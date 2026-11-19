//! Single sign-on through one OpenID Connect provider.
//!
//! The server is the OIDC client (authorization code flow with PKCE), so the
//! provider's client secret never reaches an app. The app only ever sees a
//! short-lived handoff code, which it trades for an ordinary session:
//!
//! ```text
//! app ──/sso/start──▶ server ──302──▶ provider ──302──▶ /sso/callback
//!                                                         │ code → id_token
//! app ◀──302 return_to?sso_code=… ─────────────────────────┘
//! app ──/sso/exchange {code, verifier}──▶ session token
//! ```
//!
//! The handoff is bound to the app by its own PKCE pair: whatever else can
//! open `return_to` (another app claiming the custom scheme, a browser
//! history) holds the code but not the verifier.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use reqwest::Url;
use serde::Deserialize;
use sha2::{Digest, Sha256};

/// Where the provider sends the browser back, under `PUBLIC_URL`. This is
/// the redirect URI an operator registers with their provider.
pub const CALLBACK_PATH: &str = "/api/auth/sso/callback";
/// The custom scheme the native apps listen on for the end of a sign-in.
pub const APP_SCHEME: &str = "skippy-auth";
/// How long someone has to finish signing in at the provider.
const PENDING_TTL: Duration = Duration::from_secs(10 * 60);
/// How long the app has to trade a handoff code for a session.
const HANDOFF_TTL: Duration = Duration::from_secs(2 * 60);
/// Ceiling on sign-ins in flight, so an anonymous caller hammering `/start`
/// costs bounded memory.
const MAX_IN_FLIGHT: usize = 10_000;
/// Clock skew tolerated on `exp`/`iat`.
const CLOCK_LEEWAY_SECS: i64 = 60;
const HTTP_TIMEOUT: Duration = Duration::from_secs(15);
/// Bytes of randomness in `state`, `nonce`, the PKCE verifier and the handoff.
const SECRET_BYTES: usize = 32;
const DEFAULT_SCOPES: &str = "openid email profile";
const DEFAULT_NAME: &str = "SSO";

/// What an operator configures through `OIDC_*`.
#[derive(Debug, Clone)]
pub struct OidcConfig {
    pub issuer: String,
    pub client_id: String,
    pub client_secret: String,
    pub scopes: String,
    /// Shown on the sign-in button: "Continue with {display_name}".
    pub display_name: String,
}

impl OidcConfig {
    /// `None` when SSO is not configured. Half a configuration is an error,
    /// not a quiet "off", so a typo does not silently disable sign-in.
    pub fn from_env() -> anyhow::Result<Option<Self>> {
        let read = |key: &str| {
            std::env::var(key)
                .ok()
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
        };
        let issuer = read("OIDC_ISSUER");
        let client_id = read("OIDC_CLIENT_ID");
        let client_secret = read("OIDC_CLIENT_SECRET");
        let (issuer, client_id, client_secret) = match (issuer, client_id, client_secret) {
            (None, None, None) => return Ok(None),
            (Some(issuer), Some(id), Some(secret)) => (issuer, id, secret),
            _ => anyhow::bail!(
                "OIDC_ISSUER, OIDC_CLIENT_ID and OIDC_CLIENT_SECRET must be set together"
            ),
        };
        Ok(Some(Self {
            issuer: issuer.trim_end_matches('/').to_string(),
            client_id,
            client_secret,
            scopes: read("OIDC_SCOPES").unwrap_or_else(|| DEFAULT_SCOPES.to_string()),
            display_name: read("OIDC_NAME").unwrap_or_else(|| DEFAULT_NAME.to_string()),
        }))
    }
}

/// The parts of the provider's discovery document this client uses.
#[derive(Debug, Clone, Deserialize)]
struct Discovery {
    issuer: String,
    authorization_endpoint: String,
    token_endpoint: String,
    #[serde(default)]
    userinfo_endpoint: Option<String>,
    /// Absent means `client_secret_basic` only (OIDC Discovery 3).
    #[serde(default)]
    token_endpoint_auth_methods_supported: Option<Vec<String>>,
}

impl Discovery {
    /// `client_secret_basic` unless the provider rules it out and offers
    /// `client_secret_post`; a client configured for one is refused the other.
    fn posts_secret(&self) -> bool {
        self.token_endpoint_auth_methods_supported
            .as_ref()
            .is_some_and(|methods| {
                let has = |name: &str| methods.iter().any(|m| m == name);
                !has("client_secret_basic") && has("client_secret_post")
            })
    }
}

/// Who the provider says signed in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identity {
    pub issuer: String,
    pub subject: String,
    pub email: Option<String>,
    pub email_verified: bool,
    pub name: Option<String>,
}

