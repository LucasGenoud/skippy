//! Workspace AI: every AI feature acting on a workspace's notes runs on its
//! owner's provider, behind switches only the owner flips.

use crate::helpers::*;

async fn make_workspace(app: &Router, token: &str, name: &str) -> String {
    let (status, body) = send(
        app,
        "POST",
        "/api/workspaces",
        Some(token),
        Some(json!({ "name": name })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "create workspace: {body}");
    body["id"].as_str().unwrap().to_string()
}

async fn invite(app: &Router, token: &str, workspace_id: &str, name: &str) {
    let (status, body) = send(
        app,
        "POST",
        &format!("/api/workspaces/{workspace_id}/members"),
        Some(token),
        Some(json!({ "email": test_email(name) })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "invite {name}: {body}");
}

async fn label_in(app: &Router, token: &str, name: &str, workspace_id: &str) {
    let (status, body) = send(
        app,
        "POST",
        "/api/labels",
        Some(token),
        Some(json!({ "name": name, "workspace_id": workspace_id })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "create label: {body}");
}

async fn workspace(app: &Router, token: &str, id: &str) -> Value {
    let (status, body) = send(app, "GET", "/api/workspaces", Some(token), None).await;
    assert_eq!(status, StatusCode::OK);
    body.as_array()
        .unwrap()
        .iter()
        .find(|w| w["id"] == id)
        .cloned()
        .unwrap_or_else(|| panic!("workspace {id} not listed: {body}"))
}

async fn default_workspace(app: &Router, token: &str) -> String {
    let (_, body) = send(app, "GET", "/api/workspaces", Some(token), None).await;
    body[0]["id"].as_str().unwrap().to_string()
}

async fn rewrite(app: &Router, token: &str, note_id: &str, task_id: &str) -> StatusCode {
    let (status, _) = send(
        app,
        "POST",
        &format!("/api/notes/{note_id}/rewrite"),
        Some(token),
        Some(json!({ "task_id": task_id })),
    )
    .await;
    status
}

#[tokio::test]
async fn members_get_ai_from_the_workspace_owners_provider() {
    let (state, configs) = state_with_llm_configs(r#"["work"]"#).await;
    let app = build_app(state);
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    configure_llm(&app, &ada).await;
    let team = make_workspace(&app, &ada, "Team").await;
    invite(&app, &ada, &team, "bob").await;
    label_in(&app, &ada, "work", &team).await;
    let bobs_own = default_workspace(&app, &bob).await;
    label_in(&app, &bob, "work", &bobs_own).await;

    // Bob has no provider of his own, yet his edit in Ada's workspace is
    // labeled with hers.
    create_note(
        &app,
        &bob,
        json!({"title": "standup", "workspace_id": team}),
    )
    .await;
    settle_labeling().await;
    {
        let configs = configs.lock().unwrap();
        assert_eq!(configs.len(), 1);
        assert_eq!(configs[0].base_url, "http://fake/v1");
        assert_eq!(configs[0].model, "test-model");
    }

    // His own workspace runs on his own provider, and he has none.
    create_note(&app, &bob, json!({"title": "standup"})).await;
    settle_labeling().await;
    assert_eq!(configs.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn the_owner_turns_ai_features_off_per_workspace() {
    let (state, calls) = state_with_llm(r#"["work"]"#).await;
    let app = build_app(state);
    let (ada, _) = register(&app, "ada").await;
    configure_llm(&app, &ada).await;
    let home = default_workspace(&app, &ada).await;
    let team = make_workspace(&app, &ada, "Team").await;
    label_in(&app, &ada, "work", &home).await;
    label_in(&app, &ada, "work", &team).await;

    // Everything starts on.
    let ai = &workspace(&app, &ada, &team).await["ai"];
    for switch in ["enabled", "labeling", "chat", "writing", "assistant_access"] {
        assert_eq!(ai[switch], true, "{switch} should default on: {ai}");
    }

    let (status, body) = send(
        &app,
        "PATCH",
        &format!("/api/workspaces/{team}"),
        Some(&ada),
        Some(json!({"ai": {"labeling": false}})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["ai"]["labeling"], false);
    assert_eq!(body["ai"]["chat"], true, "an unnamed switch is untouched");

    create_note(
        &app,
        &ada,
        json!({"title": "standup", "workspace_id": team}),
    )
    .await;
    settle_labeling().await;
    assert!(calls.lock().unwrap().is_empty(), "labeling is off in Team");
    create_note(&app, &ada, json!({"title": "standup"})).await;
    settle_labeling().await;
    assert_eq!(calls.lock().unwrap().len(), 1, "and still on at home");

    // The master switch stops the rest without forgetting their positions.
    let note = create_note(&app, &ada, json!({"title": "draft", "workspace_id": team})).await;
    let note_id = note["id"].as_str().unwrap();
    let (status, body) = send(
        &app,
        "PATCH",
        &format!("/api/workspaces/{team}"),
        Some(&ada),
        Some(json!({"ai": {"enabled": false}})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["ai"]["writing"], true);
    assert_eq!(
        rewrite(&app, &ada, note_id, "grammar").await,
        StatusCode::SERVICE_UNAVAILABLE
    );
}

#[tokio::test]
async fn only_the_owner_changes_ai_switches() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let team = make_workspace(&app, &ada, "Team").await;
    invite(&app, &ada, &team, "bob").await;

    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/workspaces/{team}"),
        Some(&bob),
        Some(json!({"ai": {"enabled": false}})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(workspace(&app, &ada, &team).await["ai"]["enabled"], true);
}

#[tokio::test]
async fn members_learn_what_ai_they_have_but_never_the_key() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let (status, _) = send(
        &app,
        "PUT",
        "/api/settings",
        Some(&ada),
        Some(json!({
            "llm_base_url": "http://fake/v1",
            "llm_model": "test-model",
            "llm_api_key": "sk-secret",
            "llm_rewrite_tasks": [{
                "id": "friendly",
                "name": "Make friendly",
                "prompt": "Use a warm, friendly tone."
            }]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let team = make_workspace(&app, &ada, "Team").await;
    invite(&app, &ada, &team, "bob").await;

    let (_, listed) = send(&app, "GET", "/api/workspaces", Some(&bob), None).await;
    let text = listed.to_string();
    assert!(!text.contains("sk-secret"), "{text}");
    assert!(!text.contains("warm, friendly"), "{text}");
    assert!(!text.contains("fake/v1"), "{text}");

    let ai = &workspace(&app, &bob, &team).await["ai"];
    assert_eq!(ai["provider_ready"], true);
    assert_eq!(
        ai["rewrite_tasks"],
        json!([{"id": "friendly", "name": "Make friendly"}])
    );

    let own = default_workspace(&app, &bob).await;
    let ai = &workspace(&app, &bob, &own).await["ai"];
    assert_eq!(ai["provider_ready"], false);
    assert_eq!(
        ai["rewrite_tasks"],
        json!([
            {"id": "concise", "name": "Make concise"},
            {"id": "grammar", "name": "Fix grammar"},
        ])
    );
}

#[tokio::test]
async fn a_member_rewrites_with_the_owners_tasks_and_instructions() {
    let (state, calls) = state_with_llm(r#"{"title":"Plan","content":"Hello!"}"#).await;
    let app = build_app(state);
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let (status, _) = send(
        &app,
        "PUT",
        "/api/settings",
        Some(&ada),
        Some(json!({
            "llm_base_url": "http://fake/v1",
            "llm_model": "test-model",
            "llm_prompt": "Keep it short",
            "llm_rewrite_tasks": [{
                "id": "friendly",
                "name": "Make friendly",
                "prompt": "Use a warm, friendly tone."
            }]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let team = make_workspace(&app, &ada, "Team").await;
    invite(&app, &ada, &team, "bob").await;
    let note = create_note(&app, &bob, json!({"title": "plan", "workspace_id": team})).await;

    let status = rewrite(&app, &bob, note["id"].as_str().unwrap(), "friendly").await;
    assert_eq!(status, StatusCode::OK);
    let prompt = calls.lock().unwrap()[0][0].content.clone();
    assert!(prompt.contains("warm, friendly tone"), "{prompt}");
    assert!(prompt.contains("Keep it short"), "{prompt}");
}

#[tokio::test]
async fn a_link_summary_follows_the_notes_workspace() {
    let (state, calls) = state_with_llm("A summary.").await;
    let app = build_app(state);
    let (ada, _) = register(&app, "ada").await;
    configure_llm(&app, &ada).await;
    let team = make_workspace(&app, &ada, "Team").await;
    let note = create_note(&app, &ada, json!({"title": "links", "workspace_id": team})).await;
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/workspaces/{team}"),
        Some(&ada),
        Some(json!({"ai": {"writing": false}})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // The page is never fetched: the switch is checked first.
    let (status, _) = send(
        &app,
        "POST",
        "/api/unfurl/summary",
        Some(&ada),
        Some(json!({"url": "https://example.com", "note_id": note["id"]})),
    )
    .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert!(calls.lock().unwrap().is_empty());
}

#[tokio::test]
async fn members_hear_when_the_owner_changes_provider() {
    let state = state().await;
    let app = build_app(state.clone());
    let (ada, _) = register(&app, "ada").await;
    let (_, bob_id) = register(&app, "bob").await;
    let team = make_workspace(&app, &ada, "Team").await;
    invite(&app, &ada, &team, "bob").await;
    let mut bobs_socket = state.hub.subscribe(&bob_id);

    // A theme change is Ada's alone.
    let (status, _) = send(
        &app,
        "PUT",
        "/api/settings",
        Some(&ada),
        Some(json!({"theme": "dark"})),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(bobs_socket.try_recv().is_err());

    // A provider changes what Bob can do in Team.
    configure_llm(&app, &ada).await;
    assert!(bobs_socket.try_recv().is_ok());
}
