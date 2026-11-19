//! Single sign-on against a fake OpenID Connect provider on loopback.

use std::sync::Mutex;

use axum::extract::{Form, State};
use axum::routing::{get, post};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use reqwest::Url;
use sticky_notes_server::oidc::{OidcConfig, OidcProvider, pkce_challenge};

use crate::helpers::*;

const CLIENT_ID: &str = "skippy";
/// Carries characters RFC 6749 2.3.1 makes the client form-encode in Basic.
const CLIENT_SECRET: &str = "s3cret:/+ &";
const PUBLIC_URL: &str = "https://notes.example.test";
const APP_RETURN: &str = "skippy-auth://callback";
const VERIFIER: &str = "app-verifier-app-verifier-app-verifier-0123";

/// What the fake provider puts in the next ID token, and what it last saw.
#[derive(Default)]
struct Idp {
    issuer: String,
    claims: Value,
    /// Served from userinfo instead of the ID token.
    userinfo: Option<Value>,
    challenge: String,
    /// Advertise `client_secret_post` only, the way some providers are set up.
    post_only: bool,
}

type Shared = Arc<Mutex<Idp>>;

async fn discovery(State(idp): State<Shared>) -> axum::Json<Value> {
    let (issuer, post_only) = {
        let idp = idp.lock().unwrap();
        (idp.issuer.clone(), idp.post_only)
    };
    let methods = if post_only {
        json!(["client_secret_post"])
    } else {
        json!(["client_secret_basic", "client_secret_post"])
    };
    axum::Json(json!({
        "issuer": issuer,
        "token_endpoint_auth_methods_supported": methods,
        "authorization_endpoint": format!("{issuer}/authorize"),
        "token_endpoint": format!("{issuer}/token"),
        "userinfo_endpoint": format!("{issuer}/userinfo"),
    }))
}

async fn token(
    State(idp): State<Shared>,
    headers: axum::http::HeaderMap,
    Form(form): Form<std::collections::HashMap<String, String>>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let idp = idp.lock().unwrap();
    // Basic carries form-encoded credentials (RFC 6749 2.3.1); a client
    // authenticates one way only, never both.
    let basic = format!(
        "Basic {}",
        base64::engine::general_purpose::STANDARD.encode(format!(
            "{}:{}",
            form_encode(CLIENT_ID),
            form_encode(CLIENT_SECRET)
        ))
    );
    let header_auth = headers.get(header::AUTHORIZATION);
    let body_secret = form.get("client_secret").map(String::as_str);
    let authed = if idp.post_only {
        header_auth.is_none()
            && body_secret == Some(CLIENT_SECRET)
            && form.get("client_id").map(String::as_str) == Some(CLIENT_ID)
    } else {
        body_secret.is_none() && header_auth.is_some_and(|value| value == basic.as_str())
    };
    let pkce_ok = form
        .get("code_verifier")
        .is_some_and(|verifier| pkce_challenge(verifier) == idp.challenge);
    let code_ok = form.get("code").map(String::as_str) == Some("good-code");
    if !(authed && pkce_ok && code_ok) {
        return (StatusCode::BAD_REQUEST, "invalid_grant").into_response();
    }
    let payload = URL_SAFE_NO_PAD.encode(idp.claims.to_string());
    axum::Json(json!({
        "id_token": format!("eyJhbGciOiJSUzI1NiJ9.{payload}.c2ln"),
        "access_token": "access",
        "token_type": "Bearer",
    }))
    .into_response()
}

async fn userinfo(State(idp): State<Shared>) -> axum::Json<Value> {
    axum::Json(idp.lock().unwrap().userinfo.clone().unwrap_or(json!({})))
}

/// A running fake provider and an app configured to use it.
async fn sso_app() -> (Router, Shared, AppState) {
    let idp: Shared = Arc::default();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let issuer = format!("http://{}", listener.local_addr().unwrap());
    idp.lock().unwrap().issuer = issuer.clone();
    let router = Router::new()
        .route("/.well-known/openid-configuration", get(discovery))
        .route("/token", post(token))
        .route("/userinfo", get(userinfo))
        .with_state(idp.clone());
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });

    let provider = OidcProvider::new(
        OidcConfig {
            issuer,
            client_id: CLIENT_ID.into(),
            client_secret: CLIENT_SECRET.into(),
            scopes: "openid email profile".into(),
            display_name: "Pocket ID".into(),
        },
        PUBLIC_URL,
    )
    .unwrap();
    let state = state()
        .await
        .with_public_url(PUBLIC_URL)
        .with_oidc(Arc::new(provider));
    (build_app(state.clone()), idp, state)
}

