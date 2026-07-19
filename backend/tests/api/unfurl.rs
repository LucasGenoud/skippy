//! Integration tests for `GET /api/unfurl`. A tiny in-process HTTP server
//! serves an Open Graph page (with a request counter) so we can assert the
//! endpoint parses metadata and that a second call is served from cache.
//!
//! The SSRF guard blocks the loopback test server unless opted out, so these
//! set `STICKY_NOTES_UNFURL_ALLOW_PRIVATE=1` (the guard itself is unit-tested
//! in `src/unfurl.rs`, no network needed).

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use axum::response::Html;
use axum::routing::get;
use axum::Router;

use crate::helpers::*;

const OG_PAGE: &str = r#"<!doctype html><html><head>
<title>Fallback Title</title>
<meta property="og:title" content="YouTube">
<meta property="og:site_name" content="YouTube">
<meta property="og:image" content="/img/logo.png">
<meta property="og:description" content="Enjoy the videos">
<link rel="icon" href="/favicon.ico">
</head><body>hi</body></html>"#;

/// Spawn a loopback HTTP server serving [`OG_PAGE`] and counting hits.
/// Returns its base URL (e.g. `http://127.0.0.1:PORT`) and the counter.
async fn spawn_og_server() -> (String, Arc<AtomicUsize>) {
    let hits = Arc::new(AtomicUsize::new(0));
    let hits_for_route = hits.clone();
    let app = Router::new().route(
        "/page",
        get(move || {
            hits_for_route.fetch_add(1, Ordering::SeqCst);
            async { Html(OG_PAGE) }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    (format!("http://{addr}"), hits)
}

fn allow_private_fetch() {
    // Safe: no other test reads this env var, and the unfurl endpoint tests all
    // want it set. Process-global by nature of env.
    unsafe { std::env::set_var("STICKY_NOTES_UNFURL_ALLOW_PRIVATE", "1") };
}

#[tokio::test]
async fn unfurl_parses_open_graph_metadata() {
    allow_private_fetch();
    let (base, _hits) = spawn_og_server().await;
    let app = app().await;
    let (token, _) = register(&app, "unfurl_og").await;

    let url = format!("{base}/page");
    let (status, body) = send(
        &app,
        "GET",
        &format!("/api/unfurl?url={}", urlencoding(&url)),
        Some(&token),
        None,
    )
    .await;

    assert_eq!(status, StatusCode::OK, "unfurl: {body}");
    assert_eq!(body["title"], "YouTube");
    assert_eq!(body["site_name"], "YouTube");
    assert_eq!(body["description"], "Enjoy the videos");
    // Relative image resolved against the page URL.
    assert_eq!(body["image"], format!("{base}/img/logo.png"));
    assert_eq!(body["favicon"], format!("{base}/favicon.ico"));
}

#[tokio::test]
async fn unfurl_serves_the_second_request_from_cache() {
    allow_private_fetch();
    let (base, hits) = spawn_og_server().await;
    let app = app().await;
    let (token, _) = register(&app, "unfurl_cache").await;

    let path = format!("/api/unfurl?url={}", urlencoding(&format!("{base}/page")));
    let (s1, _) = send(&app, "GET", &path, Some(&token), None).await;
    let (s2, _) = send(&app, "GET", &path, Some(&token), None).await;

    assert_eq!(s1, StatusCode::OK);
    assert_eq!(s2, StatusCode::OK);
    // Only the first call reached the upstream server; the second hit the cache.
    assert_eq!(hits.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn unfurl_requires_auth() {
    let app = app().await;
    let (status, _) = send(&app, "GET", "/api/unfurl?url=https://example.com", None, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn unfurl_rejects_non_http_urls() {
    let app = app().await;
    let (token, _) = register(&app, "unfurl_bad").await;
    let (status, _) = send(
        &app,
        "GET",
        &format!("/api/unfurl?url={}", urlencoding("file:///etc/passwd")),
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

/// Minimal percent-encoding for the query value (`:` `/` `?` etc.).
fn urlencoding(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}