/// A sign-in waiting for the provider to send the browser back.
struct Pending {
    verifier: String,
    nonce: String,
    return_to: String,
    app_challenge: String,
    created: Instant,
}

/// A finished sign-in waiting for the app to collect it.
struct Handoff {
    user_id: String,
    /// Whether the sign-in made the account, so the app can welcome it.
    created: bool,
    app_challenge: String,
    created_at: Instant,
}

/// Why a callback could not finish. Every variant is safe to show to the
/// person signing in.
#[derive(Debug, PartialEq, Eq)]
pub enum OidcError {
    /// The provider could not be reached or answered with nonsense.
    Provider(&'static str),
    /// The provider answered, but the answer does not check out.
    Rejected(&'static str),
}

impl OidcError {
    pub fn message(&self) -> &'static str {
        match self {
            OidcError::Provider(m) | OidcError::Rejected(m) => m,
        }
    }
}

pub struct OidcProvider {
    config: OidcConfig,
    /// `{PUBLIC_URL}/api/auth/sso/callback`.
    redirect_uri: String,
    public_url: String,
    http: reqwest::Client,
    /// Fetched on first use rather than at startup: an identity provider that
    /// is down when this server boots must not keep password users out.
    discovery: tokio::sync::Mutex<Option<Discovery>>,
    pending: Mutex<HashMap<String, Pending>>,
    handoffs: Mutex<HashMap<String, Handoff>>,
}

impl OidcProvider {
    pub fn new(config: OidcConfig, public_url: &str) -> anyhow::Result<Self> {
        let http = reqwest::Client::builder()
            .timeout(HTTP_TIMEOUT)
            // A token endpoint that redirects is misconfigured; following it
            // would post the client secret wherever it pointed.
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        let public_url = public_url.trim_end_matches('/').to_string();
        Ok(Self {
            config,
            redirect_uri: format!("{public_url}{CALLBACK_PATH}"),
            public_url,
            http,
            discovery: tokio::sync::Mutex::new(None),
            pending: Mutex::default(),
            handoffs: Mutex::default(),
        })
    }

    pub fn display_name(&self) -> &str {
        &self.config.display_name
    }

    /// Whether `return_to` is somewhere this server may send a handoff code:
    /// this deployment's own web app, the native apps' custom scheme, or a
    /// loopback listener (RFC 8252, used by the desktop apps).
    pub fn allowed_return(&self, return_to: &str) -> bool {
        let Ok(url) = Url::parse(return_to) else {
            return false;
        };
        if url.fragment().is_some() {
            return false;
        }
        match url.scheme() {
            APP_SCHEME => true,
            "http" if is_loopback(&url) => true,
            "http" | "https" => {
                let own = Url::parse(&self.public_url).ok();
                own.is_some_and(|own| own.origin() == url.origin())
            }
            _ => false,
        }
    }

    /// Start a sign-in: remember it under a fresh `state` and return the
    /// provider URL to send the browser to.
    pub async fn begin(&self, return_to: &str, app_challenge: &str) -> Result<String, OidcError> {
        let discovery = self.discovery().await?;
        let state = random_secret();
        let verifier = random_secret();
        let nonce = random_secret();

        let mut url = Url::parse(&discovery.authorization_endpoint)
            .map_err(|_| OidcError::Provider("the identity provider's address is invalid"))?;
        url.query_pairs_mut()
            .append_pair("response_type", "code")
            .append_pair("client_id", &self.config.client_id)
            .append_pair("redirect_uri", &self.redirect_uri)
            .append_pair("scope", &self.config.scopes)
            .append_pair("state", &state)
            .append_pair("nonce", &nonce)
            .append_pair("code_challenge", &pkce_challenge(&verifier))
            .append_pair("code_challenge_method", "S256");

        let mut pending = self.pending.lock().expect("pending lock");
        pending.retain(|_, p| p.created.elapsed() < PENDING_TTL);
        if pending.len() >= MAX_IN_FLIGHT {
            return Err(OidcError::Provider(
                "too many sign-ins in progress, try again shortly",
            ));
        }
        pending.insert(
            state,
            Pending {
                verifier,
                nonce,
                return_to: return_to.to_string(),
                app_challenge: app_challenge.to_string(),
                created: Instant::now(),
            },
        );
        Ok(url.into())
    }

