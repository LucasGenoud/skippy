//! Per-note checklist suggestion history.

use crate::helpers::*;

#[tokio::test]
async fn checking_items_builds_note_scoped_history() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let note = create_note(
        &app,
        &ada,
        json!({"kind": "checklist", "items": [
            {"id": "i1", "text": "Milk", "done": false},
            {"id": "i2", "text": "Eggs", "done": false},
        ]}),
    )
    .await;
    let id = note["id"].as_str().unwrap();

    // Nothing recorded until something is checked.
    let (_, history) = send(&app, "GET", "/api/checklist-history", Some(&ada), None).await;
    assert_eq!(history, json!([]));

    // Check "Milk" -> recorded once, against this note. Re-sending the same
    // done state doesn't double count; unchecking and re-checking bumps the
    // use count.
    let check = |done: bool| {
        json!({"items": [
            {"id": "i1", "text": "Milk", "done": done},
            {"id": "i2", "text": "Eggs", "done": false},
        ]})
    };
    for patch in [check(true), check(true), check(false), check(true)] {
        let (status, _) =
            send(&app, "PATCH", &format!("/api/notes/{id}"), Some(&ada), Some(patch)).await;
        assert_eq!(status, StatusCode::OK);
    }
    let (_, history) = send(&app, "GET", "/api/checklist-history", Some(&ada), None).await;
    assert_eq!(history.as_array().unwrap().len(), 1);
    assert_eq!(history[0]["note_id"], *id);
    assert_eq!(history[0]["text"], "Milk");
    assert_eq!(history[0]["uses"], 2);

    // History follows note access: Bob sees none until the note is shared
    // with him, then he sees this note's history (a shared grocery list
    // shares its suggestions).
    let (_, history) = send(&app, "GET", "/api/checklist-history", Some(&bob), None).await;
    assert_eq!(history, json!([]));
    send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&ada),
        Some(json!({"username": "bob"})),
    )
    .await;
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&bob),
        Some(json!({"items": [
            {"id": "i1", "text": "Milk", "done": true},
            {"id": "i2", "text": "Eggs", "done": true},
        ]})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, history) = send(&app, "GET", "/api/checklist-history", Some(&bob), None).await;
    let texts: Vec<&str> =
        history.as_array().unwrap().iter().map(|e| e["text"].as_str().unwrap()).collect();
    assert!(texts.contains(&"Milk") && texts.contains(&"Eggs"));

    // Scoping: checks in Ada's second note land under that note's id, never
    // mixed into the first note's history.
    let other = create_note(
        &app,
        &ada,
        json!({"kind": "checklist", "items": [
            {"id": "j1", "text": "Sand paper", "done": true},
        ]}),
    )
    .await;
    let other_id = other["id"].as_str().unwrap();
    let (_, history) = send(&app, "GET", "/api/checklist-history", Some(&ada), None).await;
    for entry in history.as_array().unwrap() {
        if entry["text"] == "Sand paper" {
            assert_eq!(entry["note_id"], *other_id);
        } else {
            assert_eq!(entry["note_id"], *id);
        }
    }
}

#[tokio::test]
async fn precreated_checked_items_are_recorded() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let note = create_note(
        &app,
        &ada,
        json!({"kind": "checklist", "items": [
            {"id": "i1", "text": "Bread", "done": true},
            {"id": "i2", "text": "  ", "done": true},
        ]}),
    )
    .await;
    let (_, history) = send(&app, "GET", "/api/checklist-history", Some(&ada), None).await;
    // Whitespace-only texts are never recorded.
    assert_eq!(history.as_array().unwrap().len(), 1);
    assert_eq!(history[0]["text"], "Bread");
    assert_eq!(history[0]["note_id"], note["id"]);
}

