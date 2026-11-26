//! Drawing and tracker notes: their content is client-written JSON (strokes,
//! a day-by-day log), which nothing that reads a note as text may treat as
//! words.

use crate::helpers::*;

/// Each data kind with content of its shape.
const DATA_NOTES: [(&str, &str); 2] = [
    ("drawing", r#"{"v":1,"s":[{"w":4,"p":[10,10,20,20]}]}"#),
    (
        "tracker",
        r#"{"v":1,"style":"count","log":{"2026-11-26":3}}"#,
    ),
];

async fn data_note(app: &Router, token: &str, kind: &str, content: &str) -> String {
    let note = create_note(
        app,
        token,
        json!({"kind": kind, "title": "Cat", "content": content}),
    )
    .await;
    assert_eq!(note["kind"], kind);
    assert_eq!(note["content"], content);
    note["id"].as_str().unwrap().to_string()
}

async fn mcp_token(app: &Router, session: &str) -> String {
    let (status, body) = send(
        app,
        "POST",
        "/api/tokens",
        Some(session),
        Some(json!({"name": "Claude", "scope": "write"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    body["secret"].as_str().unwrap().to_string()
}

async fn mcp_call(app: &Router, token: &str, name: &str, arguments: Value) -> Value {
    let (status, body) = send(
        app,
        "POST",
        "/api/mcp",
        Some(token),
        Some(json!({
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body["result"].clone()
}

#[tokio::test]
async fn data_notes_keep_their_content_and_patch_it() {
    let app = app().await;
    let (token, _) = register(&app, "ada").await;
    for (kind, content) in DATA_NOTES {
        let id = data_note(&app, &token, kind, content).await;

        let (status, note) = send(
            &app,
            "PATCH",
            &format!("/api/notes/{id}"),
            Some(&token),
            Some(json!({"content": "{}"})),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{note}");
        assert_eq!(note["content"], "{}");
    }
}

#[tokio::test]
async fn an_ai_rewrite_refuses_a_data_note() {
    let (llm, calls) = FakeLlm::new(r#"{"title": "Dog", "content": "x"}"#);
    let app = build_app(state().await.with_llm(llm));
    let (token, _) = register(&app, "ada").await;
    configure_llm(&app, &token).await;
    for (kind, content) in DATA_NOTES {
        let id = data_note(&app, &token, kind, content).await;

        let (status, _) = send(
            &app,
            "POST",
            &format!("/api/notes/{id}/rewrite"),
            Some(&token),
            Some(json!({"task_id": "grammar"})),
        )
        .await;

        assert_eq!(status, StatusCode::BAD_REQUEST, "{kind}");
    }
    assert!(calls.lock().unwrap().is_empty());
}

#[tokio::test]
async fn assistants_read_a_data_note_as_its_title_and_never_append_to_it() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let secret = mcp_token(&app, &ada).await;
    for (kind, content) in DATA_NOTES {
        let id = data_note(&app, &ada, kind, content).await;

        let read = mcp_call(&app, &secret, "get_note", json!({"id": id})).await;
        assert_eq!(read["isError"], false, "{read}");
        assert_eq!(read["structuredContent"]["title"], "Cat");
        assert_eq!(read["structuredContent"]["text"], "", "{kind}");

        let appended = mcp_call(
            &app,
            &secret,
            "append_to_note",
            json!({"id": id, "text": "whiskers"}),
        )
        .await;
        assert_eq!(appended["isError"], true, "{kind}: {appended}");
        let (_, note) = send(&app, "GET", &format!("/api/notes/{id}"), Some(&ada), None).await;
        assert_eq!(note["content"], content);
    }
}

#[tokio::test]
async fn an_untitled_data_note_has_nothing_to_index() {
    let app = build_app(state_with_search().await);
    let (ada, _) = register(&app, "ada").await;
    for (kind, content) in DATA_NOTES {
        create_note(&app, &ada, json!({"kind": kind, "content": content})).await;
    }
    settle_index().await;

    let (_, stats) = send(&app, "GET", "/api/search/stats", Some(&ada), None).await;
    assert_eq!(stats["total_notes"], json!(0));
    assert_eq!(stats["indexed_notes"], json!(0));
}
