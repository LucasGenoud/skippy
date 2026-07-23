//! The per-user settings document.

use crate::helpers::*;

#[tokio::test]
async fn settings_roundtrip_scoped_and_validated() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;

    // Defaults to an empty object.
    let (status, body) = send(&app, "GET", "/api/settings", Some(&ada), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, json!({}));

    // Roundtrip an arbitrary settings document.
    let doc = json!({
        "theme": "dark",
        "date_format": "dayFirst",
        "palette": [{"key": "lava", "name": "Lava", "light": "#FF5722", "dark": "#4E1A0F"}],
    });
    let (status, _) = send(&app, "PUT", "/api/settings", Some(&ada), Some(doc.clone())).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, body) = send(&app, "GET", "/api/settings", Some(&ada), None).await;
    assert_eq!(body, doc);

    // Strictly per-user.
    let (_, body) = send(&app, "GET", "/api/settings", Some(&bob), None).await;
    assert_eq!(body, json!({}));

    // Non-objects are rejected; auth is required.
    let (status, _) = send(&app, "PUT", "/api/settings", Some(&ada), Some(json!([1, 2]))).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = send(&app, "GET", "/api/settings", None, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}
