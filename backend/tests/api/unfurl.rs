//! Integration tests for `GET /api/unfurl`. A tiny in-process HTTP server
//! serves an Open Graph page (with a request counter) so we can assert the
//! endpoint parses metadata and that a second call is served from cache.
//!
//! The SSRF guard blocks the loopback test server unless opted out, so these
//! set `UNFURL_ALLOW_PRIVATE=1` (the guard itself is unit-tested
//! in `src/unfurl.rs`, no network needed).

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use axum::Router;
use axum::response::Html;
use axum::routing::get;

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
    unsafe { std::env::set_var("UNFURL_ALLOW_PRIVATE", "1") };
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
    let (status, _) = send(
        &app,
        "GET",
        "/api/unfurl?url=https://example.com",
        None,
        None,
    )
    .await;
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

#[tokio::test]
async fn summarize_fetches_page_content_and_uses_the_writing_model() {
    allow_private_fetch();
    let (base, _) = spawn_og_server().await;
    let (state, calls) = state_with_llm("A tiny page summary.").await;
    let app = build_app(state);
    let (token, _) = register(&app, "unfurl_summary").await;
    let (status, _) = send(
        &app,
        "PUT",
        "/api/settings",
        Some(&token),
        Some(json!({
            "llm_base_url": "http://fake/v1",
            "llm_model": "test-model",
            "llm_writing": true
        })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let (status, body) = send(
        &app,
        "POST",
        "/api/unfurl/summary",
        Some(&token),
        Some(json!({"url": format!("{base}/page"), "length": "long"})),
    )
    .await;

    assert_eq!(status, StatusCode::OK, "summary: {body}");
    assert_eq!(body["summary"], "A tiny page summary.");
    let calls = calls.lock().unwrap();
    assert!(calls[0][0].content.contains("detailed overview"));
    assert!(calls[0][1].content.contains("hi"));
    assert!(!calls[0][1].content.contains("Fallback Title"));
}

#[tokio::test]
async fn automatically_summarizes_a_link_added_through_notes_api() {
    allow_private_fetch();
    let (base, _) = spawn_og_server().await;
    let (state, calls) = state_with_llm("Automatic summary.").await;
    let app = build_app(state);
    let (token, _) = register(&app, "unfurl_auto_summary").await;
    let (status, _) = send(
        &app,
        "PUT",
        "/api/settings",
        Some(&token),
        Some(json!({
            "llm_base_url": "http://fake/v1",
            "llm_model": "test-model",
            "llm_writing": true,
            "auto_summarize_links": true,
            "link_summary_length": "medium"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let url = format!("{base}/page");
    let (status, note) = send(
        &app,
        "POST",
        "/api/notes",
        Some(&token),
        Some(json!({"content": url})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "create: {note}");
    let id = note["id"].as_str().unwrap();

    for _ in 0..50 {
        tokio::time::sleep(Duration::from_millis(10)).await;
        let (status, note) =
            send(&app, "GET", &format!("/api/notes/{id}"), Some(&token), None).await;
        assert_eq!(status, StatusCode::OK);
        if note["content"]
            .as_str()
            .is_some_and(|text| text.contains("Automatic summary."))
        {
            let calls = calls.lock().unwrap();
            assert!(calls[0][0].content.contains("compact overview"));
            return;
        }
    }
    panic!("automatic summary was not added");
}

/// A page that answers only once the test lets it, so a summary can be
/// caught mid-fetch.
async fn spawn_gated_server() -> (String, Arc<tokio::sync::Notify>) {
    let gate = Arc::new(tokio::sync::Notify::new());
    let gate_for_route = gate.clone();
    let app = Router::new().route(
        "/slow",
        get(move || {
            let gate = gate_for_route.clone();
            async move {
                gate.notified().await;
                Html(OG_PAGE)
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    (format!("http://{addr}"), gate)
}

#[tokio::test]
async fn cancelling_stops_a_running_link_summary() {
    allow_private_fetch();
    let (base, gate) = spawn_gated_server().await;
    let (state, calls) = state_with_llm("Automatic summary.").await;
    let app = build_app(state);
    let (token, _) = register(&app, "unfurl_cancel_summary").await;
    let (other, _) = register(&app, "unfurl_cancel_stranger").await;
    let (status, _) = send(
        &app,
        "PUT",
        "/api/settings",
        Some(&token),
        Some(json!({
            "llm_base_url": "http://fake/v1",
            "llm_model": "test-model",
            "llm_writing": true,
            "auto_summarize_links": true
        })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let url = format!("{base}/slow");
    let (status, note) = send(
        &app,
        "POST",
        "/api/notes",
        Some(&token),
        Some(json!({"content": url})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "create: {note}");
    let id = note["id"].as_str().unwrap();
    let path = format!("/api/notes/{id}");
    let mut running = false;
    for _ in 0..50 {
        let (_, note) = send(&app, "GET", &path, Some(&token), None).await;
        if note["summarizing_links"] == true {
            running = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(running, "summary never started");

    // Someone who cannot see the note cannot stop it either.
    let cancel = format!("{path}/link-summaries");
    let (status, _) = send(&app, "DELETE", &cancel, Some(&other), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let (status, _) = send(&app, "DELETE", &cancel, Some(&token), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, note) = send(&app, "GET", &path, Some(&token), None).await;
    assert_eq!(note["summarizing_links"], false);

    // Even if the page answers now, nothing is written and no model is asked.
    gate.notify_waiters();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let (_, note) = send(&app, "GET", &path, Some(&token), None).await;
    assert_eq!(note["content"], url);
    assert!(calls.lock().unwrap().is_empty());
}

#[tokio::test]
async fn note_view_reports_a_running_link_summary() {
    let state = state().await;
    let _job = state.start_link_summary("summary-pending");
    let app = build_app(state);
    let (token, _) = register(&app, "unfurl_pending_summary").await;

    let (status, note) = send(
        &app,
        "POST",
        "/api/notes",
        Some(&token),
        Some(json!({"id": "summary-pending", "content": "https://example.com"})),
    )
    .await;

    assert_eq!(status, StatusCode::CREATED, "create: {note}");
    assert_eq!(note["summarizing_links"], true);
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
