//! Shared test harness: in-memory app state, request helpers, and the
//! deterministic fakes (embedder, transcriber, LLM) used across modules.

use async_trait::async_trait;

use sticky_notes_server::files::DiskStore;
use sticky_notes_server::llm::{ChatMessage, Llm, LlmConfig};
use sticky_notes_server::search::TextEmbedder;
use sticky_notes_server::store::sqlite::SqliteRepository;
use sticky_notes_server::transcribe::Transcriber;

// Common externals, re-exported so every test module can pull in the whole
// harness with one `use crate::helpers::*;`.
pub use std::sync::Arc;

pub use axum::Router;
pub use axum::body::Body;
pub use axum::http::{Request, StatusCode, header};
pub use http_body_util::BodyExt;
pub use serde_json::{Value, json};
pub use tower::ServiceExt;

pub use sticky_notes_server::search::{SearchService, SqliteVectorIndex};
pub use sticky_notes_server::{AppState, build_app};

/// Fixed signing key for the test app so tests can mint/forge file signatures
/// deterministically (production uses a random, persisted secret).
pub const TEST_FILE_SECRET: &[u8] = b"sticky-notes-test-file-signing-secret";

pub async fn state() -> AppState {
    let repo = Arc::new(SqliteRepository::connect(":memory:").await.unwrap());
    let dir = std::env::temp_dir().join(format!("sticky-notes-test-{}", uuid::Uuid::new_v4()));
    AppState::new(repo, Arc::new(DiskStore::new(dir))).with_file_secret(TEST_FILE_SECRET.to_vec())
}

/// Deterministic bag-of-words embedder: shared tokens => similar vectors.
/// Lets the search pipeline be tested without the real ONNX model.
pub struct HashEmbedder;

/// Dimension of HashEmbedder vectors; the vector index is created to match.
pub const HASH_EMBED_DIMS: usize = 64;

impl TextEmbedder for HashEmbedder {
    fn embed(&self, texts: Vec<String>) -> anyhow::Result<Vec<Vec<f32>>> {
        Ok(texts
            .into_iter()
            .map(|text| {
                let mut v = vec![0f32; HASH_EMBED_DIMS];
                for token in text.to_lowercase().split_whitespace() {
                    let mut hash: u64 = 1469598103934665603;
                    for b in token.bytes() {
                        hash ^= b as u64;
                        hash = hash.wrapping_mul(1099511628211);
                    }
                    v[(hash as usize) % HASH_EMBED_DIMS] += 1.0;
                }
                v
            })
            .collect())
    }

    fn model_name(&self) -> &str {
        "hash-test"
    }

    fn dims(&self) -> usize {
        HASH_EMBED_DIMS
    }
}

pub async fn state_with_search() -> AppState {
    let index = Arc::new(
        SqliteVectorIndex::connect(":memory:", HASH_EMBED_DIMS, "hash-test:64")
            .await
            .unwrap(),
    );
    state()
        .await
        .with_search(Arc::new(SearchService::new(Arc::new(HashEmbedder), index)))
}

/// Deterministic stand-in for the Whisper service: echoes the clip size so
/// tests can assert the transcript landed on the note without a container.
pub struct FakeTranscriber;

#[async_trait]
impl Transcriber for FakeTranscriber {
    async fn transcribe(&self, audio: Vec<u8>, _filename: &str) -> anyhow::Result<String> {
        Ok(format!("transcript of {} bytes", audio.len()))
    }
}

pub async fn state_with_transcription() -> AppState {
    state().await.with_transcription(Arc::new(FakeTranscriber))
}

/// Background indexing runs on spawned tasks; give them a beat to finish.
pub async fn settle_index() {
    tokio::time::sleep(std::time::Duration::from_millis(80)).await;
}

pub async fn app() -> Router {
    build_app(state().await)
}

pub async fn send(
    app: &Router,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let mut builder = Request::builder().method(method).uri(path);
    if let Some(t) = token {
        builder = builder.header(header::AUTHORIZATION, format!("Bearer {t}"));
    }
    let request = match body {
        Some(v) => builder
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(v.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    };
    let response = app.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    let value = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap_or(Value::Null)
    };
    (status, value)
}

pub fn test_email(name: &str) -> String {
    format!("{name}@example.test")
}

/// Registers a user and returns their (token, user_id).
pub async fn register(app: &Router, name: &str) -> (String, String) {
    let email = test_email(name);
    let (status, body) = send(
        app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"name": name, "email": email, "password": "hunter22"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "register {name}: {body}");
    (
        body["token"].as_str().unwrap().to_string(),
        body["user"]["id"].as_str().unwrap().to_string(),
    )
}

pub async fn create_note(app: &Router, token: &str, payload: Value) -> Value {
    let (status, body) = send(app, "POST", "/api/notes", Some(token), Some(payload)).await;
    assert_eq!(status, StatusCode::CREATED, "create note: {body}");
    body
}

