use crate::helpers::*;
use sticky_notes_server::{build_app_with_cors_origin, cors_origin_from_public_url};

#[tokio::test]
async fn configured_public_url_is_the_only_cors_origin() {
    let app = build_app_with_cors_origin(
        state().await,
        Some(cors_origin_from_public_url("https://notes.example.com/app/").unwrap()),
    );

    let allowed = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/health")
                .header(header::ORIGIN, "https://notes.example.com")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        allowed
            .headers()
            .get(header::ACCESS_CONTROL_ALLOW_ORIGIN)
            .unwrap(),
        "https://notes.example.com",
    );

    let rejected = app
        .oneshot(
            Request::builder()
                .uri("/api/health")
                .header(header::ORIGIN, "https://untrusted.example")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert!(
        rejected
            .headers()
            .get(header::ACCESS_CONTROL_ALLOW_ORIGIN)
            .is_none(),
    );
}
