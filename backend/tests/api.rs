use std::sync::Arc;

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode, header};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use tower::ServiceExt;

use sticky_notes_server::files::FileStore;
use async_trait::async_trait;
use sticky_notes_server::search::{SearchService, SqliteVectorIndex, TextEmbedder};
use sticky_notes_server::store::Repository;
use sticky_notes_server::store::sqlite::SqliteRepository;
use sticky_notes_server::transcribe::Transcriber;
use sticky_notes_server::{AppState, build_app};

// ---------------------------------------------------------------------------
// Harness

async fn state() -> AppState {
    let repo = Arc::new(SqliteRepository::connect(":memory:").await.unwrap());
    let dir = std::env::temp_dir().join(format!("sticky-notes-test-{}", uuid::Uuid::new_v4()));
    AppState::new(repo, FileStore::new(dir))
}

/// Deterministic bag-of-words embedder: shared tokens => similar vectors.
/// Lets the search pipeline be tested without the real ONNX model.
struct HashEmbedder;

impl TextEmbedder for HashEmbedder {
    fn embed(&self, texts: Vec<String>) -> anyhow::Result<Vec<Vec<f32>>> {
        Ok(texts
            .into_iter()
            .map(|text| {
                let mut v = vec![0f32; 64];
                for token in text.to_lowercase().split_whitespace() {
                    let mut hash: u64 = 1469598103934665603;
                    for b in token.bytes() {
                        hash ^= b as u64;
                        hash = hash.wrapping_mul(1099511628211);
                    }
                    v[(hash % 64) as usize] += 1.0;
                }
                v
            })
            .collect())
    }
}

async fn state_with_search() -> AppState {
    let index = Arc::new(SqliteVectorIndex::connect(":memory:").await.unwrap());
    state()
        .await
        .with_search(Arc::new(SearchService::new(Arc::new(HashEmbedder), index)))
}

/// Deterministic stand-in for the Whisper service: echoes the clip size so
/// tests can assert the transcript landed on the note without a container.
struct FakeTranscriber;

#[async_trait]
impl Transcriber for FakeTranscriber {
    async fn transcribe(&self, audio: Vec<u8>, _filename: &str) -> anyhow::Result<String> {
        Ok(format!("transcript of {} bytes", audio.len()))
    }
}

async fn state_with_transcription() -> AppState {
    state().await.with_transcription(Arc::new(FakeTranscriber))
}

/// Background indexing runs on spawned tasks; give them a beat to finish.
async fn settle_index() {
    tokio::time::sleep(std::time::Duration::from_millis(80)).await;
}

async fn app() -> Router {
    build_app(state().await)
}

async fn send(
    app: &Router,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let mut builder = Request::builder().method(method).uri(path);
    if let Some(t) = token {
        builder = builder.header(header::AUTHORIZATION, format!("Bearer {t}"));
    }
    let request = match body {
        Some(v) => builder
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(v.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    };
    let response = app.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    let value = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap_or(Value::Null)
    };
    (status, value)
}

/// Registers a user and returns their (token, user_id).
async fn register(app: &Router, username: &str) -> (String, String) {
    let (status, body) = send(
        app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": username, "password": "hunter22"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "register {username}: {body}");
    (
        body["token"].as_str().unwrap().to_string(),
        body["user"]["id"].as_str().unwrap().to_string(),
    )
}

async fn create_note(app: &Router, token: &str, payload: Value) -> Value {
    let (status, body) = send(app, "POST", "/api/notes", Some(token), Some(payload)).await;
    assert_eq!(status, StatusCode::CREATED, "create note: {body}");
    body
}

async fn list_notes(app: &Router, token: &str) -> Vec<Value> {
    let (status, body) = send(app, "GET", "/api/notes", Some(token), None).await;
    assert_eq!(status, StatusCode::OK);
    body.as_array().unwrap().clone()
}

// ---------------------------------------------------------------------------
// Health & auth

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
    assert_eq!(body["username"], "ada");
    assert_eq!(body["id"], json!(user_id));

    // Fresh login issues a distinct working token.
    let (status, body) = send(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"username": "ada", "password": "hunter22"})),
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
        (json!({"username": "ada", "password": "hunter22"}), StatusCode::CONFLICT),
        (json!({"username": "AdA", "password": "hunter22"}), StatusCode::CONFLICT), // case-insensitive
        (json!({"username": "ab", "password": "hunter22"}), StatusCode::BAD_REQUEST),
        (json!({"username": "has space", "password": "hunter22"}), StatusCode::BAD_REQUEST),
        (json!({"username": "fine-name", "password": "short"}), StatusCode::BAD_REQUEST),
    ];
    for (payload, expected) in cases {
        let (status, _) = send(&app, "POST", "/api/auth/register", None, Some(payload.clone())).await;
        assert_eq!(status, expected, "payload {payload}");
    }
}