async fn get_location(app: &Router, path: &str) -> (StatusCode, String) {
    let request = Request::builder().uri(path).body(Body::empty()).unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    let location = response
        .headers()
        .get(header::LOCATION)
        .map(|value| value.to_str().unwrap().to_string())
        .unwrap_or_default();
    (response.status(), location)
}

fn param(url: &str, key: &str) -> Option<String> {
    Url::parse(url)
        .unwrap()
        .query_pairs()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.into_owned())
}

fn start_path() -> String {
    format!(
        "/api/auth/sso/start?return_to={}&code_challenge={}",
        urlencode(APP_RETURN),
        pkce_challenge(VERIFIER)
    )
}

fn form_encode(value: &str) -> String {
    urlencode(value)
}

fn urlencode(value: &str) -> String {
    url_form(&[("v", value)])[2..].to_string()
}

fn url_form(pairs: &[(&str, &str)]) -> String {
    let mut url = Url::parse("http://x/").unwrap();
    url.query_pairs_mut().extend_pairs(pairs);
    url.query().unwrap_or_default().to_string()
}

/// Run a sign-in as far as the redirect back to the app. `claims` lands in the
/// ID token, completed with a valid `iss`, `aud`, `exp` and `nonce`.
async fn callback(app: &Router, idp: &Shared, claims: Value) -> String {
    let (status, location) = get_location(app, &start_path()).await;
    assert_eq!(status, StatusCode::SEE_OTHER, "start: {location}");
    assert_eq!(
        param(&location, "redirect_uri").as_deref(),
        Some("https://notes.example.test/api/auth/sso/callback")
    );
    let state = param(&location, "state").unwrap();
    {
        let mut idp = idp.lock().unwrap();
        idp.challenge = param(&location, "code_challenge").unwrap();
        let mut full = json!({
            "iss": idp.issuer,
            "aud": CLIENT_ID,
            "exp": chrono::Utc::now().timestamp() + 300,
            "nonce": param(&location, "nonce").unwrap(),
        });
        for (key, value) in claims.as_object().unwrap() {
            full[key] = value.clone();
        }
        idp.claims = full;
    }
    let query = url_form(&[("code", "good-code"), ("state", &state)]);
    let (status, back) = get_location(app, &format!("/api/auth/sso/callback?{query}")).await;
    assert_eq!(status, StatusCode::SEE_OTHER, "callback");
    assert!(back.starts_with(APP_RETURN), "{back}");
    back
}

async fn exchange(app: &Router, back: &str, verifier: &str) -> (StatusCode, Value) {
    let code = param(back, "sso_code").unwrap_or_else(|| panic!("no code in {back}"));
    send(
        app,
        "POST",
        "/api/auth/sso/exchange",
        None,
        Some(json!({"code": code, "code_verifier": verifier})),
    )
    .await
}

async fn sign_in(app: &Router, idp: &Shared, claims: Value) -> Value {
    let back = callback(app, idp, claims).await;
    let (status, body) = exchange(app, &back, VERIFIER).await;
    assert_eq!(status, StatusCode::OK, "exchange: {body}");
    body
}

