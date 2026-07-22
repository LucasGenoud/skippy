//! Label CRUD and per-user scoping.

use crate::helpers::*;

#[tokio::test]
async fn labels_are_personal_even_on_shared_notes() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;

    // Create labels; duplicates conflict per-owner but not across users.
    let (status, ada_label) = send(
        &app,
        "POST",
        "/api/labels",
        Some(&ada),
        Some(json!({"name": "work"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let (status, _) = send(
        &app,
        "POST",
        "/api/labels",
        Some(&ada),
        Some(json!({"name": "Work"})),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    let (status, bob_label) = send(
        &app,
        "POST",
        "/api/labels",
        Some(&bob),
        Some(json!({"name": "work"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    // Shared note: each participant tags with their own label and sees only theirs.
    let note = create_note(&app, &ada, json!({"title": "tagged"})).await;
    let id = note["id"].as_str().unwrap();
    send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&ada),
        Some(json!({"email": "bob@example.test"})),
    )
    .await;
    let ada_label_id = ada_label["id"].as_str().unwrap();
    let bob_label_id = bob_label["id"].as_str().unwrap();
    let (status, view) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"label_ids": [ada_label_id]})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(view["label_ids"], json!([ada_label_id]));
    let (status, view) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&bob),
        Some(json!({"label_ids": [bob_label_id]})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(view["label_ids"], json!([bob_label_id]));
    // Ada still sees only her label.
    let (_, view) = send(&app, "GET", &format!("/api/notes/{id}"), Some(&ada), None).await;
    assert_eq!(view["label_ids"], json!([ada_label_id]));

    // Bob can't attach Ada's label — it is silently not his to use.
    let (status, view) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&bob),
        Some(json!({"label_ids": [ada_label_id]})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(view["label_ids"], json!([]));
}

#[tokio::test]
async fn label_color_and_icon_round_trip() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;

    // Create carrying colour + icon.
    let (status, created) = send(
        &app,
        "POST",
        "/api/labels",
        Some(&ada),
        Some(json!({"name": "work", "color": "#1A73E8", "icon": "work"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(created["color"], "#1A73E8");
    assert_eq!(created["icon"], "work");
    let label_id = created["id"].as_str().unwrap();

    // They survive a list fetch.
    let (_, labels) = send(&app, "GET", "/api/labels", Some(&ada), None).await;
    assert_eq!(labels[0]["color"], "#1A73E8");
    assert_eq!(labels[0]["icon"], "work");

    // Update recolours + clears the icon (empty string resets to default).
    let (status, updated) = send(
        &app,
        "PATCH",
        &format!("/api/labels/{label_id}"),
        Some(&ada),
        Some(json!({"name": "work", "color": "#188038", "icon": ""})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(updated["color"], "#188038");
    // Cleared icon is omitted from the response (serde skips None).
    assert!(updated.get("icon").is_none());

    let (_, labels) = send(&app, "GET", "/api/labels", Some(&ada), None).await;
    assert_eq!(labels[0]["color"], "#188038");
    assert!(labels[0].get("icon").is_none());
}

#[tokio::test]
async fn label_rename_delete_scoped_to_owner() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let (_, label) = send(
        &app,
        "POST",
        "/api/labels",
        Some(&ada),
        Some(json!({"name": "todo"})),
    )
    .await;
    let label_id = label["id"].as_str().unwrap();

    // Bob can't touch Ada's label.
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/labels/{label_id}"),
        Some(&bob),
        Some(json!({"name": "mine now"})),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/labels/{label_id}"),
        Some(&bob),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // Ada renames then deletes; the label disappears from her notes.
    let note = create_note(&app, &ada, json!({"title": "n"})).await;
    let note_id = note["id"].as_str().unwrap();
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{note_id}"),
        Some(&ada),
        Some(json!({"label_ids": [label_id]})),
    )
    .await;
    let (status, renamed) = send(
        &app,
        "PATCH",
        &format!("/api/labels/{label_id}"),
        Some(&ada),
        Some(json!({"name": "renamed"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(renamed["name"], "renamed");
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/labels/{label_id}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, view) = send(
        &app,
        "GET",
        &format!("/api/notes/{note_id}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(view["label_ids"], json!([]));
}
