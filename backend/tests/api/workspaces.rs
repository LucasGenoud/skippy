//! Workspaces: the default one, creation, membership, and the way notes and
//! labels are scoped to them.

use crate::helpers::*;

/// The workspaces a token can see, default first.
async fn workspaces(app: &Router, token: &str) -> Vec<Value> {
    let (status, body) = send(app, "GET", "/api/workspaces", Some(token), None).await;
    assert_eq!(status, StatusCode::OK, "list workspaces: {body}");
    body.as_array().unwrap().clone()
}

async fn default_workspace_id(app: &Router, token: &str) -> String {
    workspaces(app, token).await[0]["id"]
        .as_str()
        .unwrap()
        .to_string()
}

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

async fn invite(app: &Router, token: &str, workspace_id: &str, email: &str) -> (StatusCode, Value) {
    send(
        app,
        "POST",
        &format!("/api/workspaces/{workspace_id}/members"),
        Some(token),
        Some(json!({ "email": email })),
    )
    .await
}

#[tokio::test]
async fn registration_creates_one_default_workspace() {
    let app = app().await;
    let (ada, ada_id) = register(&app, "ada").await;

    let mine = workspaces(&app, &ada).await;
    assert_eq!(mine.len(), 1);
    assert_eq!(mine[0]["is_default"], json!(true));
    assert_eq!(mine[0]["notes_enabled"], json!(true));
    assert_eq!(mine[0]["board_enabled"], json!(true));
    assert_eq!(mine[0]["owner"]["id"], json!(ada_id));
    assert_eq!(mine[0]["members"], json!([]));

    // A note with no workspace named lands in it.
    let note = create_note(&app, &ada, json!({"title": "first"})).await;
    assert_eq!(note["workspace_id"], mine[0]["id"]);
}

