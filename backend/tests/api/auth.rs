//! Health check and the register/login/logout flows.

use crate::helpers::*;

#[tokio::test]
async fn health_works() {
    let app = app().await;
    let (status, body) = send(&app, "GET", "/api/health", None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["ok"], json!(true));
}

#[tokio::test]
async fn register_login_me_logout_flow() {
    let app = app().await;
    let (token, user_id) = register(&app, "ada").await;

    let (status, body) = send(&app, "GET", "/api/auth/me", Some(&token), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["name"], "ada");
    assert_eq!(body["email"], "ada@example.test");
    assert_eq!(body["id"], json!(user_id));

    // Fresh login issues a distinct working token.
    let (status, body) = send(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"email": "ADA@example.test", "password": "hunter22"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let token2 = body["token"].as_str().unwrap().to_string();
    assert_ne!(token, token2);

    // Logout kills only the token used.
    let (status, _) = send(&app, "POST", "/api/auth/logout", Some(&token), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _) = send(&app, "GET", "/api/auth/me", Some(&token), None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _) = send(&app, "GET", "/api/auth/me", Some(&token2), None).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn register_validation_and_duplicates() {
    let app = app().await;
    register(&app, "ada").await;

    let cases = [
        (
            json!({"name": "Someone Else", "email": "ADA@example.test", "password": "hunter22"}),
            StatusCode::CONFLICT,
        ),
        (
            json!({"name": "A", "email": "valid@example.test", "password": "hunter22"}),
            StatusCode::BAD_REQUEST,
        ),
        (
            json!({"name": "Valid Name", "email": "not-an-email", "password": "hunter22"}),
            StatusCode::BAD_REQUEST,
        ),
        (
            json!({"name": "Valid Name", "email": "valid@example.test", "password": "short"}),
            StatusCode::BAD_REQUEST,
        ),
    ];
    for (payload, expected) in cases {
        let (status, _) = send(
            &app,
            "POST",
            "/api/auth/register",
            None,
            Some(payload.clone()),
        )
        .await;
        assert_eq!(status, expected, "payload {payload}");
    }
}

#[tokio::test]
async fn login_rejects_bad_credentials() {
    let app = app().await;
    register(&app, "ada").await;
    for payload in [
        json!({"email": "ada", "password": "hunter22"}),
        json!({"email": "ada@example.test", "password": "wrong-password"}),
        json!({"email": "nobody@example.test", "password": "hunter22"}),
    ] {
        let (status, _) = send(&app, "POST", "/api/auth/login", None, Some(payload)).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
}

#[tokio::test]
async fn account_name_email_and_password_can_be_changed() {
    let app = app().await;
    let (token, user_id) = register(&app, "ada").await;

    let (status, body) = send(
        &app,
        "PATCH",
        "/api/auth/me",
        Some(&token),
        Some(json!({"name": "Ada Lovelace"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["name"], "Ada Lovelace");

    let (status, body) = send(
        &app,
        "PATCH",
        "/api/auth/me",
        Some(&token),
        Some(json!({
            "email": "ada.lovelace@example.test",
            "current_password": "hunter22"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["email"], "ada.lovelace@example.test");

    let (status, _) = send(
        &app,
        "PATCH",
        "/api/auth/me",
        Some(&token),
        Some(json!({
            "new_password": "analytical-engine",
            "current_password": "hunter22"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, _) = send(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"email": "ada@example.test", "password": "hunter22"})),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let (status, body) = send(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({
            "email": "ada.lovelace@example.test",
            "password": "analytical-engine"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["user"]["id"], user_id);
}

#[tokio::test]
async fn sensitive_account_changes_require_current_password() {
    let app = app().await;
    let (token, _) = register(&app, "ada").await;

    for payload in [
        json!({"email": "new@example.test"}),
        json!({"new_password": "new-secret", "current_password": "wrong"}),
    ] {
        let (status, _) = send(&app, "PATCH", "/api/auth/me", Some(&token), Some(payload)).await;
        assert_eq!(status, StatusCode::FORBIDDEN);
    }
}

#[tokio::test]
async fn deleting_an_account_removes_owned_workspaces_and_every_note_inside_them() {
    let app_state = state().await;
    let app = build_app(app_state.clone());
    let (ada, ada_id) = register(&app, "ada").await;
    let (grace, grace_id) = register(&app, "grace").await;
    let (linus, _) = register(&app, "linus").await;

    let (_, second_login) = send(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({
            "email": "ada@example.test",
            "password": "hunter22"
        })),
    )
    .await;
    let ada_second_token = second_login["token"].as_str().unwrap().to_string();

    let (_, ada_workspaces) = send(&app, "GET", "/api/workspaces", Some(&ada), None).await;
    let ada_default = ada_workspaces[0]["id"].as_str().unwrap();
    let (_, grace_workspaces) = send(&app, "GET", "/api/workspaces", Some(&grace), None).await;
    let grace_default = grace_workspaces[0]["id"].as_str().unwrap();
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/workspaces/{ada_default}/members"),
        Some(&ada),
        Some(json!({"email": "grace@example.test"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/workspaces/{grace_default}/members"),
        Some(&grace),
        Some(json!({"email": "ada@example.test"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let ada_note = create_note(&app, &ada, json!({"title": "Ada's note"})).await;
    let ada_note_id = ada_note["id"].as_str().unwrap();
    let (status, attachment) = upload(&app, &ada, ada_note_id, "text/plain", b"owned bytes").await;
    assert_eq!(status, StatusCode::CREATED);
    let attachment_id = attachment["id"].as_str().unwrap();
    assert!(app_state.files.read(attachment_id).await.is_some());

    let grace_note = create_note(
        &app,
        &grace,
        json!({
            "id": "grace-in-adas-workspace",
            "workspace_id": ada_default,
            "title": "Grace's note"
        }),
    )
    .await;
    let grace_note_id = grace_note["id"].as_str().unwrap();
    let (status, grace_attachment) =
        upload(&app, &grace, grace_note_id, "text/plain", b"grace bytes").await;
    assert_eq!(status, StatusCode::CREATED);
    let grace_attachment_id = grace_attachment["id"].as_str().unwrap();
    assert!(app_state.files.read(grace_attachment_id).await.is_some());
    let retained_note = create_note(
        &app,
        &ada,
        json!({
            "id": "ada-in-graces-workspace",
            "workspace_id": grace_default,
            "title": "Owned by Grace's workspace"
        }),
    )
    .await;
    assert_eq!(retained_note["owner"]["id"], grace_id);
    assert_eq!(
        app_state
            .repo
            .note_record("ada-in-graces-workspace")
            .await
            .unwrap()
            .unwrap()
            .created_by,
        Some(ada_id.clone())
    );
    let (status, retained_attachment) = upload(
        &app,
        &ada,
        "ada-in-graces-workspace",
        "text/plain",
        b"survives creator deletion",
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let retained_attachment_id = retained_attachment["id"].as_str().unwrap();

    // Grace's workspace owns this note, so Grace also owns its sharing
    // lifecycle even though Ada created it. Both grants must outlive Ada.
    let (status, _) = send(
        &app,
        "POST",
        "/api/notes/ada-in-graces-workspace/collaborators",
        Some(&grace),
        Some(json!({"email": "linus@example.test"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, public_link) = send(
        &app,
        "POST",
        "/api/share-links",
        Some(&grace),
        Some(json!({
            "target": "note",
            "note_id": "ada-in-graces-workspace"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let public_token = public_link["token"].as_str().unwrap().to_string();

    // A password typo must leave the account and both sessions untouched.
    let (status, _) = send(
        &app,
        "DELETE",
        "/api/auth/me",
        Some(&ada),
        Some(json!({"current_password": "wrong"})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(
        send(&app, "GET", "/api/auth/me", Some(&ada_second_token), None)
            .await
            .0,
        StatusCode::OK
    );

    let (status, _) = send(
        &app,
        "DELETE",
        "/api/auth/me",
        Some(&ada),
        Some(json!({"current_password": "hunter22"})),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    // Every session and every blob from the deleted workspace is gone.
    for token in [&ada, &ada_second_token] {
        assert_eq!(
            send(&app, "GET", "/api/auth/me", Some(token), None).await.0,
            StatusCode::UNAUTHORIZED
        );
    }
    assert!(app_state.files.read(attachment_id).await.is_none());
    assert!(app_state.files.read(grace_attachment_id).await.is_none());
    assert!(app_state.files.read(retained_attachment_id).await.is_some());

    // Grace keeps her account and default workspace, but her note was inside
    // Ada's workspace and is therefore deleted with that workspace.
    let (_, grace_workspaces) = send(&app, "GET", "/api/workspaces", Some(&grace), None).await;
    assert_eq!(grace_workspaces.as_array().unwrap().len(), 1);
    let notes = list_notes(&app, &grace).await;
    assert_eq!(notes.len(), 1);
    assert_eq!(notes[0]["id"], "ada-in-graces-workspace");
    assert_eq!(notes[0]["owner"]["id"], grace_id);
    let linus_notes = list_notes(&app, &linus).await;
    assert_eq!(linus_notes.len(), 1);
    assert_eq!(linus_notes[0]["id"], "ada-in-graces-workspace");
    let (status, public_page) = send(
        &app,
        "GET",
        &format!("/api/public/{public_token}"),
        None,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(public_page["notes"][0]["id"], "ada-in-graces-workspace");
    assert_eq!(
        app_state
            .repo
            .note_record("ada-in-graces-workspace")
            .await
            .unwrap()
            .unwrap()
            .created_by,
        None,
        "creator attribution is cleared without deleting the workspace-owned note"
    );

    // The email is free again because the account row itself was removed.
    let (status, _) = send(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({
            "name": "New Ada",
            "email": "ada@example.test",
            "password": "hunter22"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
}

#[tokio::test]
async fn endpoints_require_auth() {
    let app = app().await;
    for (method, path) in [
        ("GET", "/api/notes"),
        ("POST", "/api/notes"),
        ("GET", "/api/labels"),
        ("GET", "/api/auth/me"),
        ("PATCH", "/api/auth/me"),
        ("DELETE", "/api/auth/me"),
    ] {
        let (status, _) = send(&app, method, path, None, None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "{method} {path}");
    }
}