#[tokio::test]
async fn first_sign_in_creates_an_account_and_later_ones_reuse_it() {
    let (app, idp, _) = sso_app().await;
    let claims = json!({"sub": "u-1", "email": "Grace@Example.test", "email_verified": true, "name": "Grace Hopper"});
    let first = sign_in(&app, &idp, claims).await;
    assert_eq!(first["user"]["email"], "grace@example.test");
    assert_eq!(first["user"]["name"], "Grace Hopper");
    assert_eq!(first["user"]["has_password"], false);
    assert_eq!(first["created"], true);

    let token = first["token"].as_str().unwrap();
    let (status, workspaces) = send(&app, "GET", "/api/workspaces", Some(token), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(workspaces.as_array().unwrap().len(), 1, "default workspace");

    // Same subject, new address at the provider: still the same account.
    let again = sign_in(
        &app,
        &idp,
        json!({"sub": "u-1", "email": "other@example.test", "email_verified": true}),
    )
    .await;
    assert_eq!(again["user"]["id"], first["user"]["id"]);
    assert_eq!(again["created"], false);
}

#[tokio::test]
async fn verified_email_links_an_existing_account() {
    let (app, idp, _) = sso_app().await;
    let (_, user_id) = register(&app, "ada").await;
    let body = sign_in(
        &app,
        &idp,
        json!({"sub": "ada-sub", "email": test_email("ada"), "email_verified": "true"}),
    )
    .await;
    assert_eq!(body["user"]["id"], user_id.as_str());
    assert_eq!(body["user"]["has_password"], true);
    assert_eq!(body["created"], false);
}

#[tokio::test]
async fn unverified_email_cannot_take_over_an_existing_account() {
    let (app, idp, _) = sso_app().await;
    register(&app, "ada").await;
    let back = callback(
        &app,
        &idp,
        json!({"sub": "attacker", "email": test_email("ada"), "email_verified": false}),
    )
    .await;
    assert!(param(&back, "sso_code").is_none());
    assert!(
        param(&back, "sso_error")
            .unwrap()
            .contains("already exists")
    );
}

#[tokio::test]
async fn email_comes_from_userinfo_when_the_id_token_has_none() {
    let (app, idp, _) = sso_app().await;
    idp.lock().unwrap().userinfo = Some(json!({
        "sub": "u-2", "email": "lin@example.test", "email_verified": true,
        "preferred_username": "lin"
    }));
    let body = sign_in(&app, &idp, json!({"sub": "u-2"})).await;
    assert_eq!(body["user"]["email"], "lin@example.test");
    assert_eq!(body["user"]["name"], "lin");
}

#[tokio::test]
async fn userinfo_for_another_subject_is_refused() {
    let (app, idp, _) = sso_app().await;
    idp.lock().unwrap().userinfo = Some(json!({"sub": "someone-else", "email": "x@example.test"}));
    let back = callback(&app, &idp, json!({"sub": "u-3"})).await;
    assert!(param(&back, "sso_error").is_some(), "{back}");
}

#[tokio::test]
async fn id_tokens_that_do_not_check_out_are_refused() {
    let (app, idp, _) = sso_app().await;
    let base = json!({"sub": "u", "email": "u@example.test", "email_verified": true});
    let mut cases = Vec::new();
    for (key, value) in [
        ("aud", json!("another-client")),
        ("iss", json!("https://evil.example.test")),
        ("nonce", json!("replayed")),
        ("exp", json!(chrono::Utc::now().timestamp() - 3600)),
        ("aud", json!([CLIENT_ID, "other"])),
        ("azp", json!("another-client")),
    ] {
        let mut claims = base.clone();
        claims[key] = value;
        cases.push((key, claims));
    }
    for (key, claims) in cases {
        let back = callback(&app, &idp, claims).await;
        assert!(param(&back, "sso_code").is_none(), "{key} accepted: {back}");
        assert!(param(&back, "sso_error").is_some(), "{key}: {back}");
    }
}

#[tokio::test]
async fn handoff_code_needs_the_apps_verifier_and_works_once() {
    let (app, idp, _) = sso_app().await;
    let claims = json!({"sub": "u-4", "email": "u4@example.test", "email_verified": true});
    let back = callback(&app, &idp, claims.clone()).await;
    let (status, _) = exchange(&app, &back, "not-the-verifier").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    // Spent by the failed attempt.
    let (status, _) = exchange(&app, &back, VERIFIER).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let back = callback(&app, &idp, claims).await;
    assert_eq!(exchange(&app, &back, VERIFIER).await.0, StatusCode::OK);
    assert_eq!(
        exchange(&app, &back, VERIFIER).await.0,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn callback_state_is_single_use() {
    let (app, idp, _) = sso_app().await;
    let (_, location) = get_location(&app, &start_path()).await;
    let state = param(&location, "state").unwrap();
    idp.lock().unwrap().challenge = param(&location, "code_challenge").unwrap();
    let query = url_form(&[("error", "access_denied"), ("state", &state)]);
    let (status, back) = get_location(&app, &format!("/api/auth/sso/callback?{query}")).await;
    assert_eq!(status, StatusCode::SEE_OTHER);
    assert_eq!(
        param(&back, "sso_error").as_deref(),
        Some("sign-in was cancelled")
    );

    let (status, _) = get_location(&app, &format!("/api/auth/sso/callback?{query}")).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn start_only_returns_to_this_app() {
    let (app, _, _) = sso_app().await;
    let challenge = pkce_challenge(VERIFIER);
    for target in ["https://evil.example.test/sso", "javascript:alert(1)"] {
        let path = format!(
            "/api/auth/sso/start?return_to={}&code_challenge={challenge}",
            urlencode(target)
        );
        let (status, _) = get_location(&app, &path).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{target}");
    }
    let web = format!(
        "/api/auth/sso/start?return_to={}&code_challenge={challenge}",
        urlencode("https://notes.example.test/sso")
    );
    assert_eq!(get_location(&app, &web).await.0, StatusCode::SEE_OTHER);
    let short = format!(
        "/api/auth/sso/start?return_to={}&code_challenge=abc",
        urlencode(APP_RETURN)
    );
    assert_eq!(get_location(&app, &short).await.0, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn sso_is_unavailable_when_not_configured() {
    let app = app().await;
    let (status, _) = get_location(&app, &start_path()).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    let (_, caps) = send(&app, "GET", "/api/capabilities", None, None).await;
    assert_eq!(caps["sso"], Value::Null);
    assert_eq!(caps["password_login"], true);
}

#[tokio::test]
async fn capabilities_advertise_the_provider() {
    let (app, _, _) = sso_app().await;
    let (_, caps) = send(&app, "GET", "/api/capabilities", None, None).await;
    assert_eq!(caps["sso"]["name"], "Pocket ID");
}

#[tokio::test]
async fn password_login_can_be_turned_off() {
    let (_, idp, state) = sso_app().await;
    let app = build_app(state.with_password_login(false));
    let (status, _) = send(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"name": "ada", "email": test_email("ada"), "password": "hunter22"})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = send(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"email": test_email("ada"), "password": "hunter22"})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (_, caps) = send(&app, "GET", "/api/capabilities", None, None).await;
    assert_eq!(caps["password_login"], false);
    assert_eq!(caps["password_reset"], false);

    let body = sign_in(
        &app,
        &idp,
        json!({"sub": "u-5", "email": "u5@example.test", "email_verified": true}),
    )
    .await;
    assert!(body["token"].is_string());
}

#[tokio::test]
async fn sso_accounts_have_no_password_to_confirm_with() {
    let (app, idp, _) = sso_app().await;
    let body = sign_in(
        &app,
        &idp,
        json!({"sub": "u-6", "email": "u6@example.test", "email_verified": true}),
    )
    .await;
    let token = body["token"].as_str().unwrap();

    // No password verifies, not even an empty one.
    let (status, _) = send(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"email": "u6@example.test", "password": ""})),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let (status, _) = send(
        &app,
        "PATCH",
        "/api/auth/me",
        Some(token),
        Some(json!({"email": "new@example.test"})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, renamed) = send(
        &app,
        "PATCH",
        "/api/auth/me",
        Some(token),
        Some(json!({"name": "Renamed"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(renamed["has_password"], false);

    let (status, _) = send(&app, "DELETE", "/api/auth/me", Some(token), Some(json!({}))).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn a_post_only_provider_gets_the_secret_in_the_body() {
    let (app, idp, _) = sso_app().await;
    idp.lock().unwrap().post_only = true;
    let body = sign_in(
        &app,
        &idp,
        json!({"sub": "u-7", "email": "u7@example.test", "email_verified": true}),
    )
    .await;
    assert!(body["token"].is_string());
}

#[tokio::test]
async fn an_unreachable_provider_sends_the_app_an_error() {
    // A port nothing listens on.
    let issuer = {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        format!("http://{}", listener.local_addr().unwrap())
    };
    let provider = OidcProvider::new(
        OidcConfig {
            issuer,
            client_id: CLIENT_ID.into(),
            client_secret: CLIENT_SECRET.into(),
            scopes: "openid".into(),
            display_name: "SSO".into(),
        },
        PUBLIC_URL,
    )
    .unwrap();
    let app = build_app(
        state()
            .await
            .with_public_url(PUBLIC_URL)
            .with_oidc(Arc::new(provider)),
    );
    let (status, location) = get_location(&app, &start_path()).await;
    assert_eq!(status, StatusCode::SEE_OTHER);
    assert!(location.starts_with(APP_RETURN), "{location}");
    assert!(param(&location, "sso_error").is_some(), "{location}");
}

#[tokio::test]
async fn a_missing_email_verified_is_asked_of_userinfo() {
    let (app, idp, _) = sso_app().await;
    let (_, user_id) = register(&app, "ada").await;
    idp.lock().unwrap().userinfo = Some(json!({
        "sub": "ada-sub", "email": test_email("ada"), "email_verified": true
    }));
    let body = sign_in(
        &app,
        &idp,
        json!({"sub": "ada-sub", "email": test_email("ada")}),
    )
    .await;
    assert_eq!(body["user"]["id"], user_id.as_str());
}

#[tokio::test]
async fn a_fractional_expiry_is_accepted() {
    let (app, idp, _) = sso_app().await;
    let exp = chrono::Utc::now().timestamp() as f64 + 300.5;
    let body = sign_in(
        &app,
        &idp,
        json!({"sub": "u-8", "email": "u8@example.test", "email_verified": true, "exp": exp}),
    )
    .await;
    assert!(body["token"].is_string());
}

#[tokio::test]
async fn junk_exchanges_do_not_lock_out_real_ones() {
    let (app, idp, _) = sso_app().await;
    for _ in 0..40 {
        send(
            &app,
            "POST",
            "/api/auth/sso/exchange",
            None,
            Some(json!({"code": "junk", "code_verifier": VERIFIER})),
        )
        .await;
    }
    let body = sign_in(
        &app,
        &idp,
        json!({"sub": "u-9", "email": "u9@example.test", "email_verified": true}),
    )
    .await;
    assert!(body["token"].is_string());
}
