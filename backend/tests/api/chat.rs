//! Notes chat over WebSocket: routing, retrieval, and write actions.

use crate::helpers::*;

/// Drive one real /api/chat turn: spawn the app on a TCP port, connect with a
/// WS client, send a request frame, and collect frames until done/error.
async fn chat_turn(state: AppState, token: &str, message: &str, history: Value) -> Vec<Value> {
    use futures::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as WsMessage;

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, build_app(state)).await.unwrap();
    });

    let url = format!("ws://{addr}/api/chat");
    let (mut ws, _) = tokio_tungstenite::connect_async(url)
        .await
        .expect("ws connect");
    ws.send(WsMessage::text(
        json!({"token": token, "message": message, "history": history}).to_string(),
    ))
    .await
    .unwrap();

    let mut frames = Vec::new();
    while let Ok(Some(Ok(frame))) =
        tokio::time::timeout(std::time::Duration::from_secs(5), ws.next()).await
    {
        let WsMessage::Text(text) = frame else {
            continue;
        };
        let value: Value = serde_json::from_str(&text).unwrap();
        let kind = value["type"].as_str().unwrap_or_default().to_string();
        frames.push(value);
        if kind == "done" || kind == "error" {
            break;
        }
    }
    frames
}

/// The model routes each turn first: `{"search": "<its own query>"}` looks
/// notes up by what the conversation is ABOUT, regardless of how little the
/// literal message says.
#[tokio::test]
async fn chat_route_model_query_drives_retrieval() {
    let (llm, calls) = FakeLlm::new_seq(&[r#"{"search": "buy groceries bread"}"#, "Bread it is."]);
    let index = Arc::new(
        SqliteVectorIndex::connect(":memory:", HASH_EMBED_DIMS, "hash-test:64")
            .await
            .unwrap(),
    );
    let state = state()
        .await
        .with_search(Arc::new(SearchService::new(Arc::new(HashEmbedder), index)))
        .with_llm(llm);
    let app = build_app(state.clone());
    let (token, _) = register(&app, "ada").await;
    configure_llm(&app, &token).await;

    // Tokens shared with the MESSAGE point at junk; only the model-written
    // query points at the groceries note (HashEmbedder: whitespace tokens).
    // Half-checked checklist: the prompt must carry the per-item state.
    create_note(
        &app,
        &token,
        json!({
            "kind": "checklist",
            "title": "Groceries",
            "content": "buy groceries",
            "items": [
                {"id": "i1", "text": "bread", "done": true},
                {"id": "i2", "text": "milk", "done": false},
                {"id": "i3", "text": "potatoes", "done": false},
            ],
        }),
    )
    .await;
    for i in 0..7 {
        create_note(
            &app,
            &token,
            json!({"title": format!("junk {i}"), "content": format!("ok thing {i}")}),
        )
        .await;
    }
    settle_index().await;

    let frames = chat_turn(state, &token, "ok", json!([])).await;

    assert_eq!(frames.first().unwrap()["type"], "sources", "{frames:?}");
    let sources = frames[0]["notes"].as_array().unwrap();
    assert!(
        sources.iter().any(|s| s["title"] == "Groceries"),
        "the routed query must drive retrieval: {sources:?}"
    );
    assert_eq!(frames.last().unwrap()["type"], "done");
    // Two model calls: the route, then the answer over the retrieved notes —
    // with checklist state intact (checked bread vs pending milk).
    let calls = calls.lock().unwrap();
    assert_eq!(calls.len(), 2);
    assert!(
        calls[0][0].content.contains(r#"{"search":"#),
        "route prompt first"
    );
    let answer_prompt = &calls[1][0].content;
    assert!(answer_prompt.contains("- [x] bread"), "{answer_prompt}");
    assert!(answer_prompt.contains("- [ ] milk"), "{answer_prompt}");
    assert!(answer_prompt.contains("- [ ] potatoes"), "{answer_prompt}");
}

/// Vector ACLs update asynchronously. Revoking access in the primary store
/// must take effect immediately even while a stale vector row still names the
/// former collaborator.
#[tokio::test]
async fn chat_live_authorizes_stale_index_hits_after_revocation() {
    let (llm, calls) = FakeLlm::new_seq(&[r#"{"search": "classified zephyr"}"#, "Nothing found."]);
    let index = Arc::new(
        SqliteVectorIndex::connect(":memory:", HASH_EMBED_DIMS, "hash-test:64")
            .await
            .unwrap(),
    );
    let state = state()
        .await
        .with_search(Arc::new(SearchService::new(Arc::new(HashEmbedder), index)))
        .with_llm(llm);
    let app = build_app(state.clone());
    let (ada, _) = register(&app, "ada_stale_chat").await;
    let (bob, bob_id) = register(&app, "bob_stale_chat").await;
    configure_llm(&app, &bob).await;

    let note = create_note(
        &app,
        &ada,
        json!({
            "title": "Classified zephyr",
            "content": "vault combination is 1234"
        }),
    )
    .await;
    let note_id = note["id"].as_str().unwrap();
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/notes/{note_id}/collaborators"),
        Some(&ada),
        Some(json!({"email": test_email("bob_stale_chat")})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    settle_index().await;

    assert!(
        state
            .repo
            .remove_collaborator(note_id, &bob_id)
            .await
            .unwrap()
    );
    let stale = state
        .search
        .as_ref()
        .unwrap()
        .search(&bob_id, "classified zephyr", 8)
        .await
        .unwrap();
    assert!(stale.iter().any(|(id, _)| id == note_id));

    let frames = chat_turn(state, &bob, "what is in the vault?", json!([])).await;
    assert_eq!(frames.first().unwrap()["type"], "sources", "{frames:?}");
    assert_eq!(
        frames[0]["notes"],
        json!([]),
        "a stale vector row must not become a chat source"
    );
    let calls = calls.lock().unwrap();
    let answer_prompt = &calls.last().unwrap()[0].content;
    assert!(
        !answer_prompt.contains("vault combination is 1234"),
        "revoked note content reached the LLM: {answer_prompt}"
    );
}

/// A turn routed to `{"search": null}` (thanks, chit-chat) answers from the
/// conversation alone: no notes in the prompt and an empty sources frame, so
/// the client shows no chips — and the model can't trip over irrelevant
/// notes and disavow its previous answer.
#[tokio::test]
async fn chat_route_direct_skips_retrieval_and_sources() {
    let (llm, calls) = FakeLlm::new_seq(&[r#"{"search": null}"#, "You're welcome!"]);
    let index = Arc::new(
        SqliteVectorIndex::connect(":memory:", HASH_EMBED_DIMS, "hash-test:64")
            .await
            .unwrap(),
    );
    let state = state()
        .await
        .with_search(Arc::new(SearchService::new(Arc::new(HashEmbedder), index)))
        .with_llm(llm);
    let app = build_app(state.clone());
    let (token, _) = register(&app, "ada").await;
    configure_llm(&app, &token).await;
    create_note(
        &app,
        &token,
        json!({"title": "Groceries", "content": "bread"}),
    )
    .await;
    settle_index().await;

    let frames = chat_turn(
        state,
        &token,
        "nice thank you",
        json!([
            {"role": "user", "content": "what should I buy"},
            {"role": "assistant", "content": "Bread."},
        ]),
    )
    .await;

    // Empty sources frame -> no chips; then the streamed answer.
    assert_eq!(frames.first().unwrap()["type"], "sources", "{frames:?}");
    assert_eq!(
        frames[0]["notes"].as_array().unwrap().len(),
        0,
        "{frames:?}"
    );
    let text: String = frames
        .iter()
        .filter(|f| f["type"] == "delta")
        .map(|f| f["text"].as_str().unwrap_or_default())
        .collect();
    assert_eq!(text, "You're welcome!");
    assert_eq!(frames.last().unwrap()["type"], "done");
    // The answer prompt is the no-lookup variant, with the history intact.
    let calls = calls.lock().unwrap();
    let answer = calls.last().unwrap();
    assert!(
        answer[0].content.contains("no note lookup"),
        "{}",
        answer[0].content
    );
    assert!(!answer[0].content.contains("Notes:"));
    assert!(
        answer.iter().any(|m| m.content == "Bread."),
        "history preserved"
    );
}

/// A route reply the parser can't read (prose, wrong shape) must fall back
/// to plain retrieval — blending recent user turns so a low-content
/// follow-up ("nice") still surfaces the note the conversation is about.
#[tokio::test]
async fn chat_retrieval_follows_the_conversation_not_just_the_last_message() {
    let (llm, calls) = FakeLlm::new("Bread it is.");
    let index = Arc::new(
        SqliteVectorIndex::connect(":memory:", HASH_EMBED_DIMS, "hash-test:64")
            .await
            .unwrap(),
    );
    let state = state()
        .await
        .with_search(Arc::new(SearchService::new(Arc::new(HashEmbedder), index)))
        .with_llm(llm);
    let app = build_app(state.clone());
    let (token, _) = register(&app, "ada").await;
    configure_llm(&app, &token).await;

    // NOTE: the HashEmbedder tokenizes on whitespace only, so these strings
    // deliberately avoid punctuation to share exact tokens with the queries.
    create_note(
        &app,
        &token,
        json!({"title": "Groceries", "content": "buy groceries bread milk potatoes"}),
    )
    .await;
    // More decoys than the context window (6), every one sharing the
    // follow-up's only token — embedding "nice" alone would rank all of them
    // above the groceries note.
    for i in 0..7 {
        create_note(
            &app,
            &token,
            json!({"title": format!("junk {i}"), "content": format!("nice thing {i}")}),
        )
        .await;
    }
    settle_index().await;

    let frames = chat_turn(
        state,
        &token,
        "nice",
        json!([
            {"role": "user", "content": "what groceries should I buy"},
            {"role": "assistant", "content": "Bread, milk and potatoes."},
        ]),
    )
    .await;

    assert_eq!(frames.first().unwrap()["type"], "sources", "{frames:?}");
    let sources = frames[0]["notes"].as_array().unwrap();
    assert!(
        sources.iter().any(|s| s["title"] == "Groceries"),
        "groceries note must stay in the sources of a follow-up turn: {sources:?}"
    );
    // Streamed deltas concatenate to the model reply, then the turn closes.
    let text: String = frames
        .iter()
        .filter(|f| f["type"] == "delta")
        .map(|f| f["text"].as_str().unwrap_or_default())
        .collect();
    assert_eq!(text, "Bread it is.");
    assert_eq!(frames.last().unwrap()["type"], "done");
    // And the note text made it into the model's prompt.
    let calls = calls.lock().unwrap();
    let system = &calls.last().unwrap().first().unwrap().content;
    assert!(system.contains("bread milk potatoes"), "{system}");
}

/// A turn routed to `{"write": …}` runs the planner, which returns a note to
/// create — the server persists it and announces it with a `created` frame.
/// A successful write makes exactly two model calls (route + plan) and no
/// answer stream.
#[tokio::test]
async fn chat_write_creates_a_new_note() {
    let (llm, calls) = FakeLlm::new_seq(&[
        r#"{"write": "grocery list"}"#,
        r#"{"action":"create","kind":"checklist","title":"Groceries","items":["bread","milk"]}"#,
    ]);
    let index = Arc::new(
        SqliteVectorIndex::connect(":memory:", HASH_EMBED_DIMS, "hash-test:64")
            .await
            .unwrap(),
    );
    let state = state()
        .await
        .with_search(Arc::new(SearchService::new(Arc::new(HashEmbedder), index)))
        .with_llm(llm);
    let app = build_app(state.clone());
    let (token, _) = register(&app, "ada").await;
    configure_llm(&app, &token).await;

    let frames = chat_turn(
        state,
        &token,
        "make me a grocery list with bread and milk",
        json!([]),
    )
    .await;

    // The `created` frame carries the new note; a confirmation streams after.
    let created = frames
        .iter()
        .find(|f| f["type"] == "created")
        .expect("created frame");
    assert_eq!(created["action"], "create");
    assert_eq!(created["note"]["title"], "Groceries");
    let confirmation: String = frames
        .iter()
        .filter(|f| f["type"] == "delta")
        .map(|f| f["text"].as_str().unwrap_or_default())
        .collect();
    assert!(
        confirmation.contains("Groceries") && confirmation.contains("2 items"),
        "{confirmation}"
    );
    assert_eq!(frames.last().unwrap()["type"], "done");

    // The note was actually persisted, with its items.
    let notes = list_notes(&app, &token).await;
    let note = notes
        .iter()
        .find(|n| n["title"] == "Groceries")
        .expect("note persisted");
    assert_eq!(note["kind"], "checklist");
    let items: Vec<&str> = note["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["text"].as_str().unwrap())
        .collect();
    assert_eq!(items, ["bread", "milk"]);

    // Route + plan only; no answer stream on a successful write.
    assert_eq!(calls.lock().unwrap().len(), 2);
}

/// A write turn can add to an existing note: the planner picks a retrieved
/// candidate by id and returns items to append, which the server merges onto
/// the note's current items (the target id is validated against what was
/// actually retrieved).
#[tokio::test]
async fn chat_write_appends_to_an_existing_note() {
    let (llm, _calls) = FakeLlm::new_seq(&[
        r#"{"write": "groceries"}"#,
        r#"{"action":"append","note_id":"g1","items":["potatoes"]}"#,
    ]);
    let index = Arc::new(
        SqliteVectorIndex::connect(":memory:", HASH_EMBED_DIMS, "hash-test:64")
            .await
            .unwrap(),
    );
    let state = state()
        .await
        .with_search(Arc::new(SearchService::new(Arc::new(HashEmbedder), index)))
        .with_llm(llm);
    let app = build_app(state.clone());
    let (token, _) = register(&app, "ada").await;
    configure_llm(&app, &token).await;

    // Known id so the planner can target it; the shared token "groceries" lets
    // retrieval surface it as a candidate (HashEmbedder: whitespace tokens).
    create_note(
        &app,
        &token,
        json!({
            "id": "g1",
            "kind": "checklist",
            "title": "Groceries",
            "content": "buy groceries bread milk",
            "items": [{"id": "i1", "text": "bread", "done": false}],
        }),
    )
    .await;
    settle_index().await;

    let frames = chat_turn(state, &token, "add potatoes to my groceries", json!([])).await;

    let created = frames
        .iter()
        .find(|f| f["type"] == "created")
        .expect("created frame");
    assert_eq!(created["action"], "append");
    assert_eq!(created["note"]["id"], "g1");
    assert_eq!(frames.last().unwrap()["type"], "done");

    // The item was appended to the existing list, not replacing it.
    let notes = list_notes(&app, &token).await;
    let note = notes
        .iter()
        .find(|n| n["id"] == "g1")
        .expect("note still there");
    let items: Vec<&str> = note["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["text"].as_str().unwrap())
        .collect();
    assert_eq!(items, ["bread", "potatoes"]);
}
