//! Note version history: capture, scoping, restore.

use crate::helpers::*;

async fn versions(app: &Router, token: &str, id: &str) -> Vec<Value> {
    let (status, body) = send(
        app,
        "GET",
        &format!("/api/notes/{id}/versions"),
        Some(token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "list versions: {body}");
    body.as_array().unwrap().clone()
}

#[tokio::test]
async fn history_captures_edits_and_restores() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let note = create_note(&app, &ada, json!({"title": "Draft", "content": "first"})).await;
    let id = note["id"].as_str().unwrap().to_string();

    // A fresh note has no history — nothing has changed yet.
    assert!(versions(&app, &ada, &id).await.is_empty());

    // The first content edit snapshots how the note started ("first").
    let patch = |c: &str| json!({ "content": c });
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(patch("second")),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    // A second quick edit by the same author coalesces into the same session.
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(patch("third")),
    )
    .await;

    let history = versions(&app, &ada, &id).await;
    assert_eq!(history.len(), 1, "same-session edits coalesce: {history:?}");
    assert_eq!(history[0]["content"], "first");
    assert_eq!(history[0]["title"], "Draft");
    assert_eq!(history[0]["edited_by"]["name"], "ada");

    // Restoring rolls content back and checkpoints the pre-restore state.
    let version_id = history[0]["id"].as_str().unwrap();
    let (status, restored) = send(
        &app,
        "POST",
        &format!("/api/notes/{id}/versions/{version_id}/restore"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(restored["content"], "first");

    let after = list_notes(&app, &ada).await;
    assert_eq!(after[0]["content"], "first");

    // History now holds the original plus the "third" checkpoint, newest first.
    let history = versions(&app, &ada, &id).await;
    assert_eq!(history.len(), 2);
    assert_eq!(history[0]["content"], "third");
    assert_eq!(history[1]["content"], "first");
}

#[tokio::test]
async fn organizational_edits_are_not_versioned() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let note = create_note(&app, &ada, json!({"title": "keep"})).await;
    let id = note["id"].as_str().unwrap().to_string();

    // Color, pin, archive, reminder — none of these are "content".
    for patch in [
        json!({"color": "red"}),
        json!({"pinned": true}),
        json!({"archived": true}),
    ] {
        let (status, _) = send(
            &app,
            "PATCH",
            &format!("/api/notes/{id}"),
            Some(&ada),
            Some(patch),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }
    assert!(versions(&app, &ada, &id).await.is_empty());

    // A real content change does create one.
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"title": "renamed"})),
    )
    .await;
    assert_eq!(versions(&app, &ada, &id).await.len(), 1);
}

#[tokio::test]
async fn history_is_scoped_to_participants() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (eve, _) = register(&app, "eve").await;
    let note = create_note(&app, &ada, json!({"title": "private"})).await;
    let id = note["id"].as_str().unwrap().to_string();
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"title": "v2"})),
    )
    .await;
    let version_id = versions(&app, &ada, &id).await[0]["id"]
        .as_str()
        .unwrap()
        .to_string();

    // A stranger can neither read the timeline nor restore from it — 404, so
    // note ids leak nothing (same posture as get_note).
    let (status, _) = send(
        &app,
        "GET",
        &format!("/api/notes/{id}/versions"),
        Some(&eve),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/notes/{id}/versions/{version_id}/restore"),
        Some(&eve),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn history_attributes_each_editor_on_shared_notes() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let note = create_note(&app, &ada, json!({"content": "start"})).await;
    let id = note["id"].as_str().unwrap().to_string();
    send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&ada),
        Some(json!({"email": "bob@example.test"})),
    )
    .await;

    // ada edits (snapshots the created state, authored by ada), then bob edits
    // (author switch snapshots ada's state), then ada again (snapshots bob's).
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"content": "a"})),
    )
    .await;
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&bob),
        Some(json!({"content": "b"})),
    )
    .await;
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"content": "c"})),
    )
    .await;

    let history = versions(&app, &ada, &id).await;
    assert_eq!(
        history.len(),
        3,
        "author switches open new sessions: {history:?}"
    );
    assert_eq!(history[0]["content"], "b");
    assert_eq!(history[0]["edited_by"]["name"], "bob");
    assert_eq!(history[1]["content"], "a");
    assert_eq!(history[1]["edited_by"]["name"], "ada");
    assert_eq!(history[2]["content"], "start");
    assert_eq!(history[2]["edited_by"]["name"], "ada");
}

#[tokio::test]
async fn deleting_a_note_purges_its_history() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let note = create_note(&app, &ada, json!({"title": "temp"})).await;
    let id = note["id"].as_str().unwrap().to_string();
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"title": "v2"})),
    )
    .await;
    assert_eq!(versions(&app, &ada, &id).await.len(), 1);

    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/notes/{id}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    // The note is gone, so its history endpoint 404s (cascade removed the rows).
    let (status, _) = send(
        &app,
        "GET",
        &format!("/api/notes/{id}/versions"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}
