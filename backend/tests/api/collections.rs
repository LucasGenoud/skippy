use crate::helpers::*;

#[tokio::test]
async fn collections_preserve_labels_and_scope_columns() {
    let app = app().await;
    let (token, _) = register(&app, "owner").await;
    let (_, workspaces) = send(&app, "GET", "/api/workspaces", Some(&token), None).await;
    let workspace = workspaces[0]["id"].as_str().unwrap();
    assert_eq!(workspaces[0]["collections"][0]["id"], "inbox");
    for id in ["recipes", "project"] {
        let (status, _) = send(
            &app,
            "PUT",
            &format!("/api/workspaces/{workspace}/collections/{id}"),
            Some(&token),
            Some(json!({"id":id,"name":id,"layout":"board"})),
        )
        .await;
        assert_eq!(status, StatusCode::NO_CONTENT);
    }
    let mut stages = vec![];
    for id in ["recipes", "project"] {
        let (status, stage) = send(
            &app,
            "POST",
            "/api/stages",
            Some(&token),
            Some(json!({"collection_id":id,"name":"Doing"})),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED);
        stages.push(stage["id"].as_str().unwrap().to_owned());
    }
    let (_, label) = send(
        &app,
        "POST",
        "/api/labels",
        Some(&token),
        Some(json!({"name":"Urgent"})),
    )
    .await;
    let note = create_note(&app, &token, json!({"title":"Recipe", "collection_id":"recipes", "stage_id":stages[0], "label_ids":[label["id"]]})).await;
    let path = format!("/api/notes/{}", note["id"].as_str().unwrap());
    let (status, moved) = send(
        &app,
        "PATCH",
        &path,
        Some(&token),
        Some(json!({"collection_id":"project"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(moved["collection_id"], "project");
    assert!(moved["stage_id"].is_null());
    assert_eq!(moved["label_ids"], note["label_ids"]);
    let (_, wrong) = send(
        &app,
        "PATCH",
        &path,
        Some(&token),
        Some(json!({"stage_id":stages[0]})),
    )
    .await;
    assert!(wrong["stage_id"].is_null());
    let (_, assigned) = send(
        &app,
        "PATCH",
        &path,
        Some(&token),
        Some(json!({"stage_id":stages[1]})),
    )
    .await;
    assert_eq!(assigned["stage_id"], stages[1]);
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/workspaces/{workspace}/collections/project"),
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, restored) = send(&app, "GET", &path, Some(&token), None).await;
    assert_eq!(restored["collection_id"], "inbox");
    assert_eq!(restored["label_ids"], note["label_ids"]);
    assert!(restored["stage_id"].is_null());
    assert_eq!(restored["content"], note["content"]);
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/workspaces/{workspace}/collections/inbox"),
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn collections_require_membership_even_for_direct_collaborators() {
    let app = app().await;
    let (owner, _) = register(&app, "owner").await;
    let (other, _) = register(&app, "other").await;
    let (_, ws) = send(&app, "GET", "/api/workspaces", Some(&owner), None).await;
    let workspace = ws[0]["id"].as_str().unwrap();
    let path = format!("/api/workspaces/{workspace}/collections/secret");
    let body = json!({"id":"secret","name":"Secret","layout":"masonry"});
    let (status, _) = send(&app, "PUT", &path, Some(&other), Some(body.clone())).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = send(&app, "PUT", &path, Some(&owner), Some(body)).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let note = create_note(
        &app,
        &owner,
        json!({"title":"Shared", "collection_id":"secret"}),
    )
    .await;
    let note_path = format!("/api/notes/{}", note["id"].as_str().unwrap());
    let (status, _) = send(
        &app,
        "POST",
        &format!("{note_path}/collaborators"),
        Some(&owner),
        Some(json!({"email":"other@example.test"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = send(
        &app,
        "PATCH",
        &note_path,
        Some(&other),
        Some(json!({"collection_id":"inbox"})),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = send(
        &app,
        "PATCH",
        &note_path,
        Some(&other),
        Some(json!({"title":"Edited"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = send(&app, "DELETE", &path, Some(&other), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/workspaces/{workspace}/members"),
        Some(&owner),
        Some(json!({"email":"other@example.test"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, moved) = send(
        &app,
        "PATCH",
        &note_path,
        Some(&other),
        Some(json!({"collection_id":"inbox"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(moved["collection_id"], "inbox");
}

#[tokio::test]
async fn duplicate_collection_names_are_permanent_conflicts() {
    let app = app().await;
    let (token, _) = register(&app, "owner").await;
    let (_, ws) = send(&app, "GET", "/api/workspaces", Some(&token), None).await;
    let workspace = ws[0]["id"].as_str().unwrap();
    for (id, expected) in [("a", StatusCode::NO_CONTENT), ("b", StatusCode::CONFLICT)] {
        let (status, _) = send(
            &app,
            "PUT",
            &format!("/api/workspaces/{workspace}/collections/{id}"),
            Some(&token),
            Some(json!({"id":id,"name":"Project","layout":"masonry"})),
        )
        .await;
        assert_eq!(status, expected);
    }
}

#[tokio::test]
async fn collections_and_notes_reject_invalid_or_foreign_destinations() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let (_, ada_workspaces) = send(&app, "GET", "/api/workspaces", Some(&ada), None).await;
    let (_, bob_workspaces) = send(&app, "GET", "/api/workspaces", Some(&bob), None).await;
    let ada_workspace = ada_workspaces[0]["id"].as_str().unwrap();
    let bob_workspace = bob_workspaces[0]["id"].as_str().unwrap();

    let (status, _) = send(
        &app,
        "PUT",
        &format!("/api/workspaces/{ada_workspace}/collections/bad"),
        Some(&ada),
        Some(json!({"id":"bad","name":"Bad","layout":"boardish"})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, _) = send(&app, "POST", "/api/notes", Some(&ada), Some(json!({"title":"wrong collection","workspace_id":ada_workspace,"collection_id":"missing"}))).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let (status, _) = send(
        &app,
        "POST",
        "/api/notes",
        Some(&ada),
        Some(
            json!({"title":"wrong workspace","workspace_id":bob_workspace,"collection_id":"inbox"}),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}