    /// Take the sign-in a callback's `state` belongs to, returning where to
    /// send the browser and what to finish it with. Spent whatever happens
    /// next, so a replayed callback finds nothing.
    pub fn take_pending(&self, state: &str) -> Option<PendingLogin> {
        let mut pending = self.pending.lock().expect("pending lock");
        let entry = pending.remove(state)?;
        if entry.created.elapsed() >= PENDING_TTL {
            return None;
        }
        Some(PendingLogin {
            return_to: entry.return_to,
            verifier: entry.verifier,
            nonce: entry.nonce,
            app_challenge: entry.app_challenge,
        })
    }

    /// Trade the provider's authorization code for the identity it vouches
    /// for.
    ///
    /// The ID token's signature is not checked against the provider's keys.
    /// It arrives straight from the token endpoint over a TLS connection this
    /// server opened, which OpenID Connect Core 3.1.3.7 accepts in place of
    /// signature validation for the code flow. The claims are still checked.
    pub async fn finish(&self, code: &str, login: &PendingLogin) -> Result<Identity, OidcError> {
        let discovery = self.discovery().await?;
        let mut form = vec![
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", self.redirect_uri.as_str()),
            ("code_verifier", login.verifier.as_str()),
        ];
        let mut request = self.http.post(&discovery.token_endpoint);
        // One authentication method per request (RFC 6749 2.3).
        if discovery.posts_secret() {
            form.push(("client_id", self.config.client_id.as_str()));
            form.push(("client_secret", self.config.client_secret.as_str()));
        } else {
            // Basic carries the credentials form-encoded (RFC 6749 2.3.1),
            // which matters for secrets with `:`, `+` or spaces in them.
            request = request.basic_auth(
                form_encode(&self.config.client_id),
                Some(form_encode(&self.config.client_secret)),
            );
        }
        let response = request
            .form(&form)
            .send()
            .await
            .map_err(|_| OidcError::Provider("the identity provider could not be reached"))?;
        if !response.status().is_success() {
            return Err(OidcError::Rejected(
                "the identity provider refused the sign-in",
            ));
        }
        let tokens: TokenResponse = response
            .json()
            .await
            .map_err(|_| OidcError::Provider("the identity provider sent an unreadable answer"))?;
        let claims = decode_claims(&tokens.id_token)?;
        validate_claims(
            &claims,
            &discovery.issuer,
            &self.config.client_id,
            &login.nonce,
        )?;

        let mut identity = Identity {
            issuer: discovery.issuer.clone(),
            subject: claims.sub.clone(),
            email: claims.email.clone(),
            email_verified: claims.email_verified.is_true(),
            name: claims.display_name(),
        };
        // Many providers keep the email, or whether it is verified, out of
        // the ID token and serve it from userinfo instead.
        if (identity.email.is_none() || claims.email_verified.is_missing())
            && let (Some(endpoint), Some(access)) = (
                discovery.userinfo_endpoint.as_deref(),
                tokens.access_token.as_deref(),
            )
        {
            let info = self.userinfo(endpoint, access).await?;
            if info.sub != identity.subject {
                return Err(OidcError::Rejected(
                    "the identity provider described a different account",
                ));
            }
            // The verdict describes userinfo's address, so the two travel
            // together; an answer without one leaves the token's as it was.
            if info.email.is_some() {
                identity.email = info.email.clone();
                identity.email_verified = info.email_verified.is_true();
            }
            identity.name = identity.name.or_else(|| info.display_name());
        }
        identity.email = identity
            .email
            .map(|email| email.trim().to_lowercase())
            .filter(|email| !email.is_empty());
        Ok(identity)
    }

    async fn userinfo(&self, endpoint: &str, access_token: &str) -> Result<Claims, OidcError> {
        let response = self
            .http
            .get(endpoint)
            .bearer_auth(access_token)
            .send()
            .await
            .map_err(|_| OidcError::Provider("the identity provider could not be reached"))?;
        if !response.status().is_success() {
            return Err(OidcError::Rejected(
                "the identity provider would not describe the account",
            ));
        }
        response
            .json()
            .await
            .map_err(|_| OidcError::Provider("the identity provider sent an unreadable answer"))
    }

    /// Park a finished sign-in for the app to collect; returns the code that
    /// goes into `return_to`.
    pub fn hand_off(&self, user_id: &str, app_challenge: &str, created: bool) -> String {
        let code = random_secret();
        let mut handoffs = self.handoffs.lock().expect("handoff lock");
        handoffs.retain(|_, h| h.created_at.elapsed() < HANDOFF_TTL);
        handoffs.insert(
            code_digest(&code),
            Handoff {
                user_id: user_id.to_string(),
                created,
                app_challenge: app_challenge.to_string(),
                created_at: Instant::now(),
            },
        );
        code
    }

