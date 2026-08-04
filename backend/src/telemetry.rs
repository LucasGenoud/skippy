//! Minimal structured telemetry without imposing an external collector.
//!
//! Events are emitted as one JSON object per line, which works with Docker's
//! default logging and can be ingested by the self-hoster's tool of choice.

use std::sync::atomic::Ordering;
use std::time::Instant;

use axum::extract::{MatchedPath, Request};
use axum::http::{HeaderValue, header::HeaderName};
use axum::middleware::Next;
use axum::response::Response;
use serde_json::{Value, json};

use crate::AppState;

pub static REQUEST_ID_HEADER: HeaderName = HeaderName::from_static("x-request-id");

tokio::task_local! {
    static CURRENT_REQUEST_ID: String;
}

pub fn current_request_id() -> Option<String> {
    CURRENT_REQUEST_ID.try_with(Clone::clone).ok()
}

pub fn event(level: &str, name: &str, fields: Value) {
    let mut value = json!({
        "timestamp": chrono::Utc::now().to_rfc3339(),
        "level": level,
        "event": name,
    });
    if let (Some(target), Some(source)) = (value.as_object_mut(), fields.as_object()) {
        target.extend(source.clone());
    }
    if level == "error" || level == "warn" {
        eprintln!("{value}");
    } else {
        println!("{value}");
    }
}

impl AppState {
    /// Count and report failures from detached work. Health exposes only the
    /// aggregate counter; potentially sensitive provider errors remain in
    /// server logs.
    pub fn report_background_failure(&self, job: &str, error: &dyn std::fmt::Display) {
        self.background_failures.fetch_add(1, Ordering::Relaxed);
        event(
            "error",
            "background_job_failed",
            json!({ "job": job, "error": error.to_string() }),
        );
    }
}

/// Add a correlation id to every response and emit a structured request log.
pub async fn request_context(request: Request, next: Next) -> Response {
    let started = Instant::now();
    let request_id = request
        .headers()
        .get(&REQUEST_ID_HEADER)
        .and_then(valid_request_id)
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let method = request.method().to_string();
    let path = request
        .extensions()
        .get::<MatchedPath>()
        .map(|matched| matched.as_str().to_string())
        .unwrap_or_else(|| safe_path(request.uri().path()));

    let mut response = CURRENT_REQUEST_ID
        .scope(request_id.clone(), next.run(request))
        .await;
    response.headers_mut().insert(
        REQUEST_ID_HEADER.clone(),
        HeaderValue::from_str(&request_id).expect("validated request id is a header value"),
    );
    event(
        if response.status().is_server_error() {
            "error"
        } else {
            "info"
        },
        "http_request",
        json!({
            "request_id": request_id,
            "method": method,
            "path": path,
            "status": response.status().as_u16(),
            "duration_ms": started.elapsed().as_millis(),
        }),
    );
    response
}

fn valid_request_id(value: &HeaderValue) -> Option<String> {
    let value = value.to_str().ok()?;
    if value.is_empty()
        || value.len() > 128
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
    {
        return None;
    }
    Some(value.to_string())
}

fn safe_path(path: &str) -> String {
    for prefix in ["/api/public/", "/api/files/"] {
        if path.starts_with(prefix) {
            return format!("{prefix}{{credential}}");
        }
    }
    path.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credentials_are_not_logged_in_fallback_paths() {
        assert_eq!(safe_path("/api/public/secret"), "/api/public/{credential}");
        assert_eq!(safe_path("/api/files/signed-id"), "/api/files/{credential}");
        assert_eq!(safe_path("/api/health"), "/api/health");
    }
}
