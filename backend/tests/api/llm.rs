//! LLM auto-labeling and connection probes.

use crate::helpers::*;

#[tokio::test]
async fn auto_labeling_applies_only_existing_labels() {
    let (state, calls) = state_with_llm(r#"["recipes", "nonexistent"]"#).await;
    let app = build_app(state);
    let (token, _) = register(&app, "ada").await;
    configure_llm(&app, &token).await;
    make_label(&app, &token, "work").await;
    let recipes_id = make_label(&app, &token, "recipes").await;

    create_note(&app, &token, json!({"title": "Pasta", "content": "tomato, basil"})).await;
    settle_labeling().await;

    let note = &list_notes(&app, &token).await[0];
    assert_eq!(note["label_ids"], json!([recipes_id]));
    // The prompt carried the label names and the note text.
    let calls = calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    let prompt = &calls[0].last().unwrap().content;
    assert!(prompt.contains("work") && prompt.contains("recipes"), "{prompt}");
    assert!(prompt.contains("tomato"), "{prompt}");
}

#[tokio::test]
async fn auto_labeling_is_add_only() {
    let (state, _) = state_with_llm(r#"["recipes"]"#).await;
    let app = build_app(state);
    let (token, _) = register(&app, "ada").await;
    configure_llm(&app, &token).await;
    let work_id = make_label(&app, &token, "work").await;
    let recipes_id = make_label(&app, &token, "recipes").await;

    // Manually label the note before the labeling task fires; the LLM's
    // suggestion must union with (not replace) the user's own label.
    let note = create_note(&app, &token, json!({"title": "Lasagna"})).await;
    let id = note["id"].as_str().unwrap();
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"label_ids": [work_id]})),
    )
    .await;
    settle_labeling().await;

    let note = &list_notes(&app, &token).await[0];
    let ids = note["label_ids"].as_array().unwrap();
    assert!(ids.contains(&json!(work_id)) && ids.contains(&json!(recipes_id)), "{ids:?}");
}

#[tokio::test]
async fn auto_labeling_empty_reply_removes_nothing() {
    let (state, _) = state_with_llm("[]").await;
    let app = build_app(state);
    let (token, _) = register(&app, "ada").await;
    configure_llm(&app, &token).await;
    let work_id = make_label(&app, &token, "work").await;

    let note = create_note(&app, &token, json!({"title": "Standup notes"})).await;
    let id = note["id"].as_str().unwrap();
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"label_ids": [work_id]})),
    )
    .await;
    settle_labeling().await;

    let note = &list_notes(&app, &token).await[0];
    assert_eq!(note["label_ids"], json!([work_id]));
}

