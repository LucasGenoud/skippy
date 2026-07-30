//! Board stages: CRUD, workspace scoping, and their independence from labels.

use crate::helpers::*;

async fn make_stage(app: &Router, token: &str, name: &str) -> String {
    let (status, stage) = send(
        app,
        "POST",
        "/api/stages",
        Some(token),
        Some(json!({ "name": name })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    stage["id"].as_str().unwrap().to_string()
}

#[tokio::test]
async fn stage_crud_is_scoped_to_the_workspace() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;

    let (status, created) = send(
        &app,
        "POST",
        "/api/stages",
        Some(&ada),
        Some(json!({"name": "Doing", "color": "#1A73E8"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(created["color"], "#1A73E8");
    let stage_id = created["id"].as_str().unwrap();

    // Duplicate names conflict within a workspace, not across two people's.
    let (status, _) = send(
        &app,
        "POST",
        "/api/stages",
        Some(&ada),
        Some(json!({"name": "doing"})),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    let (status, _) = send(
        &app,
        "POST",
        "/api/stages",
        Some(&bob),
        Some(json!({"name": "Doing"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    // Bob sees only his own board.
    let (_, stages) = send(&app, "GET", "/api/stages", Some(&bob), None).await;
    assert_eq!(stages.as_array().unwrap().len(), 1);

    // Put a note in Ada's column before Bob tries to mutate it. The delete
    // authorization check must happen before notes are unassigned.
    let note = create_note(&app, &ada, json!({"title": "stay assigned"})).await;
    let note_id = note["id"].as_str().unwrap();
    let (_, note) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{note_id}"),
        Some(&ada),
        Some(json!({"stage_id": stage_id})),
    )
    .await;
    assert_eq!(note["stage_id"], stage_id);

    // Bob cannot touch Ada's column.
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/stages/{stage_id}"),
        Some(&bob),
        Some(json!({"name": "mine now"})),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/stages/{stage_id}"),
        Some(&bob),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (_, note) = send(
        &app,
        "GET",
        &format!("/api/notes/{note_id}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(
        note["stage_id"], stage_id,
        "an unauthorized delete must not unassign notes"
    );

    // Renaming leaves the column where it is; an empty colour resets it.
    let (_, before) = send(&app, "GET", "/api/stages", Some(&ada), None).await;
    let position_before = before[0]["position"].as_f64().unwrap();
    let (status, updated) = send(
        &app,
        "PATCH",
        &format!("/api/stages/{stage_id}"),
        Some(&ada),
        Some(json!({"name": "In progress", "color": ""})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(updated["name"], "In progress");
    assert!(updated.get("color").is_none());
    assert_eq!(updated["position"].as_f64().unwrap(), position_before);
}

/// New columns append to the right, and an explicit position reorders them.
#[tokio::test]
async fn stages_are_ordered_left_to_right() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let todo = make_stage(&app, &ada, "Todo").await;
    make_stage(&app, &ada, "Doing").await;
    make_stage(&app, &ada, "Done").await;

    let (_, stages) = send(&app, "GET", "/api/stages", Some(&ada), None).await;
    let names: Vec<&str> = stages
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, vec!["Todo", "Doing", "Done"]);

    // Send Todo to the end.
    send(
        &app,
        "PATCH",
        &format!("/api/stages/{todo}"),
        Some(&ada),
        Some(json!({"name": "Todo", "position": 9999.0})),
    )
    .await;
    let (_, stages) = send(&app, "GET", "/api/stages", Some(&ada), None).await;
    let names: Vec<&str> = stages
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, vec!["Doing", "Done", "Todo"]);
}

#[tokio::test]
async fn note_stage_round_trips_and_clears() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let stage_id = make_stage(&app, &ada, "Doing").await;

    // A note starts unassigned, with its board order seeded from grid order.
    let note = create_note(&app, &ada, json!({"title": "n", "position": 512.0})).await;
    let id = note["id"].as_str().unwrap();
    assert!(note["stage_id"].is_null());
    assert_eq!(note["stage_position"].as_f64().unwrap(), 512.0);

    // Filing it in a column is one patch carrying both fields.
    let (status, view) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"stage_id": stage_id, "stage_position": 2048.0})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(view["stage_id"], stage_id);
    assert_eq!(view["stage_position"].as_f64().unwrap(), 2048.0);

    // An absent key leaves the stage alone...
    let (_, view) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"title": "renamed"})),
    )
    .await;
    assert_eq!(view["stage_id"], stage_id);

    // ...while an explicit null sends it back to unassigned.
    let (_, view) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"stage_id": null})),
    )
    .await;
    assert!(view["stage_id"].is_null());
}

