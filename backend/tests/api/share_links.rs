//! Public read-only links: who may publish one, what an anonymous reader gets,
//! and what revoking or expiring one does.

use crate::helpers::*;

async fn default_workspace_id(app: &Router, token: &str) -> String {
    let (_, body) = send(app, "GET", "/api/workspaces", Some(token), None).await;
    body[0]["id"].as_str().unwrap().to_string()
}

async fn publish(app: &Router, token: &str, payload: Value) -> Value {
    let (status, body) = send(app, "POST", "/api/share-links", Some(token), Some(payload)).await;
    assert!(
        status == StatusCode::CREATED || status == StatusCode::OK,
        "publish: {status} {body}"
    );
    body
}

/// Fetch a public page the way an anonymous browser would: no token at all.
async fn public(app: &Router, token: &str) -> (StatusCode, Value) {
    send(app, "GET", &format!("/api/public/{token}"), None, None).await
}

#[tokio::test]
async fn a_note_link_serves_the_note_to_anyone_and_nobody_else() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let note = create_note(
        &app,
        &ada,
        json!({"title": "Focaccia", "content": "flour, water, salt"}),
    )
    .await;
    let id = note["id"].as_str().unwrap();
    let other = create_note(&app, &ada, json!({"title": "Private thoughts"})).await;

    let link = publish(&app, &ada, json!({"target": "note", "note_id": id})).await;
    assert_eq!(link["target"], "note");
    assert_eq!(link["title"], "Focaccia");
    let token = link["token"].as_str().unwrap();
    // A guessable token would make the whole feature pointless.
    assert!(token.len() >= 32, "token too short: {token}");

    let (status, share) = public(&app, token).await;
    assert_eq!(status, StatusCode::OK, "{share}");
    assert_eq!(share["target"], "note");
    assert_eq!(share["shared_by"], "ada");
    assert_eq!(share["notes"].as_array().unwrap().len(), 1);
    assert_eq!(share["notes"][0]["title"], "Focaccia");
    assert_eq!(share["notes"][0]["content"], "flour, water, salt");
    // The link is for one note; nothing else of Ada's rides along.
    let serialized = share.to_string();
    assert!(!serialized.contains("Private thoughts"));
    assert_eq!(other["title"], "Private thoughts");

    // An unknown token is a 404, not a hint that some tokens exist.
    let (status, _) = public(&app, "0123456789abcdef0123456789abcdef").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn a_public_note_carries_no_identities_and_no_private_state() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (_, bob_id) = register(&app, "bob").await;
    let note = create_note(
        &app,
        &ada,
        json!({
            "title": "Trip",
            "content": "book flights",
            "reminder_at": "2030-01-01T09:00:00Z",
        }),
    )
    .await;
    let id = note["id"].as_str().unwrap();
    send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&ada),
        Some(json!({"email": "bob@example.test"})),
    )
    .await;

    let link = publish(&app, &ada, json!({"target": "note", "note_id": id})).await;
    let (status, share) = public(&app, link["token"].as_str().unwrap()).await;
    assert_eq!(status, StatusCode::OK);

    let note = &share["notes"][0];
    // Everything public is opt-in (see PublicNote): no owner or collaborator
    // ids, no reminder, no archive/trash flags.
    assert!(note.get("owner").is_none());
    assert!(note.get("collaborators").is_none());
    assert!(note.get("reminder_at").is_none());
    assert!(note.get("archived").is_none());
    assert!(note.get("trashed").is_none());
    assert!(!share.to_string().contains(&bob_id));
    // The publisher's display name is the one identity that does go out.
    assert_eq!(share["shared_by"], "ada");
}