    /// Collect a parked sign-in. The code is spent on the first attempt,
    /// right verifier or not, so it cannot be guessed at. Returns the account
    /// and whether the sign-in created it.
    pub fn redeem(&self, code: &str, verifier: &str) -> Option<(String, bool)> {
        let entry = self
            .handoffs
            .lock()
            .expect("handoff lock")
            .remove(&code_digest(code))?;
        let fresh = entry.created_at.elapsed() < HANDOFF_TTL;
        let bound = pkce_challenge(verifier) == entry.app_challenge;
        (fresh && bound).then_some((entry.user_id, entry.created))
    }

    async fn discovery(&self) -> Result<Discovery, OidcError> {
        let mut cached = self.discovery.lock().await;
        if let Some(found) = cached.as_ref() {
            return Ok(found.clone());
        }
        let url = format!("{}/.well-known/openid-configuration", self.config.issuer);
        let unreachable = || OidcError::Provider("the identity provider could not be reached");
        let response = self
            .http
            .get(&url)
            .send()
            .await
            .map_err(|_| unreachable())?;
        if !response.status().is_success() {
            return Err(unreachable());
        }
        let found: Discovery = response
            .json()
            .await
            .map_err(|_| OidcError::Provider("the identity provider's configuration is invalid"))?;
        // The document must describe the issuer it was fetched for; anything
        // else is a misconfiguration that would fail every `iss` check later.
        if found.issuer.trim_end_matches('/') != self.config.issuer {
            return Err(OidcError::Provider(
                "the identity provider's issuer does not match OIDC_ISSUER",
            ));
        }
        *cached = Some(found.clone());
        Ok(found)
    }
}

/// What a callback needs from the sign-in it finishes.
pub struct PendingLogin {
    pub return_to: String,
    verifier: String,
    nonce: String,
    pub app_challenge: String,
}

#[derive(Deserialize)]
struct TokenResponse {
    id_token: String,
    #[serde(default)]
    access_token: Option<String>,
}

/// `aud` is a string or an array of them.
#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum Audience {
    One(String),
    Many(Vec<String>),
}

impl Audience {
    fn contains(&self, id: &str) -> bool {
        match self {
            Audience::One(aud) => aud == id,
            Audience::Many(auds) => auds.iter().any(|aud| aud == id),
        }
    }

    fn len(&self) -> usize {
        match self {
            Audience::One(_) => 1,
            Audience::Many(auds) => auds.len(),
        }
    }
}

/// Some providers send `email_verified` as the string `"true"`.
#[derive(Debug, Default, Deserialize)]
#[serde(untagged)]
enum Flag {
    #[default]
    Missing,
    Bool(bool),
    Text(String),
}

impl Flag {
    fn is_true(&self) -> bool {
        match self {
            Flag::Bool(value) => *value,
            Flag::Text(text) => text.eq_ignore_ascii_case("true"),
            Flag::Missing => false,
        }
    }

    fn is_missing(&self) -> bool {
        matches!(self, Flag::Missing)
    }
}

#[derive(Debug, Deserialize)]
struct Claims {
    sub: String,
    #[serde(default)]
    iss: Option<String>,
    #[serde(default)]
    aud: Option<Audience>,
    #[serde(default)]
    azp: Option<String>,
    #[serde(default)]
    /// Seconds; a few providers send a fraction.
    exp: Option<f64>,
    #[serde(default)]
    nonce: Option<String>,
    #[serde(default)]
    email: Option<String>,
    #[serde(default)]
    email_verified: Flag,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    preferred_username: Option<String>,
}

impl Claims {
    fn display_name(&self) -> Option<String> {
        [&self.name, &self.preferred_username]
            .into_iter()
            .flatten()
            .map(|name| name.trim().to_string())
            .find(|name| !name.is_empty())
    }
}

/// The payload of a compact JWT, without checking its signature (see
/// [`OidcProvider::finish`]).
fn decode_claims(token: &str) -> Result<Claims, OidcError> {
    let malformed = || OidcError::Rejected("the identity provider sent a malformed ID token");
    let mut parts = token.split('.');
    let payload = match (parts.next(), parts.next(), parts.next(), parts.next()) {
        (Some(_), Some(payload), Some(_), None) => payload,
        _ => return Err(malformed()),
    };
    let bytes = URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .map_err(|_| malformed())?;
    serde_json::from_slice(&bytes).map_err(|_| malformed())
}