/// A stage belongs to one workspace's board. A stray or foreign id is dropped
/// rather than honoured, the same rule labels get.
#[tokio::test]
async fn foreign_stage_never_sticks() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let bob_stage = make_stage(&app, &bob, "Doing").await;

    // On create.
    let note = create_note(
        &app,
        &ada,
        json!({"title": "n", "stage_id": bob_stage.clone()}),
    )
    .await;
    let id = note["id"].as_str().unwrap();
    assert!(note["stage_id"].is_null());

    // And on patch, including an id belonging to nobody.
    let (_, view) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"stage_id": bob_stage})),
    )
    .await;
    assert!(view["stage_id"].is_null());
    let (_, view) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"stage_id": "no-such-stage"})),
    )
    .await;
    assert!(view["stage_id"].is_null());
}

/// Deleting a column never deletes notes: they go back to unassigned.
#[tokio::test]
async fn deleting_a_stage_unassigns_its_notes() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let stage_id = make_stage(&app, &ada, "Doing").await;
    let note = create_note(&app, &ada, json!({"title": "keep me"})).await;
    let id = note["id"].as_str().unwrap();
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"stage_id": stage_id})),
    )
    .await;

    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/stages/{stage_id}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let (status, view) = send(&app, "GET", &format!("/api/notes/{id}"), Some(&ada), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(view["title"], "keep me");
    assert!(view["stage_id"].is_null());
}

/// A board belongs to its workspace, so a note that leaves takes no column
/// with it, the same reasoning that drops its old labels.
#[tokio::test]
async fn moving_workspaces_clears_the_stage() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let stage_id = make_stage(&app, &ada, "Doing").await;
    let (_, workspace) = send(
        &app,
        "POST",
        "/api/workspaces",
        Some(&ada),
        Some(json!({"name": "Side project"})),
    )
    .await;
    let workspace_id = workspace["id"].as_str().unwrap();

    let note = create_note(&app, &ada, json!({"title": "n"})).await;
    let id = note["id"].as_str().unwrap();
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"stage_id": stage_id})),
    )
    .await;

    let (status, view) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"workspace_id": workspace_id})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(view["workspace_id"], workspace_id);
    assert!(view["stage_id"].is_null());
}

/// Stages and labels are separate systems. Writing one must never write the
/// other, the guarantee that keeps the board out of the taxonomy's business.
#[tokio::test]
async fn stages_and_labels_do_not_touch_each_other() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let stage_id = make_stage(&app, &ada, "Doing").await;
    let label_id = make_label(&app, &ada, "work").await;

    let note = create_note(&app, &ada, json!({"title": "n"})).await;
    let id = note["id"].as_str().unwrap();
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"stage_id": stage_id, "label_ids": [label_id.clone()]})),
    )
    .await;

    // Moving between columns leaves the labels alone.
    let (_, view) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"stage_id": null})),
    )
    .await;
    assert_eq!(view["label_ids"], json!([label_id]));

    // Clearing the labels leaves the column alone.
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"stage_id": stage_id})),
    )
    .await;
    let (_, view) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"label_ids": []})),
    )
    .await;
    assert_eq!(view["label_ids"], json!([]));
    assert_eq!(view["stage_id"], stage_id);

    // Deleting the label does not disturb the board.
    send(
        &app,
        "DELETE",
        &format!("/api/labels/{label_id}"),
        Some(&ada),
        None,
    )
    .await;
    let (_, view) = send(&app, "GET", &format!("/api/notes/{id}"), Some(&ada), None).await;
    assert_eq!(view["stage_id"], stage_id);

    // And deleting the stage does not disturb the taxonomy.
    let other_label = make_label(&app, &ada, "later").await;
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"label_ids": [other_label.clone()]})),
    )
    .await;
    send(
        &app,
        "DELETE",
        &format!("/api/stages/{stage_id}"),
        Some(&ada),
        None,
    )
    .await;
    let (_, view) = send(&app, "GET", &format!("/api/notes/{id}"), Some(&ada), None).await;
    assert_eq!(view["label_ids"], json!([other_label]));
}
