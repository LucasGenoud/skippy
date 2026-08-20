//! Note CRUD, reminders, reorder, trash/purge, and kind validation.

use crate::helpers::*;
use async_trait::async_trait;
use std::sync::atomic::{AtomicBool, Ordering};
use sticky_notes_server::files::{DiskStore, FileStore};
use sticky_notes_server::store::InfrastructureRepository;
use sticky_notes_server::store::sqlite::SqliteRepository;

struct FlakyDeleteStore {
    inner: DiskStore,
    fail_deletes: AtomicBool,
}

#[async_trait]
impl FileStore for FlakyDeleteStore {
    async fn save(&self, id: &str, bytes: &[u8]) -> anyhow::Result<()> {
        self.inner.save(id, bytes).await
    }

    async fn read(&self, id: &str) -> Option<Vec<u8>> {
        self.inner.read(id).await
    }

    async fn delete(&self, id: &str) -> anyhow::Result<()> {
        if self.fail_deletes.load(Ordering::Acquire) {
            anyhow::bail!("injected blob deletion failure");
        }
        self.inner.delete(id).await
    }
}

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
async fn backup_restore_can_preserve_note_timestamps() {
    let app = app().await;
    let (token, _) = register(&app, "ada").await;
    let (status, label) = send(
        &app,
        "POST",
        "/api/labels",
        Some(&token),
        Some(json!({"id": "restore-label", "name": "Restored"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let created = "2020-01-02T03:04:05Z";
    let updated = "2021-06-07T08:09:10Z";
    let note = create_note(
        &app,
        &token,
        json!({
            "title": "restored",
            "archived": true,
            "trashed": true,
            "label_ids": [label["id"]],
            "created_at": created,
            "updated_at": updated
        }),
    )
    .await;
    assert_eq!(note["created_at"], created);
    assert_eq!(note["updated_at"], updated);
    assert_eq!(note["archived"], true);
    assert_eq!(note["trashed"], true);
    assert_eq!(note["label_ids"], json!(["restore-label"]));

    let (status, _) = send(
        &app,
        "POST",
        "/api/notes",
        Some(&token),
        Some(json!({"title": "bad", "created_at": "yesterday"})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
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
    let (status, _) = send(
        &app,
        "POST",
        "/api/notes",
        Some(&token),
        Some(json!({"id": "my-id"})),
    )
    .await;
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
    let (status, _) = send(
        &app,
        "POST",
        "/api/notes",
        Some(&token),
        Some(json!({"kind": "drawing"})),
    )
    .await;
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

    // A cadence is optional and can be changed independently of the due time.
    let (status, updated) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"reminder_repeat": "weekly"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(updated["reminder_repeat"], "weekly");

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
    assert_eq!(updated["reminder_repeat"], Value::Null);

    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"reminder_at": "tomorrow-ish"})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"reminder_repeat": "hourly"})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, _) = send(
        &app,
        "POST",
        "/api/notes",
        Some(&token),
        Some(json!({"reminder_repeat": "daily"})),
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
    let order: Vec<&str> = vec![
        a["id"].as_str().unwrap(),
        b["id"].as_str().unwrap(),
        c["id"].as_str().unwrap(),
    ];
    let (status, _) = send(
        &app,
        "POST",
        "/api/notes/reorder",
        Some(&ada),
        Some(json!({"ids": order})),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let titles: Vec<String> = list_notes(&app, &ada)
        .await
        .iter()
        .map(|n| n["title"].as_str().unwrap().to_string())
        .collect();
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
    assert_eq!(
        purged
            .iter()
            .map(|p| p.note_id.as_str())
            .collect::<Vec<_>>(),
        vec![id]
    );
    assert_eq!(list_notes(&app, &token).await.len(), 0);

    // Restore path: trash then untrash clears trashed_at (no accidental purge).
    let note = create_note(&app, &token, json!({"title": "kept"})).await;
    let id = note["id"].as_str().unwrap();
    for patch in [json!({"trashed": true}), json!({"trashed": false})] {
        let (status, _) = send(
            &app,
            "PATCH",
            &format!("/api/notes/{id}"),
            Some(&token),
            Some(patch),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }
    let purged = app_state.repo.purge_trash_before(&future).await.unwrap();
    assert!(purged.is_empty());
}

/// Purging trash must remove attachment blobs from the file store, exactly
/// like deleting a note directly does, otherwise every attachment on a note
/// that ages out of the trash leaks its bytes forever.
#[tokio::test]
async fn purging_trash_deletes_attachment_blobs() {
    let app_state = state().await;
    let app = build_app(app_state.clone());
    let (token, _user_id) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({"title": "with file"})).await;
    let id = note["id"].as_str().unwrap();
    let (status, attachment) = upload(&app, &token, id, "image/png", b"pixels").await;
    assert_eq!(status, StatusCode::CREATED);
    let attachment_id = attachment["id"].as_str().unwrap();
    assert!(app_state.files.read(attachment_id).await.is_some());

    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"trashed": true})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let future = (chrono::Utc::now() + chrono::Duration::days(8)).to_rfc3339();
    assert!(
        sticky_notes_server::handlers::purge_trash(&app_state, &future)
            .await
            .is_ok()
    );

    assert_eq!(list_notes(&app, &token).await.len(), 0);
    assert!(
        app_state.files.read(attachment_id).await.is_none(),
        "purging a trashed note must delete its blobs"
    );
}

#[tokio::test]
async fn failed_blob_cleanup_is_persisted_and_retried() {
    let repo = Arc::new(SqliteRepository::connect(":memory:").await.unwrap());
    let dir = std::env::temp_dir().join(format!("sticky-notes-cleanup-{}", uuid::Uuid::new_v4()));
    let files = Arc::new(FlakyDeleteStore {
        inner: DiskStore::new(dir),
        fail_deletes: AtomicBool::new(false),
    });
    let index = Arc::new(
        SqliteVectorIndex::connect(":memory:", HASH_EMBED_DIMS, "hash-test:64")
            .await
            .unwrap(),
    );
    let app_state = AppState::new(repo.clone(), files.clone())
        .with_search(Arc::new(SearchService::new(Arc::new(HashEmbedder), index)));
    let app = build_app(app_state.clone());
    let (token, _) = register(&app, "cleanup").await;
    let note = create_note(&app, &token, json!({"title": "retry cleanup"})).await;
    let note_id = note["id"].as_str().unwrap();
    let (_, attachment) = upload(&app, &token, note_id, "image/png", b"pixels").await;
    let attachment_id = attachment["id"].as_str().unwrap();

    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{note_id}"),
        Some(&token),
        Some(json!({"trashed": true})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    files.fail_deletes.store(true, Ordering::Release);
    let future = (chrono::Utc::now() + chrono::Duration::days(8)).to_rfc3339();
    assert!(
        sticky_notes_server::handlers::purge_trash(&app_state, &future)
            .await
            .is_ok()
    );

    assert!(files.read(attachment_id).await.is_some());
    let stats = repo.cleanup_stats().await.unwrap();
    assert_eq!(stats.pending, 1);
    assert_eq!(stats.failed, 1);

    files.fail_deletes.store(false, Ordering::Release);
    let job = repo
        .due_cleanup_jobs(i64::MAX, 10)
        .await
        .unwrap()
        .into_iter()
        .find(|job| job.target_id == attachment_id)
        .unwrap();
    repo.retry_cleanup_job(job.id, "retry now", 0)
        .await
        .unwrap();
    app_state.drain_cleanup_jobs().await;

    assert!(files.read(attachment_id).await.is_none());
    assert_eq!(repo.cleanup_stats().await.unwrap().pending, 0);
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

/// Helper: a checklist note with two unchecked items, returning (id, item ids).
async fn checklist_note(app: &Router, token: &str) -> (String, String, String) {
    let note = create_note(
        app,
        token,
        json!({
            "kind": "checklist",
            "title": "Groceries",
            "items": [
                {"id": "item-milk", "text": "Milk", "done": false},
                {"id": "item-bread", "text": "Bread", "done": false},
            ],
        }),
    )
    .await;
    (
        note["id"].as_str().unwrap().to_string(),
        "item-milk".to_string(),
        "item-bread".to_string(),
    )
}

#[tokio::test]
async fn item_reminders_are_set_cleared_and_validated_per_item() {
    let app = app().await;
    let (token, _) = register(&app, "ada").await;
    let (id, milk, bread) = checklist_note(&app, &token).await;

    let (status, view) = send(
        &app,
        "PUT",
        &format!("/api/notes/{id}/item-reminders/{milk}"),
        Some(&token),
        Some(json!({"reminder_at": "2026-08-21T09:00:00+00:00"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{view}");
    assert_eq!(
        view["item_reminders"],
        json!([{
            "item_id": "item-milk",
            "reminder_at": "2026-08-21T09:00:00+00:00",
            "reminder_repeat": null,
        }])
    );
    // Not an edit: the note keeps its own reminder field and its timestamp.
    assert_eq!(view["reminder_at"], Value::Null);

    // A second item is independent of the first.
    let (status, view) = send(
        &app,
        "PUT",
        &format!("/api/notes/{id}/item-reminders/{bread}"),
        Some(&token),
        Some(json!({
            "reminder_at": "2026-08-22T09:00:00+00:00",
            "reminder_repeat": "weekly",
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(view["item_reminders"].as_array().unwrap().len(), 2);
    // Ordered like the list reads, not by id.
    assert_eq!(view["item_reminders"][0]["item_id"], "item-milk");
    assert_eq!(view["item_reminders"][1]["reminder_repeat"], "weekly");

    // Null clears one without touching the other.
    let (status, view) = send(
        &app,
        "PUT",
        &format!("/api/notes/{id}/item-reminders/{milk}"),
        Some(&token),
        Some(json!({"reminder_at": null})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(view["item_reminders"].as_array().unwrap().len(), 1);
    assert_eq!(view["item_reminders"][0]["item_id"], "item-bread");

    // Validation mirrors the note-level reminder's.
    for body in [
        json!({"reminder_at": "tomorrow-ish"}),
        json!({"reminder_at": "2026-08-21T09:00:00+00:00", "reminder_repeat": "hourly"}),
    ] {
        let (status, _) = send(
            &app,
            "PUT",
            &format!("/api/notes/{id}/item-reminders/{milk}"),
            Some(&token),
            Some(body),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }

    // An item the note does not have cannot carry one.
    let (status, _) = send(
        &app,
        "PUT",
        &format!("/api/notes/{id}/item-reminders/item-ghost"),
        Some(&token),
        Some(json!({"reminder_at": "2026-08-21T09:00:00+00:00"})),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    // Clearing one, though, stays idempotent: a stale client may tidy up.
    let (status, _) = send(
        &app,
        "PUT",
        &format!("/api/notes/{id}/item-reminders/item-ghost"),
        Some(&token),
        Some(json!({"reminder_at": null})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn checking_or_removing_an_item_takes_its_reminder_with_it() {
    let app = app().await;
    let (token, _) = register(&app, "ada").await;
    let (id, milk, bread) = checklist_note(&app, &token).await;
    for item in [&milk, &bread] {
        let (status, _) = send(
            &app,
            "PUT",
            &format!("/api/notes/{id}/item-reminders/{item}"),
            Some(&token),
            Some(json!({"reminder_at": "2026-08-21T09:00:00+00:00"})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }

    // Checking an item off cancels its reminder: the list is done with it.
    let (status, view) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"items": [
            {"id": "item-milk", "text": "Milk", "done": true},
            {"id": "item-bread", "text": "Bread", "done": false},
        ]})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(view["item_reminders"].as_array().unwrap().len(), 1);
    assert_eq!(view["item_reminders"][0]["item_id"], "item-bread");

    // And it cannot be set again while the item stays checked.
    let (status, _) = send(
        &app,
        "PUT",
        &format!("/api/notes/{id}/item-reminders/{milk}"),
        Some(&token),
        Some(json!({"reminder_at": "2026-08-21T09:00:00+00:00"})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Deleting the row takes the reminder too.
    let (status, view) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"items": [{"id": "item-milk", "text": "Milk", "done": true}]})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(view["item_reminders"], json!([]));

    // Unchecking it does not bring the old reminder back from the dead.
    let (status, view) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"items": [{"id": "item-milk", "text": "Milk", "done": false}]})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(view["item_reminders"], json!([]));
}

#[tokio::test]
async fn item_reminders_are_shared_note_state_and_survive_create() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let (carol, _) = register(&app, "carol").await;

    // Created in one request, the way an offline compose or a restore arrives.
    let note = create_note(
        &app,
        &ada,
        json!({
            "kind": "checklist",
            "items": [{"id": "item-milk", "text": "Milk", "done": false}],
            "item_reminders": [
                {"item_id": "item-milk", "reminder_at": "2026-08-21T09:00:00+00:00"},
            ],
        }),
    )
    .await;
    let id = note["id"].as_str().unwrap();
    assert_eq!(note["item_reminders"][0]["item_id"], "item-milk");

    // A create naming an item that isn't there is refused outright.
    let (status, _) = send(
        &app,
        "POST",
        "/api/notes",
        Some(&ada),
        Some(json!({
            "kind": "checklist",
            "items": [{"id": "a", "text": "A", "done": false}],
            "item_reminders": [
                {"item_id": "b", "reminder_at": "2026-08-21T09:00:00+00:00"},
            ],
        })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // A collaborator sees it and may change it: reminders are shared state,
    // unlike labels, which stay behind with the workspace.
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&ada),
        Some(json!({"email": test_email("bob")})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, view) = send(&app, "GET", &format!("/api/notes/{id}"), Some(&bob), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(view["item_reminders"][0]["item_id"], "item-milk");
    let (status, view) = send(
        &app,
        "PUT",
        &format!("/api/notes/{id}/item-reminders/item-milk"),
        Some(&bob),
        Some(json!({"reminder_at": "2026-09-01T09:00:00+00:00"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        view["item_reminders"][0]["reminder_at"],
        "2026-09-01T09:00:00+00:00"
    );

    // A stranger learns nothing, not even that the note exists.
    let (status, _) = send(
        &app,
        "PUT",
        &format!("/api/notes/{id}/item-reminders/item-milk"),
        Some(&carol),
        Some(json!({"reminder_at": "2026-09-01T09:00:00+00:00"})),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn checklist_nesting_is_kept_in_a_drawable_shape() {
    let app = app().await;
    let (token, _) = register(&app, "ada").await;

    // A create carrying an impossible shape is corrected, not rejected: the
    // rows are the user's, only the indentation is ours to fix.
    let note = create_note(
        &app,
        &token,
        json!({
            "kind": "checklist",
            "items": [
                {"id": "a", "text": "Trip", "done": false, "depth": 2},
                {"id": "b", "text": "Pack", "done": false, "depth": 1},
                {"id": "c", "text": "Socks", "done": false, "depth": 3},
            ],
        }),
    )
    .await;
    let id = note["id"].as_str().unwrap();
    // A top-level row carries no depth at all, so a flat checklist looks on
    // the wire exactly as it did before subtasks existed.
    assert_eq!(note["items"][0].get("depth"), None);
    assert_eq!(note["items"][1]["depth"], 1);
    assert_eq!(note["items"][2]["depth"], 2);

    // An item written before subtasks existed carries no depth at all and
    // reads as top-level.
    let (status, updated) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"items": [
            {"id": "a", "text": "Trip", "done": false},
            {"id": "c", "text": "Socks", "done": false, "depth": 2},
        ]})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(updated["items"][0].get("depth"), None);
    // Its parent went away, so the subtask comes up to the level that still
    // has one rather than being dropped.
    assert_eq!(updated["items"][1]["depth"], 1);
}

#[tokio::test]
async fn restoring_a_version_lands_a_drawable_checklist() {
    let app = app().await;
    let (token, _) = register(&app, "ada").await;
    let note = create_note(
        &app,
        &token,
        json!({
            "kind": "checklist",
            "items": [
                {"id": "a", "text": "Trip", "done": false},
                {"id": "b", "text": "Pack", "done": false, "depth": 1},
            ],
        }),
    )
    .await;
    let id = note["id"].as_str().unwrap();

    // Drop the parent, which is the edit the version will roll back.
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&token),
        Some(json!({"items": [{"id": "b", "text": "Pack", "done": false, "depth": 1}]})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, versions) = send(
        &app,
        "GET",
        &format!("/api/notes/{id}/versions"),
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let version_id = versions[0]["id"].as_str().unwrap();
    let (status, restored) = send(
        &app,
        "POST",
        &format!("/api/notes/{id}/versions/{version_id}/restore"),
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{restored}");
    assert_eq!(restored["items"][0].get("depth"), None);
    assert_eq!(restored["items"][1]["depth"], 1);
}