fn validate_claims(
    claims: &Claims,
    issuer: &str,
    client_id: &str,
    nonce: &str,
) -> Result<(), OidcError> {
    if claims.iss.as_deref() != Some(issuer) {
        return Err(OidcError::Rejected("the ID token is from another issuer"));
    }
    let Some(aud) = &claims.aud else {
        return Err(OidcError::Rejected(
            "the ID token is for another application",
        ));
    };
    if !aud.contains(client_id) {
        return Err(OidcError::Rejected(
            "the ID token is for another application",
        ));
    }
    // A multi-audience token must name this client as `azp`, and any token
    // that names an `azp` must name this one (OIDC Core 3.1.3.7, 4-5).
    let azp_ok = match claims.azp.as_deref() {
        Some(azp) => azp == client_id,
        None => aud.len() == 1,
    };
    if !azp_ok {
        return Err(OidcError::Rejected(
            "the ID token is for another application",
        ));
    }
    let now = chrono::Utc::now().timestamp();
    let live = claims
        .exp
        .is_some_and(|exp| exp + CLOCK_LEEWAY_SECS as f64 > now as f64);
    if !live {
        return Err(OidcError::Rejected("the ID token has expired"));
    }
    if claims.nonce.as_deref() != Some(nonce) {
        return Err(OidcError::Rejected(
            "the ID token belongs to another sign-in",
        ));
    }
    if claims.sub.trim().is_empty() {
        return Err(OidcError::Rejected("the ID token names no account"));
    }
    Ok(())
}

fn is_loopback(url: &Url) -> bool {
    matches!(
        url.host_str(),
        Some("localhost") | Some("127.0.0.1") | Some("[::1]")
    )
}

fn random_secret() -> String {
    let mut bytes = [0u8; SECRET_BYTES];
    rand_core::RngCore::fill_bytes(&mut rand_core::OsRng, &mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

/// The S256 PKCE challenge for `verifier` (RFC 7636).
pub fn pkce_challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

fn form_encode(value: &str) -> String {
    form_urlencoded::byte_serialize(value.as_bytes()).collect()
}

/// Handoff codes are kept as digests, like sessions.
fn code_digest(code: &str) -> String {
    hex::encode(Sha256::digest(code.as_bytes()))
}

/// Append `key=value` to `return_to`, keeping whatever query it carries.
pub fn with_param(return_to: &str, key: &str, value: &str) -> String {
    match Url::parse(return_to) {
        Ok(mut url) => {
            url.query_pairs_mut().append_pair(key, value);
            url.into()
        }
        Err(_) => return_to.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn provider() -> OidcProvider {
        OidcProvider::new(
            OidcConfig {
                issuer: "https://id.example.com".into(),
                client_id: "skippy".into(),
                client_secret: "secret".into(),
                scopes: DEFAULT_SCOPES.into(),
                display_name: DEFAULT_NAME.into(),
            },
            "https://notes.example.com/",
        )
        .unwrap()
    }

    #[test]
    fn return_targets_are_limited() {
        let p = provider();
        assert!(p.allowed_return("https://notes.example.com/sso"));
        assert!(p.allowed_return("skippy-auth://callback"));
        assert!(p.allowed_return("http://localhost:43823/"));
        assert!(p.allowed_return("http://127.0.0.1:5000/cb"));
        assert!(!p.allowed_return("https://evil.example.com/sso"));
        assert!(!p.allowed_return("https://notes.example.com.evil.com/sso"));
        assert!(!p.allowed_return("http://notes.example.com/sso"));
        assert!(!p.allowed_return("javascript:alert(1)"));
        assert!(!p.allowed_return("https://notes.example.com/sso#x"));
    }

    #[test]
    fn handoff_needs_the_matching_verifier_and_is_single_use() {
        let p = provider();
        let code = p.hand_off("user-1", &pkce_challenge("right"), false);
        assert_eq!(p.redeem(&code, "wrong"), None);
        // Spent by the failed attempt.
        assert_eq!(p.redeem(&code, "right"), None);

        let code = p.hand_off("user-1", &pkce_challenge("right"), true);
        assert_eq!(p.redeem(&code, "right"), Some(("user-1".to_string(), true)));
        assert_eq!(p.redeem(&code, "right"), None);
    }

    #[test]
    fn email_verified_accepts_strings() {
        let claims: Claims =
            serde_json::from_str(r#"{"sub":"a","email_verified":"true"}"#).unwrap();
        assert!(claims.email_verified.is_true());
        let claims: Claims = serde_json::from_str(r#"{"sub":"a"}"#).unwrap();
        assert!(!claims.email_verified.is_true());
    }

    #[test]
    fn appends_params_to_existing_query() {
        assert_eq!(
            with_param("skippy-auth://callback?x=1", "sso_code", "a b"),
            "skippy-auth://callback?x=1&sso_code=a+b"
        );
    }
}