#[tokio::test]
async fn only_the_owner_may_publish_a_note() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    register(&app, "eve").await;
    let note = create_note(&app, &ada, json!({"title": "shared doc"})).await;
    let id = note["id"].as_str().unwrap();
    send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&ada),
        Some(json!({"email": "bob@example.test"})),
    )
    .await;

    // A collaborator can edit the note but cannot hand the world a link to it.
    let (status, _) = send(
        &app,
        "POST",
        "/api/share-links",
        Some(&bob),
        Some(json!({"target": "note", "note_id": id})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // A stranger gets 404: note ids leak nothing.
    let (eve, _) = register(&app, "eve2").await;
    let (status, _) = send(
        &app,
        "POST",
        "/api/share-links",
        Some(&eve),
        Some(json!({"target": "note", "note_id": id})),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // And publishing needs an account at all.
    let (status, _) = send(
        &app,
        "POST",
        "/api/share-links",
        None,
        Some(json!({"target": "note", "note_id": id})),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn a_view_link_serves_live_notes_of_one_workspace() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let workspace = default_workspace_id(&app, &ada).await;
    create_note(
        &app,
        &ada,
        json!({"title": "Live one", "workspace_id": workspace}),
    )
    .await;
    let archived = create_note(
        &app,
        &ada,
        json!({"title": "Filed away", "workspace_id": workspace, "archived": true}),
    )
    .await;
    let trashed = create_note(
        &app,
        &ada,
        json!({"title": "Thrown out", "workspace_id": workspace}),
    )
    .await;
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{}", trashed["id"].as_str().unwrap()),
        Some(&ada),
        Some(json!({"trashed": true})),
    )
    .await;

    // A second workspace must not bleed into the first one's page.
    let (_, other) = send(
        &app,
        "POST",
        "/api/workspaces",
        Some(&ada),
        Some(json!({"name": "Elsewhere"})),
    )
    .await;
    create_note(
        &app,
        &ada,
        json!({"title": "Other workspace", "workspace_id": other["id"]}),
    )
    .await;

    let link = publish(
        &app,
        &ada,
        json!({"target": "notes", "workspace_id": workspace}),
    )
    .await;
    let (status, share) = public(&app, link["token"].as_str().unwrap()).await;
    assert_eq!(status, StatusCode::OK, "{share}");
    let titles: Vec<&str> = share["notes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n["title"].as_str().unwrap())
        .collect();
    assert_eq!(titles, vec!["Live one"]);
    assert_eq!(archived["archived"], json!(true));
}

#[tokio::test]
async fn a_board_link_carries_its_columns() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let workspace = default_workspace_id(&app, &ada).await;
    let (_, stage) = send(
        &app,
        "POST",
        "/api/stages",
        Some(&ada),
        Some(json!({"name": "Doing", "workspace_id": workspace})),
    )
    .await;
    create_note(
        &app,
        &ada,
        json!({
            "title": "In progress",
            "workspace_id": workspace,
            "stage_id": stage["id"],
        }),
    )
    .await;

    let link = publish(
        &app,
        &ada,
        json!({"target": "board", "workspace_id": workspace}),
    )
    .await;
    let (status, share) = public(&app, link["token"].as_str().unwrap()).await;
    assert_eq!(status, StatusCode::OK, "{share}");
    assert_eq!(share["target"], "board");
    assert_eq!(share["stages"].as_array().unwrap().len(), 1);
    assert_eq!(share["stages"][0]["name"], "Doing");
    assert_eq!(share["notes"][0]["stage_id"], stage["id"]);
}

#[tokio::test]
async fn a_label_link_serves_that_label_and_only_the_labels_it_uses() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let workspace = default_workspace_id(&app, &ada).await;
    let (_, recipes) = send(
        &app,
        "POST",
        "/api/labels",
        Some(&ada),
        Some(json!({"name": "Recipes", "workspace_id": workspace})),
    )
    .await;
    let (_, secret) = send(
        &app,
        "POST",
        "/api/labels",
        Some(&ada),
        Some(json!({"name": "Taxes", "workspace_id": workspace})),
    )
    .await;
    create_note(
        &app,
        &ada,
        json!({
            "title": "Focaccia",
            "workspace_id": workspace,
            "label_ids": [recipes["id"]],
        }),
    )
    .await;
    create_note(
        &app,
        &ada,
        json!({
            "title": "Q3 filing",
            "workspace_id": workspace,
            "label_ids": [secret["id"]],
        }),
    )
    .await;

    let link = publish(
        &app,
        &ada,
        json!({"target": "label", "label_id": recipes["id"]}),
    )
    .await;
    let (status, share) = public(&app, link["token"].as_str().unwrap()).await;
    assert_eq!(status, StatusCode::OK, "{share}");
    assert_eq!(share["title"], "Recipes");
    assert_eq!(share["notes"].as_array().unwrap().len(), 1);
    assert_eq!(share["notes"][0]["title"], "Focaccia");
    // Only labels the page's notes actually wear, so a public page never
    // enumerates the workspace's whole taxonomy.
    let names: Vec<&str> = share["labels"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, vec!["Recipes"]);
}

#[tokio::test]
async fn only_the_workspace_owner_may_publish_a_view() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let (_, workspace) = send(
        &app,
        "POST",
        "/api/workspaces",
        Some(&ada),
        Some(json!({"name": "Team"})),
    )
    .await;
    let workspace_id = workspace["id"].as_str().unwrap();
    send(
        &app,
        "POST",
        &format!("/api/workspaces/{workspace_id}/members"),
        Some(&ada),
        Some(json!({"email": "bob@example.test"})),
    )
    .await;

    // Bob is a member, so he can write in it, but publishing it would expose
    // everyone's notes, and that stays the owner's call.
    let (status, _) = send(
        &app,
        "POST",
        "/api/share-links",
        Some(&bob),
        Some(json!({"target": "notes", "workspace_id": workspace_id})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn publishing_twice_returns_the_same_link() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let note = create_note(&app, &ada, json!({"title": "Focaccia"})).await;
    let id = note["id"].as_str().unwrap();

    let (first_status, first) = send(
        &app,
        "POST",
        "/api/share-links",
        Some(&ada),
        Some(json!({"target": "note", "note_id": id})),
    )
    .await;
    assert_eq!(first_status, StatusCode::CREATED);
    let (second_status, second) = send(
        &app,
        "POST",
        "/api/share-links",
        Some(&ada),
        Some(json!({"target": "note", "note_id": id})),
    )
    .await;
    assert_eq!(second_status, StatusCode::OK);
    assert_eq!(first["token"], second["token"]);

    let (_, links) = send(&app, "GET", "/api/share-links", Some(&ada), None).await;
    assert_eq!(links.as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn revoking_a_link_takes_the_page_down() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let note = create_note(&app, &ada, json!({"title": "Focaccia"})).await;
    let link = publish(
        &app,
        &ada,
        json!({"target": "note", "note_id": note["id"]}),
    )
    .await;
    let token = link["token"].as_str().unwrap();
    assert_eq!(public(&app, token).await.0, StatusCode::OK);

    // Holding the token is not the same as owning the link.
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/share-links/{token}"),
        Some(&bob),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(public(&app, token).await.0, StatusCode::OK);

    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/share-links/{token}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(public(&app, token).await.0, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn trashing_the_note_takes_its_page_down_too() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let note = create_note(&app, &ada, json!({"title": "Focaccia"})).await;
    let id = note["id"].as_str().unwrap();
    let link = publish(&app, &ada, json!({"target": "note", "note_id": id})).await;
    let token = link["token"].as_str().unwrap();

    send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"trashed": true})),
    )
    .await;
    assert_eq!(public(&app, token).await.0, StatusCode::NOT_FOUND);

    // Restoring brings the same link back, rather than stranding it.
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"trashed": false})),
    )
    .await;
    assert_eq!(public(&app, token).await.0, StatusCode::OK);

    // A note that is already in the trash cannot be published in the first
    // place.
    let doomed = create_note(&app, &ada, json!({"title": "Gone"})).await;
    let doomed_id = doomed["id"].as_str().unwrap();
    send(
        &app,
        "PATCH",
        &format!("/api/notes/{doomed_id}"),
        Some(&ada),
        Some(json!({"trashed": true})),
    )
    .await;
    let (status, _) = send(
        &app,
        "POST",
        "/api/share-links",
        Some(&ada),
        Some(json!({"target": "note", "note_id": doomed_id})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn an_expiry_is_validated_and_then_enforced() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let note = create_note(&app, &ada, json!({"title": "Focaccia"})).await;
    let id = note["id"].as_str().unwrap();

    for bad in ["not-a-date", "2000-01-01T00:00:00Z"] {
        let (status, _) = send(
            &app,
            "POST",
            "/api/share-links",
            Some(&ada),
            Some(json!({"target": "note", "note_id": id, "expires_at": bad})),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "expiry {bad} was accepted");
    }

    let link = publish(
        &app,
        &ada,
        json!({
            "target": "note",
            "note_id": id,
            "expires_at": "2030-01-01T00:00:00Z",
        }),
    )
    .await;
    assert_eq!(link["expires_at"], "2030-01-01T00:00:00Z");
    let (status, share) = public(&app, link["token"].as_str().unwrap()).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(share["expires_at"], "2030-01-01T00:00:00Z");
}

#[tokio::test]
async fn an_expired_link_reads_as_missing() {
    // The clock cannot be wound forward in-process, so the expiry is written
    // straight into the row the way a link created yesterday would look.
    let state = state().await;
    let app = build_app(state.clone());
    let (ada, ada_id) = register(&app, "ada").await;
    let note = create_note(&app, &ada, json!({"title": "Focaccia"})).await;

    let link = sticky_notes_server::models::ShareLink {
        token: "expired-token".to_string(),
        owner_id: ada_id,
        target: "note".to_string(),
        note_id: Some(note["id"].as_str().unwrap().to_string()),
        workspace_id: None,
        label_id: None,
        created_at: "2020-01-01T00:00:00Z".to_string(),
        expires_at: Some("2020-01-02T00:00:00Z".to_string()),
    };
    state.repo.insert_share_link(&link).await.unwrap();

    assert_eq!(public(&app, "expired-token").await.0, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn a_public_page_is_not_for_crawlers_or_shared_caches() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let note = create_note(&app, &ada, json!({"title": "Focaccia"})).await;
    let link = publish(
        &app,
        &ada,
        json!({"target": "note", "note_id": note["id"]}),
    )
    .await;

    let request = Request::builder()
        .method("GET")
        .uri(format!("/api/public/{}", link["token"].as_str().unwrap()))
        .body(Body::empty())
        .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response.headers().get("x-robots-tag").unwrap(),
        "noindex, nofollow"
    );
    assert_eq!(
        response.headers().get(header::CACHE_CONTROL).unwrap(),
        "private, no-store"
    );
}

#[tokio::test]
async fn attachments_come_with_signed_urls_that_work_without_a_session() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let note = create_note(&app, &ada, json!({"title": "Focaccia"})).await;
    let id = note["id"].as_str().unwrap();
    let (status, _) = upload(&app, &ada, id, "image/png", b"not-really-a-png").await;
    assert_eq!(status, StatusCode::CREATED);

    let link = publish(&app, &ada, json!({"target": "note", "note_id": id})).await;
    let (_, share) = public(&app, link["token"].as_str().unwrap()).await;
    let url = share["notes"][0]["attachments"][0]["url"]
        .as_str()
        .expect("attachment carries a signed url");

    // The signature is the credential here too: an anonymous reader loads the
    // bytes with no Authorization header at all.
    let (status, _) = send(&app, "GET", url, None, None).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn an_unknown_target_is_refused() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let note = create_note(&app, &ada, json!({"title": "Focaccia"})).await;
    let (status, _) = send(
        &app,
        "POST",
        "/api/share-links",
        Some(&ada),
        Some(json!({"target": "everything", "note_id": note["id"]})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // A target whose id is missing is a bad request, not a 500.
    let (status, _) = send(
        &app,
        "POST",
        "/api/share-links",
        Some(&ada),
        Some(json!({"target": "notes"})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}