#[tokio::test]
async fn auto_labeling_skipped_when_unconfigured_off_or_labelless() {
    // Unconfigured: no llm_* settings at all.
    let (state, calls) = state_with_llm(r#"["work"]"#).await;
    let app = build_app(state);
    let (token, _) = register(&app, "ada").await;
    make_label(&app, &token, "work").await;
    create_note(&app, &token, json!({"title": "meeting"})).await;
    settle_labeling().await;
    assert_eq!(calls.lock().unwrap().len(), 0, "unconfigured user must not call the LLM");

    // Configured but toggled off.
    let (state, calls) = state_with_llm(r#"["work"]"#).await;
    let app = build_app(state);
    let (token, _) = register(&app, "bob").await;
    let (status, _) = send(
        &app,
        "PUT",
        "/api/settings",
        Some(&token),
        Some(json!({
            "llm_base_url": "http://fake/v1", "llm_model": "m", "llm_labeling": false
        })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    make_label(&app, &token, "work").await;
    create_note(&app, &token, json!({"title": "meeting"})).await;
    settle_labeling().await;
    assert_eq!(calls.lock().unwrap().len(), 0, "toggle off must not call the LLM");

    // Configured and on, but the user has no labels to pick from.
    let (state, calls) = state_with_llm(r#"["work"]"#).await;
    let app = build_app(state);
    let (token, _) = register(&app, "eve").await;
    configure_llm(&app, &token).await;
    create_note(&app, &token, json!({"title": "meeting"})).await;
    settle_labeling().await;
    assert_eq!(calls.lock().unwrap().len(), 0, "no labels means nothing to assign");
}

#[tokio::test]
async fn auto_labeling_parses_fenced_reply() {
    let (state, _) = state_with_llm("```json\n[\"work\"]\n```").await;
    let app = build_app(state);
    let (token, _) = register(&app, "ada").await;
    configure_llm(&app, &token).await;
    let work_id = make_label(&app, &token, "work").await;

    create_note(&app, &token, json!({"title": "quarterly report"})).await;
    settle_labeling().await;

    let note = &list_notes(&app, &token).await[0];
    assert_eq!(note["label_ids"], json!([work_id]));
}

#[tokio::test]
async fn auto_labeling_debounces_rapid_edits() {
    let (state, calls) = state_with_llm(r#"["work"]"#).await;
    let app = build_app(state);
    let (token, _) = register(&app, "ada").await;
    configure_llm(&app, &token).await;
    make_label(&app, &token, "work").await;

    // A create plus a burst of content autosaves within the debounce window
    // must collapse into a single LLM call.
    let note = create_note(&app, &token, json!({"title": "draft"})).await;
    let id = note["id"].as_str().unwrap();
    for i in 1..=3 {
        let (status, _) = send(
            &app,
            "PATCH",
            &format!("/api/notes/{id}"),
            Some(&token),
            Some(json!({"content": format!("v{i} of the meeting agenda")})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }
    settle_labeling().await;
    assert_eq!(calls.lock().unwrap().len(), 1);

    // Organizational patches never re-trigger labeling.
    send(&app, "PATCH", &format!("/api/notes/{id}"), Some(&token), Some(json!({"pinned": true})))
        .await;
    settle_labeling().await;
    assert_eq!(calls.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn auto_labeling_skips_trashed_notes() {
    let (state, calls) = state_with_llm(r#"["work"]"#).await;
    let app = build_app(state);
    let (token, _) = register(&app, "ada").await;
    configure_llm(&app, &token).await;
    make_label(&app, &token, "work").await;

    // Trash the note before the labeling task wakes up: it must notice and bail.
    let note = create_note(&app, &token, json!({"title": "meeting"})).await;
    let id = note["id"].as_str().unwrap();
    send(&app, "PATCH", &format!("/api/notes/{id}"), Some(&token), Some(json!({"trashed": true})))
        .await;
    settle_labeling().await;
    assert_eq!(calls.lock().unwrap().len(), 0);
}

#[tokio::test]
async fn llm_test_endpoint_probes_and_validates() {
    // Happy path: the probe completion succeeds.
    let (ok_state, _) = state_with_llm("OK").await;
    let app = build_app(ok_state);
    let (token, _) = register(&app, "ada").await;
    let probe = json!({"base_url": "http://fake/v1", "api_key": "", "model": "m"});
    let (status, body) = send(&app, "POST", "/api/llm/test", Some(&token), Some(probe.clone())).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["ok"], json!(true));

    // Unreachable/failing provider: still 200, but ok:false with the reason.
    let fail_state = state().await.with_llm(Arc::new(FailLlm));
    let app2 = build_app(fail_state);
    let (token2, _) = register(&app2, "bob").await;
    let (status, body) = send(&app2, "POST", "/api/llm/test", Some(&token2), Some(probe.clone())).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["ok"], json!(false));
    assert!(body["error"].as_str().unwrap().contains("connection refused"));

    // Missing pieces are a client error; missing auth is unauthorized.
    let (status, _) = send(
        &app,
        "POST",
        "/api/llm/test",
        Some(&token),
        Some(json!({"base_url": "", "model": "m"})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = send(&app, "POST", "/api/llm/test", None, Some(probe)).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn note_rewrite_requires_opt_in_and_updates_content() {
    let (state, calls) = state_with_llm(r#"{"title":"Short title","content":"Correct sentence."}"#).await;
    let app = build_app(state);
    let (token, _) = register(&app, "ada").await;
    configure_llm(&app, &token).await;
    let note = create_note(&app, &token, json!({"title": "Long title", "content": "bad sentence"})).await;
    let id = note["id"].as_str().unwrap();

    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/notes/{id}/rewrite"),
        Some(&token),
        Some(json!({"mode": "grammar"})),
    )
    .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert!(calls.lock().unwrap().is_empty());

    let (status, _) = send(
        &app,
        "PUT",
        "/api/settings",
        Some(&token),
        Some(json!({
            "llm_base_url": "http://fake/v1",
            "llm_model": "test-model",
            "llm_labeling": false,
            "llm_writing": true,
        })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let (status, rewritten) = send(
        &app,
        "POST",
        &format!("/api/notes/{id}/rewrite"),
        Some(&token),
        Some(json!({"mode": "grammar"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(rewritten["title"], json!("Short title"));
    assert_eq!(rewritten["content"], json!("Correct sentence."));
    let prompt = calls.lock().unwrap()[0][0].content.clone();
    assert!(prompt.contains("grammar, spelling, punctuation, and syntax"));
    assert!(prompt.contains("plain text only, without Markdown syntax"));
    assert!(prompt.contains("Never translate it or switch languages"));

    let markdown_note = create_note(
        &app,
        &token,
        json!({"kind": "markdown", "title": "Readme", "content": "# bad heading"}),
    )
    .await;
    let markdown_id = markdown_note["id"].as_str().unwrap();
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/notes/{markdown_id}/rewrite"),
        Some(&token),
        Some(json!({"mode": "grammar"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let markdown_prompt = calls.lock().unwrap()[1][0].content.clone();
    assert!(markdown_prompt.contains("Markdown note"));
    assert!(!markdown_prompt.contains("plain text only"));
}
