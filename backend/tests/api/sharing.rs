//! Collaborator rules on shared notes.

use crate::helpers::*;

#[tokio::test]
async fn share_grants_edit_but_not_trash_or_share() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, bob_id) = register(&app, "bob").await;
    register(&app, "eve").await;
    let note = create_note(&app, &ada, json!({"title": "shared doc"})).await;
    let id = note["id"].as_str().unwrap();

    // Ada shares with Bob by email.
    let (status, shared) = send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&ada),
        Some(json!({"email": "bob@example.test"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(shared["collaborators"][0]["id"], json!(bob_id));

    // Bob now sees and can edit the note.
    let bobs = list_notes(&app, &bob).await;
    assert_eq!(bobs.len(), 1);
    assert_eq!(bobs[0]["owner"]["name"], "ada");
    let (status, edited) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&bob),
        Some(json!({"content": "bob was here"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(edited["content"], "bob was here");

    // ... but cannot trash, delete, or share it further.
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&bob),
        Some(json!({"trashed": true})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/notes/{id}"),
        Some(&bob),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&bob),
        Some(json!({"email": "eve@example.test"})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // Sharing with an unknown user is a 400; sharing with yourself a 409.
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&ada),
        Some(json!({"email": "nobody@example.test"})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&ada),
        Some(json!({"email": "ada@example.test"})),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn collaborator_can_leave_and_owner_can_remove() {
    let app = app().await;
    let (ada, ada_id) = register(&app, "ada").await;
    let (bob, bob_id) = register(&app, "bob").await;
    let (eve, eve_id) = register(&app, "eve").await;
    let note = create_note(&app, &ada, json!({"title": "team"})).await;
    let id = note["id"].as_str().unwrap();
    for name in ["bob", "eve"] {
        let (status, _) = send(
            &app,
            "POST",
            &format!("/api/notes/{id}/collaborators"),
            Some(&ada),
            Some(json!({"email": test_email(name)})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }

    // Bob cannot kick Eve, but can leave himself.
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/notes/{id}/collaborators/{eve_id}"),
        Some(&bob),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/notes/{id}/collaborators/{bob_id}"),
        Some(&bob),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(list_notes(&app, &bob).await.len(), 0);

    // Owner removes Eve.
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/notes/{id}/collaborators/{eve_id}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(list_notes(&app, &eve).await.len(), 0);

    // Owner "removing" themselves is a 404 (they're not a collaborator row).
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/notes/{id}/collaborators/{ada_id}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn deleting_a_shared_note_removes_it_for_everyone() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let note = create_note(&app, &ada, json!({"title": "doomed"})).await;
    let id = note["id"].as_str().unwrap();
    send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&ada),
        Some(json!({"email": "bob@example.test"})),
    )
    .await;
    assert_eq!(list_notes(&app, &bob).await.len(), 1);

    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/notes/{id}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(list_notes(&app, &ada).await.len(), 0);
    assert_eq!(list_notes(&app, &bob).await.len(), 0);
}
