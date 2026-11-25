use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode, header};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use tower::ServiceExt;

use crate::helpers::*;

/// The smallest valid PNG: a 1x1 transparent pixel.
const PNG: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x64, 0xF8, 0xCF, 0x50,
    0x0F, 0x00, 0x03, 0x86, 0x01, 0x80, 0x5A, 0x34, 0x7D, 0x6B, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

async fn put_avatar(app: &Router, token: &str, mime: &str, bytes: &[u8]) -> StatusCode {
    let request = Request::builder()
        .method("PUT")
        .uri("/api/auth/me/avatar")
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .header(header::CONTENT_TYPE, mime)
        .body(Body::from(bytes.to_vec()))
        .unwrap();
    app.clone().oneshot(request).await.unwrap().status()
}

async fn get_avatar(app: &Router, token: &str, user_id: &str) -> (StatusCode, Option<String>, Vec<u8>) {
    let request = Request::builder()
        .uri(format!("/api/users/{user_id}/avatar"))
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let mime = response
        .headers()
        .get(header::CONTENT_TYPE)
        .map(|v| v.to_str().unwrap().to_string());
    let bytes = response.into_body().collect().await.unwrap().to_bytes().to_vec();
    (status, mime, bytes)
}

async fn me(app: &Router, token: &str) -> Value {
    let (status, body) = send(app, "GET", "/api/auth/me", Some(token), None).await;
    assert_eq!(status, StatusCode::OK);
    body
}

#[tokio::test]
async fn an_uploaded_picture_is_served_and_versioned() {
    let app = app().await;
    let (token, id) = register(&app, "ada").await;
    assert!(me(&app, &token).await.get("avatar").is_none());

    assert_eq!(put_avatar(&app, &token, "image/png", PNG).await, StatusCode::NO_CONTENT);
    let version = me(&app, &token).await["avatar"].as_i64().expect("version");

    let (status, mime, bytes) = get_avatar(&app, &token, &id).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(mime.as_deref(), Some("image/png"));
    assert_eq!(bytes, PNG);

    // Replacing it moves the version, so clients drop the old picture.
    tokio::time::sleep(std::time::Duration::from_millis(2)).await;
    assert_eq!(put_avatar(&app, &token, "image/png", PNG).await, StatusCode::NO_CONTENT);
    assert!(me(&app, &token).await["avatar"].as_i64().unwrap() > version);

    let (status, _) = send(&app, "DELETE", "/api/auth/me/avatar", Some(&token), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(me(&app, &token).await.get("avatar").is_none());
    assert_eq!(get_avatar(&app, &token, &id).await.0, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn only_small_images_are_accepted() {
    let app = app().await;
    let (token, _) = register(&app, "ada").await;
    assert_eq!(
        put_avatar(&app, &token, "image/png", b"<svg></svg>").await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        put_avatar(&app, &token, "image/svg+xml", PNG).await,
        StatusCode::BAD_REQUEST
    );
    let huge = [PNG, &vec![0u8; 300 * 1024]].concat();
    assert_eq!(
        put_avatar(&app, &token, "image/png", &huge).await,
        StatusCode::BAD_REQUEST
    );
}

#[tokio::test]
async fn pictures_reach_only_people_who_share_something() {
    let app = app().await;
    let (ada, ada_id) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let (eve, _) = register(&app, "eve").await;
    put_avatar(&app, &ada, "image/png", PNG).await;

    // A stranger cannot learn the account exists.
    assert_eq!(get_avatar(&app, &eve, &ada_id).await.0, StatusCode::NOT_FOUND);

    // Sharing a note with bob shows him ada, and the note carries the version.
    let note = create_note(&app, &ada, json!({"title": "plans"})).await;
    let id = note["id"].as_str().unwrap();
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&ada),
        Some(json!({"email": test_email("bob")})),
    )
    .await;
    assert!(status.is_success(), "share: {status}");
    assert_eq!(get_avatar(&app, &bob, &ada_id).await.0, StatusCode::OK);
    let shared = list_notes(&app, &bob).await;
    let owner = &shared.iter().find(|n| n["id"] == id).unwrap()["owner"];
    assert!(owner["avatar"].as_i64().is_some(), "owner: {owner}");

    // A workspace member sees the owner's picture on the roster.
    let (status, workspace) = send(
        &app,
        "POST",
        "/api/workspaces",
        Some(&ada),
        Some(json!({"name": "Team"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let workspace_id = workspace["id"].as_str().unwrap();
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/workspaces/{workspace_id}/members"),
        Some(&ada),
        Some(json!({"email": test_email("eve")})),
    )
    .await;
    assert!(status.is_success());
    assert_eq!(get_avatar(&app, &eve, &ada_id).await.0, StatusCode::OK);
    let (_, list) = send(&app, "GET", "/api/workspaces", Some(&eve), None).await;
    let team = list.as_array().unwrap().iter().find(|w| w["id"] == workspace_id).unwrap();
    assert!(team["owner"]["avatar"].as_i64().is_some(), "team: {team}");
}
