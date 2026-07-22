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
    assert_eq!(body["name"], "ada");
    assert_eq!(body["email"], "ada@example.test");
    assert_eq!(body["id"], json!(user_id));

    // Fresh login issues a distinct working token.
    let (status, body) = send(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"email": "ADA@example.test", "password": "hunter22"})),
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
        (
            json!({"name": "Someone Else", "email": "ADA@example.test", "password": "hunter22"}),
            StatusCode::CONFLICT,
        ),
        (
            json!({"name": "A", "email": "valid@example.test", "password": "hunter22"}),
            StatusCode::BAD_REQUEST,
        ),
        (
            json!({"name": "Valid Name", "email": "not-an-email", "password": "hunter22"}),
            StatusCode::BAD_REQUEST,
        ),
        (
            json!({"name": "Valid Name", "email": "valid@example.test", "password": "short"}),
            StatusCode::BAD_REQUEST,
        ),
    ];
    for (payload, expected) in cases {
        let (status, _) = send(
            &app,
            "POST",
            "/api/auth/register",
            None,
            Some(payload.clone()),
        )
        .await;
        assert_eq!(status, expected, "payload {payload}");
    }
}

#[tokio::test]
async fn login_rejects_bad_credentials() {
    let app = app().await;
    register(&app, "ada").await;
    for payload in [
        json!({"email": "ada", "password": "hunter22"}),
        json!({"email": "ada@example.test", "password": "wrong-password"}),
        json!({"email": "nobody@example.test", "password": "hunter22"}),
    ] {
        let (status, _) = send(&app, "POST", "/api/auth/login", None, Some(payload)).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
}

#[tokio::test]
async fn account_name_email_and_password_can_be_changed() {
    let app = app().await;
    let (token, user_id) = register(&app, "ada").await;

    let (status, body) = send(
        &app,
        "PATCH",
        "/api/auth/me",
        Some(&token),
        Some(json!({"name": "Ada Lovelace"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["name"], "Ada Lovelace");

    let (status, body) = send(
        &app,
        "PATCH",
        "/api/auth/me",
        Some(&token),
        Some(json!({
            "email": "ada.lovelace@example.test",
            "current_password": "hunter22"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["email"], "ada.lovelace@example.test");

    let (status, _) = send(
        &app,
        "PATCH",
        "/api/auth/me",
        Some(&token),
        Some(json!({
            "new_password": "analytical-engine",
            "current_password": "hunter22"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, _) = send(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"email": "ada@example.test", "password": "hunter22"})),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let (status, body) = send(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({
            "email": "ada.lovelace@example.test",
            "password": "analytical-engine"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["user"]["id"], user_id);
}

#[tokio::test]
async fn sensitive_account_changes_require_current_password() {
    let app = app().await;
    let (token, _) = register(&app, "ada").await;

    for payload in [
        json!({"email": "new@example.test"}),
        json!({"new_password": "new-secret", "current_password": "wrong"}),
    ] {
        let (status, _) = send(&app, "PATCH", "/api/auth/me", Some(&token), Some(payload)).await;
        assert_eq!(status, StatusCode::FORBIDDEN);
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
        ("PATCH", "/api/auth/me"),
    ] {
        let (status, _) = send(&app, method, path, None, None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "{method} {path}");
    }
}