#[tokio::test]
async fn workspaces_are_created_renamed_and_deleted_by_their_owner() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let default_id = default_workspace_id(&app, &ada).await;
    let work = make_workspace(&app, &ada, "Work").await;

    // Default first, then by creation time.
    let mine = workspaces(&app, &ada).await;
    assert_eq!(mine.len(), 2);
    assert_eq!(mine[0]["id"], json!(default_id));
    assert_eq!(mine[1]["name"], "Work");
    assert_eq!(mine[1]["is_default"], json!(false));

    // A blank name is rejected.
    let (status, _) = send(
        &app,
        "POST",
        "/api/workspaces",
        Some(&ada),
        Some(json!({"name": "   "})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Someone else's workspace is simply not there.
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/workspaces/{work}"),
        Some(&bob),
        Some(json!({"name": "mine now"})),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let (status, renamed) = send(
        &app,
        "PATCH",
        &format!("/api/workspaces/{work}"),
        Some(&ada),
        Some(json!({
            "name": "Day job",
            "notes_enabled": false,
            "board_enabled": true
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(renamed["name"], "Day job");
    assert_eq!(renamed["notes_enabled"], false);
    assert_eq!(renamed["board_enabled"], true);

    // A workspace always retains one primary way to display its notes.
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/workspaces/{work}"),
        Some(&ada),
        Some(json!({"board_enabled": false})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // The default workspace is permanent and cannot be deleted.
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/workspaces/{default_id}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/workspaces/{work}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(workspaces(&app, &ada).await.len(), 1);
}

#[tokio::test]
async fn members_see_the_workspace_notes_and_share_its_labels() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, bob_id) = register(&app, "bob").await;
    let work = make_workspace(&app, &ada, "Work").await;
    let note = create_note(
        &app,
        &ada,
        json!({"title": "roadmap", "workspace_id": work}),
    )
    .await;
    let note_id = note["id"].as_str().unwrap();

    // Before the invite the workspace does not exist as far as Bob knows.
    assert!(list_notes(&app, &bob).await.is_empty());
    let (status, _) = send(
        &app,
        "GET",
        &format!("/api/notes/{note_id}"),
        Some(&bob),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = send(
        &app,
        "POST",
        "/api/notes",
        Some(&bob),
        Some(json!({"title": "sneaky", "workspace_id": work})),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let (status, view) = invite(&app, &ada, &work, &test_email("bob")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(view["members"][0]["id"], json!(bob_id));

    // Bob now sees the note and can edit it, without a per-note share.
    let bobs = list_notes(&app, &bob).await;
    assert_eq!(bobs.len(), 1);
    assert_eq!(bobs[0]["id"], json!(note_id));
    assert_eq!(bobs[0]["collaborators"], json!([]));
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{note_id}"),
        Some(&bob),
        Some(json!({"content": "bob was here"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // Labels are the workspace's, so Bob's label is visible to Ada and can be
    // applied by either of them.
    let (status, label) = send(
        &app,
        "POST",
        "/api/labels",
        Some(&bob),
        Some(json!({"name": "urgent", "workspace_id": work})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let label_id = label["id"].as_str().unwrap();
    let (_, ada_labels) = send(&app, "GET", "/api/labels", Some(&ada), None).await;
    assert_eq!(ada_labels[0]["id"], json!(label_id));

    let (status, view) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{note_id}"),
        Some(&ada),
        Some(json!({"label_ids": [label_id]})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(view["label_ids"], json!([label_id]));
    let (_, bobs_view) = send(
        &app,
        "GET",
        &format!("/api/notes/{note_id}"),
        Some(&bob),
        None,
    )
    .await;
    assert_eq!(bobs_view["label_ids"], json!([label_id]));

    // Same name in another workspace is fine; a duplicate in this one is not.
    let (status, _) = send(
        &app,
        "POST",
        "/api/labels",
        Some(&ada),
        Some(json!({"name": "Urgent"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let (status, _) = send(
        &app,
        "POST",
        "/api/labels",
        Some(&ada),
        Some(json!({"name": "Urgent", "workspace_id": work})),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn workspace_owner_controls_member_created_note_lifecycle() {
    let app = app().await;
    let (ada, ada_id) = register(&app, "ada_workspace_note_owner").await;
    let (bob, _) = register(&app, "bob_workspace_note_creator").await;
    let work = make_workspace(&app, &ada, "Team").await;
    let (status, _) = invite(&app, &ada, &work, &test_email("bob_workspace_note_creator")).await;
    assert_eq!(status, StatusCode::OK);

    let note = create_note(
        &app,
        &bob,
        json!({"title": "created by member", "workspace_id": work}),
    )
    .await;
    let note_id = note["id"].as_str().unwrap();
    assert_eq!(note["owner"]["id"], ada_id);

    for (method, path, body) in [
        (
            "PATCH",
            format!("/api/notes/{note_id}"),
            Some(json!({"trashed": true})),
        ),
        ("DELETE", format!("/api/notes/{note_id}"), None),
        (
            "POST",
            format!("/api/notes/{note_id}/collaborators"),
            Some(json!({"email": test_email("ada_workspace_note_owner")})),
        ),
    ] {
        let (status, _) = send(&app, method, &path, Some(&bob), body).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{method} {path}");
    }

    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/notes/{note_id}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn only_the_owner_manages_the_roster_and_members_can_leave() {
    let app = app().await;
    let (ada, ada_id) = register(&app, "ada").await;
    let (bob, bob_id) = register(&app, "bob").await;
    register(&app, "eve").await;
    let work = make_workspace(&app, &ada, "Work").await;
    invite(&app, &ada, &work, &test_email("bob")).await;

    // Members cannot rename, delete, or invite.
    for (method, path, body) in [
        (
            "PATCH",
            format!("/api/workspaces/{work}"),
            Some(json!({"name": "bob's"})),
        ),
        ("DELETE", format!("/api/workspaces/{work}"), None),
        (
            "POST",
            format!("/api/workspaces/{work}/members"),
            Some(json!({"email": test_email("eve")})),
        ),
    ] {
        let (status, _) = send(&app, method, &path, Some(&bob), body).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{method} {path}");
    }

    // Inviting yourself is a conflict, and an unknown address is a bad request.
    let (status, _) = invite(&app, &ada, &work, &test_email("ada")).await;
    assert_eq!(status, StatusCode::CONFLICT);
    let (status, _) = invite(&app, &ada, &work, "nobody@example.test").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // The owner cannot be removed from their own workspace.
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/workspaces/{work}/members/{ada_id}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // Notes are owned by the workspace, so Bob's note stays there when he
    // leaves; creator identity is not a second ownership relation.
    let bobs_note = create_note(
        &app,
        &bob,
        json!({"title": "bob's plan", "workspace_id": work}),
    )
    .await;
    let bobs_note_id = bobs_note["id"].as_str().unwrap().to_string();
    let (_, stage) = send(
        &app,
        "POST",
        "/api/stages",
        Some(&bob),
        Some(json!({"name": "Doing", "workspace_id": work})),
    )
    .await;
    let (_, bobs_note) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{bobs_note_id}"),
        Some(&bob),
        Some(json!({"stage_id": stage["id"]})),
    )
    .await;
    assert_eq!(bobs_note["stage_id"], stage["id"]);
    let adas_note = create_note(
        &app,
        &ada,
        json!({"title": "ada's plan", "workspace_id": work}),
    )
    .await;

    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/workspaces/{work}/members/{bob_id}"),
        Some(&bob),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    assert!(list_notes(&app, &bob).await.is_empty());
    // Ada retains both workspace-owned notes, including Bob's staged note.
    let adas: Vec<Value> = list_notes(&app, &ada)
        .await
        .into_iter()
        .filter(|n| n["workspace_id"] == json!(work))
        .collect();
    assert_eq!(adas.len(), 2);
    let retained = adas.iter().find(|note| note["id"] == bobs_note_id).unwrap();
    assert_eq!(retained["stage_id"], stage["id"]);
    assert!(adas.iter().any(|note| note["id"] == adas_note["id"]));
}

#[tokio::test]
async fn deleting_a_workspace_permanently_removes_every_note_and_attachment() {
    let app_state = state_with_search().await;
    let app = build_app(app_state.clone());
    let (ada, _ada_id) = register(&app, "ada").await;
    let (bob, _bob_id) = register(&app, "bob").await;
    let (eve, _eve_id) = register(&app, "eve").await;
    let work = make_workspace(&app, &ada, "Work").await;
    invite(&app, &ada, &work, &test_email("bob")).await;

    let adas = create_note(
        &app,
        &ada,
        json!({"title": "ada's", "workspace_id": work, "pinned": true}),
    )
    .await;
    let adas_id = adas["id"].as_str().unwrap();
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/notes/{adas_id}/collaborators"),
        Some(&ada),
        Some(json!({"email": test_email("eve")})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let bobs = create_note(&app, &bob, json!({"title": "bob's", "workspace_id": work})).await;
    let bobs_id = bobs["id"].as_str().unwrap();
    let (_, label) = send(
        &app,
        "POST",
        "/api/labels",
        Some(&ada),
        Some(json!({"name": "shared", "workspace_id": work})),
    )
    .await;
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{adas_id}"),
        Some(&ada),
        Some(json!({"label_ids": [label["id"]]})),
    )
    .await;
    let (_, stage) = send(
        &app,
        "POST",
        "/api/stages",
        Some(&ada),
        Some(json!({"name": "Doing", "workspace_id": work})),
    )
    .await;
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{adas_id}"),
        Some(&ada),
        Some(json!({"stage_id": stage["id"], "content": "keep this"})),
    )
    .await;
    let (status, attachment) = upload(&app, &ada, adas_id, "image/png", b"pixels").await;
    assert_eq!(status, StatusCode::CREATED);
    let attachment_id = attachment["id"].as_str().unwrap();
    assert!(app_state.files.read(attachment_id).await.is_some());
    let (_, versions_before) = send(
        &app,
        "GET",
        &format!("/api/notes/{adas_id}/versions"),
        Some(&ada),
        None,
    )
    .await;
    assert!(!versions_before.as_array().unwrap().is_empty());
    settle_index().await;
    let hits = app_state
        .search
        .as_ref()
        .unwrap()
        .search(std::slice::from_ref(&work), "keep", 20)
        .await
        .unwrap();
    assert!(hits.iter().any(|(id, _)| id == adas_id));

    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/workspaces/{work}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    // The container, its taxonomy, every author's notes, direct shares,
    // versions, attachment metadata/bytes, and semantic rows are all gone.
    assert!(list_notes(&app, &ada).await.is_empty());
    assert!(list_notes(&app, &bob).await.is_empty());
    assert!(list_notes(&app, &eve).await.is_empty());

    let (status, _) = send(
        &app,
        "GET",
        &format!("/api/notes/{adas_id}/versions"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (_, labels) = send(&app, "GET", "/api/labels", Some(&ada), None).await;
    assert_eq!(labels, json!([]));
    assert!(app_state.files.read(attachment_id).await.is_none());

    settle_index().await;
    let hits = app_state
        .search
        .as_ref()
        .unwrap()
        .search(std::slice::from_ref(&work), "keep", 20)
        .await
        .unwrap();
    assert!(hits.iter().all(|(id, _)| id != adas_id));
    assert!(hits.iter().all(|(id, _)| id != bobs_id));
}

#[tokio::test]
async fn moving_a_note_is_owner_only_and_leaves_the_old_labels_behind() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let work = make_workspace(&app, &ada, "Work").await;
    invite(&app, &ada, &work, &test_email("bob")).await;
    let home = default_workspace_id(&app, &ada).await;

    let note = create_note(&app, &ada, json!({"title": "plan", "workspace_id": work})).await;
    let note_id = note["id"].as_str().unwrap();
    let work_label = make_label_in(&app, &ada, "project", &work).await;
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{note_id}"),
        Some(&ada),
        Some(json!({"label_ids": [work_label]})),
    )
    .await;

    // A member who does not own the note cannot move it out from under others.
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{note_id}"),
        Some(&bob),
        Some(json!({"workspace_id": default_workspace_id(&app, &bob).await})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // Nor can the owner file it somewhere they don't belong.
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{note_id}"),
        Some(&ada),
        Some(json!({"workspace_id": default_workspace_id(&app, &bob).await})),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // Moving it home drops the label, which belonged to the old workspace.
    let (status, moved) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{note_id}"),
        Some(&ada),
        Some(json!({"workspace_id": home})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(moved["workspace_id"], json!(home));
    assert_eq!(moved["label_ids"], json!([]));
    // And Bob, a member of the workspace it left, can no longer see it.
    assert!(list_notes(&app, &bob).await.is_empty());
}

#[tokio::test]
async fn semantic_search_can_be_scoped_to_one_workspace() {
    let app = build_app(state_with_search().await);
    let (ada, _) = register(&app, "ada").await;
    let work = make_workspace(&app, &ada, "Work").await;
    let home = default_workspace_id(&app, &ada).await;

    let personal = create_note(&app, &ada, json!({"title": "buy milk and bread"})).await;
    let job = create_note(
        &app,
        &ada,
        json!({"title": "buy milk for the office", "workspace_id": work}),
    )
    .await;
    settle_index().await;

    let hits = |body: Value| -> Vec<String> {
        body.as_array()
            .unwrap()
            .iter()
            .map(|hit| hit["note_id"].as_str().unwrap().to_string())
            .collect()
    };

    // Unscoped, both notes match.
    let (status, body) = send(&app, "GET", "/api/search?q=buy%20milk", Some(&ada), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(hits(body).len(), 2);

    let (_, body) = send(
        &app,
        "GET",
        &format!("/api/search?q=buy%20milk&workspace_id={work}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(hits(body), vec![job["id"].as_str().unwrap().to_string()]);

    let (_, body) = send(
        &app,
        "GET",
        &format!("/api/search?q=buy%20milk&workspace_id={home}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(
        hits(body),
        vec![personal["id"].as_str().unwrap().to_string()]
    );

    // Moving the note relocates its one vector between workspace collections.
    let personal_id = personal["id"].as_str().unwrap();
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{personal_id}"),
        Some(&ada),
        Some(json!({"workspace_id": work})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    settle_index().await;
    let (_, body) = send(
        &app,
        "GET",
        &format!("/api/search?q=buy%20milk&workspace_id={home}"),
        Some(&ada),
        None,
    )
    .await;
    assert!(hits(body).is_empty());
    let (_, body) = send(
        &app,
        "GET",
        &format!("/api/search?q=buy%20milk&workspace_id={work}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(hits(body).len(), 2);
}

async fn make_label_in(app: &Router, token: &str, name: &str, workspace_id: &str) -> String {
    let (status, body) = send(
        app,
        "POST",
        "/api/labels",
        Some(token),
        Some(json!({"name": name, "workspace_id": workspace_id})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "create label {name}: {body}");
    body["id"].as_str().unwrap().to_string()
}