#[tokio::test]
async fn login_rejects_bad_credentials() {
    let app = app().await;
    register(&app, "ada").await;
    for payload in [
        json!({"username": "ada", "password": "wrong-password"}),
        json!({"username": "nobody", "password": "hunter22"}),
    ] {
        let (status, _) = send(&app, "POST", "/api/auth/login", None, Some(payload)).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
}

#[tokio::test]
async fn endpoints_require_auth() {
    let app = app().await;
    for (method, path) in [
        ("GET", "/api/notes"),
        ("POST", "/api/notes"),
        ("GET", "/api/labels"),
        ("GET", "/api/auth/me"),
    ] {
        let (status, _) = send(&app, method, path, None, None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "{method} {path}");
    }
}

// ---------------------------------------------------------------------------
// Notes CRUD & scoping

#[tokio::test]
async fn create_defaults_and_patch() {
    let app = app().await;
    let (token, user_id) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({"title": "Hello", "content": "world"})).await;
    assert_eq!(note["kind"], "text");
    assert_eq!(note["color"], "default");
    assert_eq!(note["pinned"], json!(false));
    assert_eq!(note["owner"]["id"], json!(user_id));
    assert_eq!(note["items"], json!([]));

    let id = note["id"].as_str().unwrap();
    let (status, updated) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"title": "Hi", "color": "teal", "pinned": true})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(updated["title"], "Hi");
    assert_eq!(updated["color"], "teal");
    assert_eq!(updated["pinned"], json!(true));
    assert_eq!(updated["content"], "world"); // untouched
}

#[tokio::test]
async fn notes_are_scoped_per_user() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let note = create_note(&app, &ada, json!({"title": "private"})).await;

    assert_eq!(list_notes(&app, &ada).await.len(), 1);
    assert_eq!(list_notes(&app, &bob).await.len(), 0);

    // A stranger gets 404 (not 403) on someone else's note.
    let id = note["id"].as_str().unwrap();
    for method in ["GET", "PATCH", "DELETE"] {
        let body = (method == "PATCH").then(|| json!({"title": "hacked"}));
        let (status, _) = send(&app, method, &format!("/api/notes/{id}"), Some(&bob), body).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{method}");
    }
}

#[tokio::test]
async fn client_generated_ids_conflict_on_reuse() {
    let app = app().await;
    let (token, _) = register(&app, "ada").await;
    create_note(&app, &token, json!({"id": "my-id", "title": "one"})).await;
    let (status, _) =
        send(&app, "POST", "/api/notes", Some(&token), Some(json!({"id": "my-id"}))).await;
    assert_eq!(status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn checklist_items_roundtrip_and_kind_validation() {
    let app = app().await;
    let (token, _) = register(&app, "ada").await;
    let items = json!([
        {"id": "i1", "text": "Milk", "done": false},
        {"id": "i2", "text": "Eggs", "done": true},
    ]);
    let note = create_note(
        &app,
        &token,
        json!({"kind": "checklist", "title": "Groceries", "items": items}),
    )
    .await;
    assert_eq!(note["kind"], "checklist");
    assert_eq!(note["items"], items);

    // Toggle an item via PATCH.
    let id = note["id"].as_str().unwrap();
    let toggled = json!([
        {"id": "i1", "text": "Milk", "done": true},
        {"id": "i2", "text": "Eggs", "done": true},
    ]);
    let (status, updated) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"items": toggled})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(updated["items"], toggled);

    // Unknown kinds are rejected on create and patch.
    let (status, _) =
        send(&app, "POST", "/api/notes", Some(&token), Some(json!({"kind": "drawing"}))).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"kind": "sketch"})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn reminders_set_clear_validate() {
    let app = app().await;
    let (token, _) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({"title": "Call mom"})).await;
    let id = note["id"].as_str().unwrap();

    let (status, updated) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"reminder_at": "2026-08-01T09:00:00+00:00"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(updated["reminder_at"], "2026-08-01T09:00:00+00:00");

    // Explicit null clears; absent key leaves it alone.
    let (status, updated) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"title": "still set"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(updated["reminder_at"], "2026-08-01T09:00:00+00:00");
    let (status, updated) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"reminder_at": null})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(updated["reminder_at"], Value::Null);

    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"reminder_at": "tomorrow-ish"})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn reorder_renumbers_only_accessible_notes() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let a = create_note(&app, &ada, json!({"title": "a"})).await;
    let b = create_note(&app, &ada, json!({"title": "b"})).await;
    let c = create_note(&app, &ada, json!({"title": "c"})).await;
    let ada_secret = a["id"].as_str().unwrap();

    // Newest-first by default: c, b, a. Reorder to a, b, c.
    let order: Vec<&str> =
        vec![a["id"].as_str().unwrap(), b["id"].as_str().unwrap(), c["id"].as_str().unwrap()];
    let (status, _) =
        send(&app, "POST", "/api/notes/reorder", Some(&ada), Some(json!({"ids": order}))).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let titles: Vec<String> =
        list_notes(&app, &ada).await.iter().map(|n| n["title"].as_str().unwrap().to_string()).collect();
    assert_eq!(titles, vec!["a", "b", "c"]);

    // Bob smuggling Ada's note id into his reorder changes nothing.
    let before = list_notes(&app, &ada).await;
    let (status, _) = send(
        &app,
        "POST",
        "/api/notes/reorder",
        Some(&bob),
        Some(json!({"ids": [ada_secret]})),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(list_notes(&app, &ada).await, before);
}

