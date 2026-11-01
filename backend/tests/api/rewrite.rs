//! AI rewrites: the replies a model really sends back, and what a rewrite
//! must never do to a note.

use std::sync::OnceLock;

use async_trait::async_trait;
use sticky_notes_server::llm::{ChatMessage, Llm, LlmConfig, TokenStream};

use crate::helpers::*;

async fn rewrite_app(llm: Arc<dyn Llm>) -> (Router, String) {
    let app = build_app(state().await.with_llm(llm));
    let (token, _) = register(&app, "rewriter").await;
    configure_llm(&app, &token).await;
    (app, token)
}

async fn rewrite(app: &Router, token: &str, id: &str) -> (StatusCode, Value) {
    send(
        app,
        "POST",
        &format!("/api/notes/{id}/rewrite"),
        Some(token),
        Some(json!({"task_id": "grammar"})),
    )
    .await
}

async fn groceries(app: &Router, token: &str) -> String {
    let note = create_note(
        app,
        token,
        json!({"title": "Groceries", "content": "buy milk"}),
    )
    .await;
    note["id"].as_str().unwrap().to_string()
}

async fn content_of(app: &Router, token: &str, id: &str) -> Value {
    let (_, note) = send(app, "GET", &format!("/api/notes/{id}"), Some(token), None).await;
    note["content"].clone()
}

#[tokio::test]
async fn a_rewrite_reads_json_wrapped_in_reasoning_and_prose() {
    let (llm, _) = FakeLlm::new(
        "<think>The user wants {grammar} fixed.</think>\nSure! Here is the edit:\n\
         ```json\n{\"title\": \"Groceries\", \"content\": \"Buy milk.\"}\n```\n\
         Let me know if you need anything else.",
    );
    let (app, token) = rewrite_app(llm).await;
    let id = groceries(&app, &token).await;

    let (status, body) = rewrite(&app, &token, &id).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["content"], "Buy milk.");
}

#[tokio::test]
async fn a_rewrite_keeps_the_title_when_the_model_leaves_it_out() {
    let (llm, _) = FakeLlm::new(r#"{"content": "Buy milk."}"#);
    let (app, token) = rewrite_app(llm).await;
    let id = groceries(&app, &token).await;

    let (status, body) = rewrite(&app, &token, &id).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["title"], "Groceries");
    assert_eq!(body["content"], "Buy milk.");
}

#[tokio::test]
async fn a_short_checklist_reply_gets_one_correction_round() {
    let (llm, calls) = FakeLlm::new_seq(&[
        r#"{"title": "Shop", "items": ["Milk"]}"#,
        r#"{"title": "Shop", "items": ["Milk", "Eggs"]}"#,
    ]);
    let (app, token) = rewrite_app(llm).await;
    let note = create_note(
        &app,
        &token,
        json!({
            "kind": "checklist",
            "title": "shop",
            "items": [
                {"id": "a", "text": "milk", "done": true},
                {"id": "b", "text": "eggs", "done": false},
            ],
        }),
    )
    .await;
    let id = note["id"].as_str().unwrap();

    let (status, body) = rewrite(&app, &token, id).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["items"][0]["text"], "Milk");
    assert_eq!(body["items"][0]["done"], true);
    assert_eq!(body["items"][1]["text"], "Eggs");
    let calls = calls.lock().unwrap();
    assert_eq!(calls.len(), 2);
    // The second round shows the model its own reply and what was wrong.
    let correction = calls[1].last().unwrap();
    assert_eq!(correction.role, "user");
    assert!(
        correction.content.contains("2 items"),
        "{}",
        correction.content
    );
}

#[tokio::test]
async fn a_rewrite_never_empties_a_note() {
    let (llm, calls) = FakeLlm::new(r#"{"title": "Groceries", "content": ""}"#);
    let (app, token) = rewrite_app(llm).await;
    let id = groceries(&app, &token).await;

    let (status, body) = rewrite(&app, &token, &id).await;

    assert_eq!(status, StatusCode::BAD_GATEWAY, "{body}");
    assert_eq!(content_of(&app, &token, &id).await, "buy milk");
    assert_eq!(calls.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn a_note_too_long_to_rewrite_is_refused_before_asking() {
    let (llm, calls) = FakeLlm::new(r#"{"title": "", "content": "x"}"#);
    let (app, token) = rewrite_app(llm).await;
    let note = create_note(&app, &token, json!({"content": "x".repeat(20_001)})).await;

    let (status, _) = rewrite(&app, &token, note["id"].as_str().unwrap()).await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(calls.lock().unwrap().is_empty());
}

/// Edits the note through the API while the model is still "thinking", the
/// way a collaborator (or another device) would.
#[derive(Default)]
struct EditsMeanwhile {
    app: OnceLock<Router>,
    token: OnceLock<String>,
    note: OnceLock<String>,
}

#[async_trait]
impl Llm for EditsMeanwhile {
    async fn complete(&self, _: &LlmConfig, _: Vec<ChatMessage>) -> anyhow::Result<String> {
        let (app, token, id) = (
            self.app.get().unwrap(),
            self.token.get().unwrap(),
            self.note.get().unwrap(),
        );
        let (status, _) = send(
            app,
            "PATCH",
            &format!("/api/notes/{id}"),
            Some(token),
            Some(json!({"content": "typed meanwhile"})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        Ok(r#"{"title": "Groceries", "content": "Buy milk."}"#.to_string())
    }

    async fn stream(&self, _: &LlmConfig, _: Vec<ChatMessage>) -> anyhow::Result<TokenStream> {
        unreachable!("rewrites never stream")
    }
}

#[tokio::test]
async fn a_rewrite_does_not_overwrite_an_edit_made_while_it_ran() {
    let llm = Arc::new(EditsMeanwhile::default());
    let (app, token) = rewrite_app(llm.clone()).await;
    let id = groceries(&app, &token).await;
    llm.app.set(app.clone()).ok();
    llm.token.set(token.clone()).ok();
    llm.note.set(id.clone()).ok();

    let (status, body) = rewrite(&app, &token, &id).await;

    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert_eq!(content_of(&app, &token, &id).await, "typed meanwhile");
}

struct ProviderDown;

#[async_trait]
impl Llm for ProviderDown {
    async fn complete(&self, _: &LlmConfig, _: Vec<ChatMessage>) -> anyhow::Result<String> {
        Err(anyhow::anyhow!("connect error: 10.0.0.9:11434 refused"))
    }

    async fn stream(&self, _: &LlmConfig, _: Vec<ChatMessage>) -> anyhow::Result<TokenStream> {
        Err(anyhow::anyhow!("connect error"))
    }
}

#[tokio::test]
async fn a_provider_that_does_not_answer_is_a_bad_gateway_not_a_crash() {
    let (app, token) = rewrite_app(Arc::new(ProviderDown)).await;
    let id = groceries(&app, &token).await;

    let (status, body) = rewrite(&app, &token, &id).await;

    assert_eq!(status, StatusCode::BAD_GATEWAY);
    // The reason is worded for the person; the provider's address is not.
    assert!(body["error"].as_str().unwrap().contains("did not answer"));
    assert!(!body.to_string().contains("10.0.0.9"));
}
