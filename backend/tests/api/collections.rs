use crate::helpers::*;

async fn workspace(app: &Router, token: &str) -> Value {
    let (_, v) = send(app, "GET", "/api/workspaces", Some(token), None).await;
    v[0].clone()
}
async fn collection(app: &Router, token: &str, w: &str, id: &str, layout: &str) {
    let (status,v)=send(app,"PUT",&format!("/api/workspaces/{w}/collections/{id}"),Some(token),Some(json!({"id":id,"workspace_id":w,"name":id,"layout":layout,"sort":"custom","position":1.0,"icon":"book","color":"#00897B"}))).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{v}");
}

#[tokio::test]
async fn collections_membership_columns_and_moves() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let w = workspace(&app, &ada).await;
    let id = w["id"].as_str().unwrap();
    assert_eq!(w["collections"][0]["name"], "General");
    collection(&app, &ada, id, "reading", "board").await;
    let (status,_)=send(&app,"PUT",&format!("/api/workspaces/{id}/collections/reading"),Some(&bob),Some(json!({"id":"reading","workspace_id":id,"name":"No","layout":"board","sort":"custom","position":1.0}))).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    send(
        &app,
        "POST",
        &format!("/api/workspaces/{id}/members"),
        Some(&ada),
        Some(json!({"email":test_email("bob")})),
    )
    .await;
    collection(&app, &bob, id, "projects", "board").await;
    for c in ["reading", "projects"] {
        let (status, v) = send(
            &app,
            "POST",
            "/api/stages",
            Some(&bob),
            Some(
                json!({"workspace_id":id,"collection_id":c,"id":format!("{c}-todo"),"name":"Todo"}),
            ),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED, "{v}");
    }
    let n=create_note(&app,&ada,json!({"workspace_id":id,"collection_id":"reading","stage_id":"reading-todo","title":"Read"})).await;
    let (status, moved) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{}", n["id"].as_str().unwrap()),
        Some(&bob),
        Some(json!({"collection_id":"projects"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{moved}");
    assert_eq!(moved["collection_id"], "projects");
    assert!(moved["stage_id"].is_null());
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/workspaces/{id}/collections/projects"),
        Some(&bob),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, deleted) = send(
        &app,
        "GET",
        &format!("/api/notes/{}", n["id"].as_str().unwrap()),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(deleted["trashed"], true);
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{}", n["id"].as_str().unwrap()),
        Some(&ada),
        Some(json!({"trashed":false})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, restored) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{}", n["id"].as_str().unwrap()),
        Some(&bob),
        Some(json!({"trashed":false,"collection_id":"reading"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{restored}");
    assert_eq!(restored["collection_id"], "reading");
}

#[tokio::test]
async fn collections_workspace_duplication() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let w = workspace(&app, &ada).await;
    let id = w["id"].as_str().unwrap();
    collection(&app, &ada, id, "reading", "board").await;
    let (_, label) = send(
        &app,
        "POST",
        "/api/labels",
        Some(&ada),
        Some(json!({"name":"Books","workspace_id":id})),
    )
    .await;
    let (_, stage) = send(
        &app,
        "POST",
        "/api/stages",
        Some(&ada),
        Some(json!({"name":"Reading","workspace_id":id,"collection_id":"reading"})),
    )
    .await;
    let (status, _) = send(
        &app,
        "PUT",
        &format!("/api/workspaces/{id}/smart-views/books"),
        Some(&ada),
        Some(json!({"id":"books","name":"Books","query":"label:Books","position":1})),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let n = create_note(
        &app,
        &ada,
        json!({
            "workspace_id":id,"collection_id":"reading","title":"Copy me",
            "archived":true,"kind":"checklist","stage_id":stage["id"],"label_ids":[label["id"]],
            "items":[{"id":"task","text":"Read","done":false}],
            "item_reminders":[{"item_id":"task","reminder_at":"2099-01-01T00:00:00Z"}],
            "reminder_at":"2099-01-01T00:00:00Z"
        }),
    )
    .await;
    create_note(
        &app,
        &ada,
        json!({"title":"Trash stays behind","trashed":true}),
    )
    .await;
    for (mode, reminders) in [("structure", false), ("notes", false), ("notes", true)] {
        let (status, copy) = send(
            &app,
            "POST",
            &format!("/api/workspaces/{id}/duplicate"),
            Some(&ada),
            Some(json!({"name":"Copy","content":mode,"reminders":reminders})),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED, "{copy}");
        assert_eq!(copy["collections"].as_array().unwrap().len(), 2);
        assert_eq!(copy["members"], json!([]));
        assert_eq!(copy["smart_views"][0]["query"], "label:Books");
        assert_ne!(copy["smart_views"][0]["id"], "books");
        let collection = copy["collections"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["name"] == "reading")
            .unwrap();
        assert_eq!(collection["layout"], "board");
        assert_eq!(collection["icon"], "book");
        assert_eq!(collection["color"], "#00897B");
        let (_, all_labels) = send(&app, "GET", "/api/labels", Some(&ada), None).await;
        let copied_label = all_labels
            .as_array()
            .unwrap()
            .iter()
            .find(|l| l["workspace_id"] == copy["id"])
            .unwrap();
        assert_ne!(copied_label["id"], label["id"]);
        let (_, all_stages) = send(&app, "GET", "/api/stages", Some(&ada), None).await;
        let copied_stage = all_stages
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["workspace_id"] == copy["id"])
            .unwrap();
        assert_eq!(copied_stage["collection_id"], collection["id"]);
        let (_, all) = send(&app, "GET", "/api/notes", Some(&ada), None).await;
        let notes: Vec<_> = all
            .as_array()
            .unwrap()
            .iter()
            .filter(|n| n["workspace_id"] == copy["id"])
            .collect();
        assert_eq!(notes.len(), if mode == "notes" { 1 } else { 0 });
        if mode == "notes" {
            assert_ne!(notes[0]["id"], n["id"]);
            assert_eq!(notes[0]["reminder_at"].is_null(), !reminders);
            assert_eq!(
                notes[0]["item_reminders"].as_array().unwrap().len(),
                usize::from(reminders)
            );
            assert_eq!(notes[0]["title"], "Copy me");
            assert_eq!(notes[0]["archived"], true);
            assert_eq!(notes[0]["collection_id"], collection["id"]);
            assert_eq!(notes[0]["stage_id"], copied_stage["id"]);
            assert_eq!(notes[0]["label_ids"], json!([copied_label["id"]]));
            assert_eq!(notes[0]["collaborators"], json!([]));
        }
    }
}

#[tokio::test]
async fn collections_public_links_never_include_sibling_notes() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let w = workspace(&app, &ada).await;
    let wid = w["id"].as_str().unwrap();
    collection(&app, &ada, wid, "one", "board").await;
    collection(&app, &ada, wid, "two", "board").await;
    create_note(
        &app,
        &ada,
        json!({"workspace_id":wid,"collection_id":"one","title":"Public"}),
    )
    .await;
    create_note(
        &app,
        &ada,
        json!({"workspace_id":wid,"collection_id":"two","title":"Sibling"}),
    )
    .await;
    let (status, link) = send(
        &app,
        "POST",
        "/api/share-links",
        Some(&ada),
        Some(json!({"target":"board","workspace_id":wid,"collection_id":"one"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{link}");
    let path = format!("/api/public/{}", link["token"].as_str().unwrap());
    let (status, payload) = send(&app, "GET", &path, None, None).await;
    assert_eq!(status, StatusCode::OK, "{payload}");
    assert_eq!(payload["title"], "one");
    assert_eq!(payload["notes"].as_array().unwrap().len(), 1);
    assert_eq!(payload["notes"][0]["title"], "Public");
    send(
        &app,
        "DELETE",
        &format!("/api/workspaces/{wid}/collections/one"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(
        send(&app, "GET", &path, None, None).await.0,
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn collections_copy_attachments_and_member_owns_copy() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, bob_id) = register(&app, "bob").await;
    let w = workspace(&app, &ada).await;
    let wid = w["id"].as_str().unwrap();
    send(
        &app,
        "POST",
        &format!("/api/workspaces/{wid}/members"),
        Some(&ada),
        Some(json!({"email":test_email("bob")})),
    )
    .await;
    let note = create_note(&app, &ada, json!({"title":"Source"})).await;
    let (_, attachment) = upload(
        &app,
        &ada,
        note["id"].as_str().unwrap(),
        "image/png",
        b"independent bytes",
    )
    .await;
    let (status, copy) = send(
        &app,
        "POST",
        &format!("/api/workspaces/{wid}/duplicate"),
        Some(&bob),
        Some(json!({"name":"My copy","content":"notes"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{copy}");
    assert_eq!(copy["owner"]["id"], bob_id);
    assert_eq!(copy["members"], json!([]));
    let (_, notes) = send(&app, "GET", "/api/notes", Some(&bob), None).await;
    let copied = notes
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["workspace_id"] == copy["id"])
        .unwrap();
    assert_ne!(copied["attachments"][0]["id"], attachment["id"]);
    let url = copied["attachments"][0]["url"].as_str().unwrap();
    send(
        &app,
        "DELETE",
        &format!("/api/notes/{}", note["id"].as_str().unwrap()),
        Some(&ada),
        None,
    )
    .await;
    let response = app
        .clone()
        .oneshot(Request::builder().uri(url).body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .as_ref(),
        b"independent bytes"
    );
}

#[tokio::test]
async fn collections_failed_copy_rolls_back_destination() {
    let state = state().await;
    let app = build_app(state.clone());
    let (ada, _) = register(&app, "ada").await;
    let w = workspace(&app, &ada).await;
    let wid = w["id"].as_str().unwrap();
    let note = create_note(&app, &ada, json!({"title":"Source"})).await;
    let (_, attachment) = upload(
        &app,
        &ada,
        note["id"].as_str().unwrap(),
        "image/png",
        b"bytes",
    )
    .await;
    state
        .files
        .delete(attachment["id"].as_str().unwrap())
        .await
        .unwrap();
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/workspaces/{wid}/duplicate"),
        Some(&ada),
        Some(json!({"name":"Failed copy","content":"notes"})),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    let (_, workspaces) = send(&app, "GET", "/api/workspaces", Some(&ada), None).await;
    assert_eq!(workspaces.as_array().unwrap().len(), 1);
    let (_, notes) = send(&app, "GET", "/api/notes", Some(&ada), None).await;
    assert_eq!(notes.as_array().unwrap().len(), 1);
    assert_eq!(notes[0]["id"], note["id"]);
}