#[tokio::test]
async fn trash_and_purge() {
    let app_state = state().await;
    let app = build_app(app_state.clone());
    let (token, _) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({"title": "old"})).await;
    let id = note["id"].as_str().unwrap();

    let (status, updated) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"trashed": true})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(updated["trashed"], json!(true));

    // Not purged yet: trashed_at is now, the cutoff is 7 days back.
    assert_eq!(list_notes(&app, &token).await.len(), 1);

    // With a cutoff in the future the note is swept.
    let future = (chrono::Utc::now() + chrono::Duration::days(8)).to_rfc3339();
    let purged = app_state.repo.purge_trash_before(&future).await.unwrap();
    assert_eq!(purged, vec![id.to_string()]);
    assert_eq!(list_notes(&app, &token).await.len(), 0);

    // Restore path: trash then untrash clears trashed_at (no accidental purge).
    let note = create_note(&app, &token, json!({"title": "kept"})).await;
    let id = note["id"].as_str().unwrap();
    for patch in [json!({"trashed": true}), json!({"trashed": false})] {
        let (status, _) =
            send(&app, "PATCH", &format!("/api/notes/{id}"), Some(&token), Some(patch)).await;
        assert_eq!(status, StatusCode::OK);
    }
    let purged = app_state.repo.purge_trash_before(&future).await.unwrap();
    assert!(purged.is_empty());
}

// ---------------------------------------------------------------------------
// Sharing