pub async fn list_notes(app: &Router, token: &str) -> Vec<Value> {
    let (status, body) = send(app, "GET", "/api/notes", Some(token), None).await;
    assert_eq!(status, StatusCode::OK);
    body.as_array().unwrap().clone()
}

// ---------------------------------------------------------------------------
// Multipart upload helpers

pub fn multipart_body(mime: &str, bytes: &[u8]) -> (String, Vec<u8>) {
    let boundary = "XSTICKYBOUNDARY";
    let mut body = Vec::new();
    body.extend_from_slice(
        format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"pic\"\r\nContent-Type: {mime}\r\n\r\n"
        )
        .as_bytes(),
    );
    body.extend_from_slice(bytes);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    (format!("multipart/form-data; boundary={boundary}"), body)
}

pub async fn upload(
    app: &Router,
    token: &str,
    note_id: &str,
    mime: &str,
    bytes: &[u8],
) -> (StatusCode, Value) {
    let (content_type, body) = multipart_body(mime, bytes);
    let request = Request::builder()
        .method("POST")
        .uri(format!("/api/notes/{note_id}/attachments"))
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .header(header::CONTENT_TYPE, content_type)
        .body(Body::from(body))
        .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    let value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, value)
}

// ---------------------------------------------------------------------------
// LLM fakes

pub type LlmCalls = Arc<std::sync::Mutex<Vec<Vec<ChatMessage>>>>;

/// Deterministic LLM: replays scripted replies in order (the last one
/// repeats) and records every request, so tests can assert on call counts
/// and prompts without a model server.
pub struct FakeLlm {
    replies: std::sync::Mutex<Vec<String>>,
    calls: LlmCalls,
}

impl FakeLlm {
    pub fn new(reply: &str) -> (Arc<Self>, LlmCalls) {
        Self::new_seq(&[reply])
    }

    /// One reply per successive call; chat turns make two (route, answer).
    pub fn new_seq(replies: &[&str]) -> (Arc<Self>, LlmCalls) {
        let calls = Arc::new(std::sync::Mutex::new(Vec::new()));
        (
            Arc::new(Self {
                replies: std::sync::Mutex::new(replies.iter().map(|r| r.to_string()).collect()),
                calls: calls.clone(),
            }),
            calls,
        )
    }
}

#[async_trait]
impl Llm for FakeLlm {
    async fn complete(
        &self,
        _cfg: &LlmConfig,
        messages: Vec<ChatMessage>,
    ) -> anyhow::Result<String> {
        self.calls.lock().unwrap().push(messages);
        let mut replies = self.replies.lock().unwrap();
        Ok(if replies.len() > 1 {
            replies.remove(0)
        } else {
            replies[0].clone()
        })
    }

    async fn stream(
        &self,
        cfg: &LlmConfig,
        messages: Vec<ChatMessage>,
    ) -> anyhow::Result<sticky_notes_server::llm::TokenStream> {
        use futures::StreamExt;
        let reply = self.complete(cfg, messages).await?;
        let mid = reply.len() / 2;
        let chunks = vec![Ok(reply[..mid].to_string()), Ok(reply[mid..].to_string())];
        Ok(futures::stream::iter(chunks).boxed())
    }
}

/// An LLM whose every call fails, for probing error paths.
pub struct FailLlm;

#[async_trait]
impl Llm for FailLlm {
    async fn complete(&self, _: &LlmConfig, _: Vec<ChatMessage>) -> anyhow::Result<String> {
        anyhow::bail!("connection refused")
    }
    async fn stream(
        &self,
        _: &LlmConfig,
        _: Vec<ChatMessage>,
    ) -> anyhow::Result<sticky_notes_server::llm::TokenStream> {
        anyhow::bail!("connection refused")
    }
}

pub async fn state_with_llm(reply: &str) -> (AppState, LlmCalls) {
    let (llm, calls) = FakeLlm::new(reply);
    let state = state()
        .await
        .with_llm(llm)
        // Production waits 20 seconds. Keep tests fast while leaving enough
        // headroom for create/edit bursts when the integration suite runs all
        // 69 cases concurrently on a loaded machine.
        .with_label_delay(std::time::Duration::from_millis(250));
    (state, calls)
}

/// Store a working LLM config in the user's settings document.
pub async fn configure_llm(app: &Router, token: &str) {
    let (status, _) = send(
        app,
        "PUT",
        "/api/settings",
        Some(token),
        Some(json!({"llm_base_url": "http://fake/v1", "llm_model": "test-model"})),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

pub async fn make_label(app: &Router, token: &str, name: &str) -> String {
    let (status, body) = send(
        app,
        "POST",
        "/api/labels",
        Some(token),
        Some(json!({"name": name})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "create label {name}: {body}");
    body["id"].as_str().unwrap().to_string()
}

/// Labeling tasks wait out the (shrunken) debounce before calling the LLM.
pub async fn settle_labeling() {
    tokio::time::sleep(std::time::Duration::from_millis(750)).await;
}
