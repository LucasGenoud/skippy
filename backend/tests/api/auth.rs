//! Health check and the register/login/logout flows.

use crate::helpers::*;

#[tokio::test]
async fn health_works() {
    let app = app().await;
    let (status, body) = send(&app, "GET", "/api/health", None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["ok"], json!(true));
}

#[tokio::test]
async fn register_login_me_logout_flow() {
    let app = app().await;
    let (token, user_id) = register(&app, "ada").await;

    let (status, body) = send(&app, "GET", "/api/auth/me", Some(&token), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["username"], "ada");
    assert_eq!(body["id"], json!(user_id));

    // Fresh login issues a distinct working token.
    let (status, body) = send(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"username": "ada", "password": "hunter22"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let token2 = body["token"].as_str().unwrap().to_string();
    assert_ne!(token, token2);

    // Logout kills only the token used.
    let (status, _) = send(&app, "POST", "/api/auth/logout", Some(&token), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _) = send(&app, "GET", "/api/auth/me", Some(&token), None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _) = send(&app, "GET", "/api/auth/me", Some(&token2), None).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn register_validation_and_duplicates() {
    let app = app().await;
    register(&app, "ada").await;

    let cases = [
        (json!({"username": "ada", "password": "hunter22"}), StatusCode::CONFLICT),
        (json!({"username": "AdA", "password": "hunter22"}), StatusCode::CONFLICT), // case-insensitive
        (json!({"username": "ab", "password": "hunter22"}), StatusCode::BAD_REQUEST),
        (json!({"username": "has space", "password": "hunter22"}), StatusCode::BAD_REQUEST),
        (json!({"username": "fine-name", "password": "short"}), StatusCode::BAD_REQUEST),
    ];
    for (payload, expected) in cases {
        let (status, _) = send(&app, "POST", "/api/auth/register", None, Some(payload.clone())).await;
        assert_eq!(status, expected, "payload {payload}");
    }
}

#[tokio::test]
async fn login_rejects_bad_credentials() {
    let app = app().await;
    register(&app, "ada").await;
    for payload in [
        json!({"username": "ada", "password": "wrong-password"}),
        json!({"username": "nobody", "password": "hunter22"}),
    ] {
        let (status, _) = send(&app, "POST", "/api/auth/login", None, Some(payload)).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
}

#[tokio::test]
async fn endpoints_require_auth() {
    let app = app().await;
    for (method, path) in [
        ("GET", "/api/notes"),
        ("POST", "/api/notes"),
        ("GET", "/api/labels"),
        ("GET", "/api/auth/me"),
    ] {
        let (status, _) = send(&app, method, path, None, None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "{method} {path}");
    }
}