#[tokio::test]
async fn share_grants_edit_but_not_trash_or_share() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, bob_id) = register(&app, "bob").await;
    register(&app, "eve").await;
    let note = create_note(&app, &ada, json!({"title": "shared doc"})).await;
    let id = note["id"].as_str().unwrap();

    // Ada shares with Bob by username.
    let (status, shared) = send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&ada),
        Some(json!({"username": "bob"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(shared["collaborators"][0]["id"], json!(bob_id));

    // Bob now sees and can edit the note.
    let bobs = list_notes(&app, &bob).await;
    assert_eq!(bobs.len(), 1);
    assert_eq!(bobs[0]["owner"]["username"], "ada");
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
    let (status, _) = send(&app, "DELETE", &format!("/api/notes/{id}"), Some(&bob), None).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&bob),
        Some(json!({"username": "eve"})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // Sharing with an unknown user is a 400; sharing with yourself a 409.
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&ada),
        Some(json!({"username": "nobody"})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&ada),
        Some(json!({"username": "ada"})),
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
            Some(json!({"username": name})),
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
        Some(json!({"username": "bob"})),
    )
    .await;
    assert_eq!(list_notes(&app, &bob).await.len(), 1);

    let (status, _) = send(&app, "DELETE", &format!("/api/notes/{id}"), Some(&ada), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(list_notes(&app, &ada).await.len(), 0);
    assert_eq!(list_notes(&app, &bob).await.len(), 0);
}

// ---------------------------------------------------------------------------
// Labels

#[tokio::test]
async fn labels_are_personal_even_on_shared_notes() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;

    // Create labels; duplicates conflict per-owner but not across users.
    let (status, ada_label) =
        send(&app, "POST", "/api/labels", Some(&ada), Some(json!({"name": "work"}))).await;
    assert_eq!(status, StatusCode::CREATED);
    let (status, _) =
        send(&app, "POST", "/api/labels", Some(&ada), Some(json!({"name": "Work"}))).await;
    assert_eq!(status, StatusCode::CONFLICT);
    let (status, bob_label) =
        send(&app, "POST", "/api/labels", Some(&bob), Some(json!({"name": "work"}))).await;
    assert_eq!(status, StatusCode::CREATED);

    // Shared note: each participant tags with their own label and sees only theirs.
    let note = create_note(&app, &ada, json!({"title": "tagged"})).await;
    let id = note["id"].as_str().unwrap();
    send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&ada),
        Some(json!({"username": "bob"})),
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
async fn label_rename_delete_scoped_to_owner() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let (_, label) =
        send(&app, "POST", "/api/labels", Some(&ada), Some(json!({"name": "todo"}))).await;
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
    let (status, _) =
        send(&app, "DELETE", &format!("/api/labels/{label_id}"), Some(&bob), None).await;
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
    let (status, _) =
        send(&app, "DELETE", &format!("/api/labels/{label_id}"), Some(&ada), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, view) = send(&app, "GET", &format!("/api/notes/{note_id}"), Some(&ada), None).await;
    assert_eq!(view["label_ids"], json!([]));
}

#[tokio::test]
async fn markdown_kind_roundtrips_and_bad_kinds_reject() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let note = create_note(
        &app,
        &ada,
        json!({"kind": "markdown", "title": "Readme", "content": "# Hello\n- a\n- b"}),
    )
    .await;
    assert_eq!(note["kind"], "markdown");
    let id = note["id"].as_str().unwrap();

    // Convert to text and back.
    let (status, patched) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"kind": "text"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(patched["kind"], "text");
    let (status, patched) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"kind": "markdown"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(patched["kind"], "markdown");

    // Unknown kinds are still rejected.
    let (status, _) = send(
        &app,
        "POST",
        "/api/notes",
        Some(&ada),
        Some(json!({"kind": "doodle"})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

// ---------------------------------------------------------------------------
// Checklist history (typing suggestions)

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

// ---------------------------------------------------------------------------
// Attachments

fn multipart_body(mime: &str, bytes: &[u8]) -> (String, Vec<u8>) {
    let boundary = "XSTICKYBOUNDARY";
    let mut body = Vec::new();
    body.extend_from_slice(
        format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"pic\"\r\nContent-Type: {mime}\r\n\r\n"
        )
        .as_bytes(),
    );
    body.extend_from_slice(bytes);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    (format!("multipart/form-data; boundary={boundary}"), body)
}

async fn upload(
    app: &Router,
    token: &str,
    note_id: &str,
    mime: &str,
    bytes: &[u8],
) -> (StatusCode, Value) {
    let (content_type, body) = multipart_body(mime, bytes);
    let request = Request::builder()
        .method("POST")
        .uri(format!("/api/notes/{note_id}/attachments"))
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .header(header::CONTENT_TYPE, content_type)
        .body(Body::from(body))
        .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    let value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, value)
}

#[tokio::test]
async fn attachment_upload_serve_delete() {
    let app = app().await;
    let (token, _) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({"title": "with pic"})).await;
    let note_id = note["id"].as_str().unwrap();

    let payload = b"fake-png-bytes".as_slice();
    let (status, attachment) = upload(&app, &token, note_id, "image/png", payload).await;
    assert_eq!(status, StatusCode::CREATED, "{attachment}");
    let att_id = attachment["id"].as_str().unwrap();

    // Attachment appears on the note view.
    let (_, view) = send(&app, "GET", &format!("/api/notes/{note_id}"), Some(&token), None).await;
    assert_eq!(view["attachments"][0]["id"], json!(att_id));

    // File serves publicly with the right content type and bytes.
    let request = Request::builder().uri(format!("/api/files/{att_id}")).body(Body::empty()).unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()[header::CONTENT_TYPE], "image/png");
    let served = response.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(served.as_ref(), payload);

    // Delete removes row and file.
    let (status, _) =
        send(&app, "DELETE", &format!("/api/attachments/{att_id}"), Some(&token), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let request = Request::builder().uri(format!("/api/files/{att_id}")).body(Body::empty()).unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn attachment_rules() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let note = create_note(&app, &ada, json!({"title": "n"})).await;
    let note_id = note["id"].as_str().unwrap();

    // Any file type is stored, but non-images are forced to download with
    // their filename — never rendered in the app's origin.
    let (status, attachment) =
        upload(&app, &ada, note_id, "text/html", b"<script>alert(1)</script>").await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(attachment["filename"], "pic");
    assert_eq!(attachment["size"], 25);
    let att_id = attachment["id"].as_str().unwrap();
    let request = Request::builder().uri(format!("/api/files/{att_id}")).body(Body::empty()).unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let disposition = response.headers()[header::CONTENT_DISPOSITION].to_str().unwrap();
    assert!(disposition.starts_with("attachment"), "{disposition}");
    assert_eq!(response.headers()["x-content-type-options"], "nosniff");

    // Strangers can't upload to a note they can't see.
    let (status, _) = upload(&app, &bob, note_id, "image/png", b"x").await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // Collaborators can.
    send(
        &app,
        "POST",
        &format!("/api/notes/{note_id}/collaborators"),
        Some(&ada),
        Some(json!({"username": "bob"})),
    )
    .await;
    let (status, _) = upload(&app, &bob, note_id, "image/png", b"x").await;
    assert_eq!(status, StatusCode::CREATED);
}

// ---------------------------------------------------------------------------
// Semantic search

#[tokio::test]
async fn semantic_search_ranks_scopes_and_tracks_lifecycle() {
    let app = build_app(state_with_search().await);
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;

    let groceries = create_note(
        &app,
        &ada,
        json!({"title": "Groceries", "content": "buy milk eggs and bread at the market"}),
    )
    .await;
    create_note(
        &app,
        &ada,
        json!({"title": "Quarterly report", "content": "finish the business slides for friday"}),
    )
    .await;
    settle_index().await;

    // Ranked by similarity: the milk note wins for a milk-ish query.
    let (status, hits) =
        send(&app, "GET", "/api/search?q=milk%20bread", Some(&ada), None).await;
    assert_eq!(status, StatusCode::OK);
    let hits = hits.as_array().unwrap().clone();
    assert!(!hits.is_empty());
    assert_eq!(hits[0]["note_id"], groceries["id"]);

    // Scoped: bob has no access, so no results.
    let (_, bob_hits) = send(&app, "GET", "/api/search?q=milk", Some(&bob), None).await;
    assert_eq!(bob_hits, json!([]));

    // Sharing grants search visibility.
    let gid = groceries["id"].as_str().unwrap();
    send(
        &app,
        "POST",
        &format!("/api/notes/{gid}/collaborators"),
        Some(&ada),
        Some(json!({"username": "bob"})),
    )
    .await;
    settle_index().await;
    let (_, bob_hits) = send(&app, "GET", "/api/search?q=milk", Some(&bob), None).await;
    assert_eq!(bob_hits.as_array().unwrap().len(), 1);

    // Deletion removes the note from the index.
    let (status, _) = send(&app, "DELETE", &format!("/api/notes/{gid}"), Some(&ada), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    settle_index().await;
    let (_, hits) = send(&app, "GET", "/api/search?q=milk", Some(&ada), None).await;
    for hit in hits.as_array().unwrap() {
        assert_ne!(hit["note_id"], json!(gid));
    }

    // Auth required; empty query is an empty result, not an error.
    let (status, _) = send(&app, "GET", "/api/search?q=milk", None, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (_, empty) = send(&app, "GET", "/api/search?q=%20", Some(&ada), None).await;
    assert_eq!(empty, json!([]));
}

#[tokio::test]
async fn semantic_search_reports_unavailable_when_disabled() {
    let app = app().await; // no search service wired
    let (ada, _) = register(&app, "ada").await;
    let (status, _) = send(&app, "GET", "/api/search?q=milk", Some(&ada), None).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
}

// ---------------------------------------------------------------------------
// Per-user settings

#[tokio::test]
async fn settings_roundtrip_scoped_and_validated() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;

    // Defaults to an empty object.
    let (status, body) = send(&app, "GET", "/api/settings", Some(&ada), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, json!({}));

    // Roundtrip an arbitrary settings document.
    let doc = json!({
        "theme": "dark",
        "date_format": "dayFirst",
        "palette": [{"key": "lava", "name": "Lava", "light": "#FF5722", "dark": "#4E1A0F"}],
    });
    let (status, _) = send(&app, "PUT", "/api/settings", Some(&ada), Some(doc.clone())).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, body) = send(&app, "GET", "/api/settings", Some(&ada), None).await;
    assert_eq!(body, doc);

    // Strictly per-user.
    let (_, body) = send(&app, "GET", "/api/settings", Some(&bob), None).await;
    assert_eq!(body, json!({}));

    // Non-objects are rejected; auth is required.
    let (status, _) = send(&app, "PUT", "/api/settings", Some(&ada), Some(json!([1, 2]))).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = send(&app, "GET", "/api/settings", None, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

// ---------------------------------------------------------------------------
// Capabilities & audio transcription

#[tokio::test]
async fn capabilities_reflect_wired_services() {
    // Nothing wired: both optional features report off (unauthenticated).
    let app = app().await;
    let (status, caps) = send(&app, "GET", "/api/capabilities", None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(caps["semantic_search"], json!(false));
    assert_eq!(caps["audio_transcription"], json!(false));

    let app = build_app(state_with_search().await);
    let (_, caps) = send(&app, "GET", "/api/capabilities", None, None).await;
    assert_eq!(caps["semantic_search"], json!(true));
    assert_eq!(caps["audio_transcription"], json!(false));

    let app = build_app(state_with_transcription().await);
    let (_, caps) = send(&app, "GET", "/api/capabilities", None, None).await;
    assert_eq!(caps["semantic_search"], json!(false));
    assert_eq!(caps["audio_transcription"], json!(true));
}

#[tokio::test]
async fn audio_note_upload_triggers_transcription() {
    let app = build_app(state_with_transcription().await);
    let (token, _) = register(&app, "ada").await;

    // A fresh audio note carries no transcript yet.
    let note = create_note(&app, &token, json!({"kind": "audio"})).await;
    let id = note["id"].as_str().unwrap().to_string();
    assert_eq!(note["kind"], json!("audio"));
    assert_eq!(note["transcript_status"], json!("none"));

    // Uploading the clip runs Whisper and stores the transcript as content.
    let (status, _) = upload(&app, &token, &id, "audio/webm", b"fake-audio-bytes").await;
    assert_eq!(status, StatusCode::CREATED);
    settle_index().await;

    let refreshed = &list_notes(&app, &token).await[0];
    assert_eq!(refreshed["transcript_status"], json!("done"));
    assert_eq!(refreshed["content"], json!("transcript of 16 bytes"));
}

#[tokio::test]
async fn retry_transcription_validates_and_reruns() {
    let app = build_app(state_with_transcription().await);
    let (token, _) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({"kind": "audio"})).await;
    let id = note["id"].as_str().unwrap().to_string();

    // Nothing to transcribe yet.
    let (status, _) =
        send(&app, "POST", &format!("/api/notes/{id}/transcribe"), Some(&token), None).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // With a clip attached, an explicit retry re-runs and lands the transcript.
    upload(&app, &token, &id, "audio/webm", b"hello").await;
    settle_index().await;
    let (status, _) =
        send(&app, "POST", &format!("/api/notes/{id}/transcribe"), Some(&token), None).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    settle_index().await;
    let refreshed = &list_notes(&app, &token).await[0];
    assert_eq!(refreshed["transcript_status"], json!("done"));
    assert_eq!(refreshed["content"], json!("transcript of 5 bytes"));
}

#[tokio::test]
async fn non_audio_upload_leaves_transcript_untouched() {
    let app = build_app(state_with_transcription().await);
    let (token, _) = register(&app, "ada").await;
    // A text note with an image attachment is never transcribed.
    let note = create_note(&app, &token, json!({"title": "hi"})).await;
    let id = note["id"].as_str().unwrap().to_string();
    upload(&app, &token, &id, "image/png", b"\x89PNG\r\n").await;
    settle_index().await;
    let refreshed = &list_notes(&app, &token).await[0];
    assert_eq!(refreshed["transcript_status"], json!("none"));
    assert_eq!(refreshed["content"], json!(""));
}

#[tokio::test]
async fn transcribe_reports_unavailable_when_disabled() {
    let app = app().await; // no transcription service wired
    let (token, _) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({"kind": "audio"})).await;
    let id = note["id"].as_str().unwrap().to_string();
    let (status, _) =
        send(&app, "POST", &format!("/api/notes/{id}/transcribe"), Some(&token), None).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
}
