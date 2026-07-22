//! Reminder push notifications through the connector registry.

use crate::helpers::*;

use async_trait::async_trait;
use sticky_notes_server::notify::{self, Connector, Notification};

/// Everything the fake connectors delivered: (channel, destination, title, body).
type SentLog = Arc<std::sync::Mutex<Vec<(String, String, String, String)>>>;

/// A recording connector configured by a single settings key (the same keys
/// the real ntfy/Telegram connectors use, so tests exercise the real
/// settings-document contract with only the HTTP transport faked).
struct FakeChannel {
    name: &'static str,
    key: &'static str,
    log: SentLog,
    fail: bool,
}

#[async_trait]
impl Connector for FakeChannel {
    fn name(&self) -> &'static str {
        self.name
    }

    fn configured(&self, settings: &Value) -> bool {
        settings[self.key]
            .as_str()
            .map(str::trim)
            .is_some_and(|s| !s.is_empty())
    }

    async fn send(&self, settings: &Value, notification: &Notification) -> anyhow::Result<()> {
        if self.fail {
            anyhow::bail!("boom");
        }
        self.log.lock().unwrap().push((
            self.name.to_string(),
            settings[self.key].as_str().unwrap_or_default().to_string(),
            notification.title.clone(),
            notification.body.clone(),
        ));
        Ok(())
    }
}

async fn state_with_notifiers() -> (AppState, SentLog) {
    let log: SentLog = Arc::default();
    let connectors: Vec<Arc<dyn Connector>> = vec![
        Arc::new(FakeChannel {
            name: "ntfy",
            key: "ntfy_url",
            log: log.clone(),
            fail: false,
        }),
        Arc::new(FakeChannel {
            name: "telegram",
            key: "telegram_chat_id",
            log: log.clone(),
            fail: false,
        }),
    ];
    (state().await.with_notifiers(connectors), log)
}

async fn put_settings(app: &Router, token: &str, doc: Value) {
    let (status, _) = send(app, "PUT", "/api/settings", Some(token), Some(doc)).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn due_reminders_fire_once_per_configured_participant() {
    let (state, log) = state_with_notifiers().await;
    let app = build_app(state.clone());
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    put_settings(&app, &ada, json!({"ntfy_url": "https://ntfy.sh/ada-notes"})).await;
    put_settings(&app, &bob, json!({"telegram_chat_id": "4242"})).await;

    let note = create_note(
        &app,
        &ada,
        json!({
            "title": "Water plants",
            "content": "the ficus too",
            "reminder_at": "2020-01-05T10:00:00Z",
        }),
    )
    .await;
    let id = note["id"].as_str().unwrap();
    let (status, _) = send(
        &app,
        "POST",
        &format!("/api/notes/{id}/collaborators"),
        Some(&ada),
        Some(json!({"email": "bob@example.test"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    notify::sweep_due_reminders(&state).await;
    {
        let mut sent = log.lock().unwrap();
        sent.sort(); // participant order is not specified
        assert_eq!(
            *sent,
            vec![
                (
                    "ntfy".to_string(),
                    "https://ntfy.sh/ada-notes".to_string(),
                    "Water plants".to_string(),
                    "the ficus too".to_string()
                ),
                (
                    "telegram".to_string(),
                    "4242".to_string(),
                    "Water plants".to_string(),
                    "the ficus too".to_string()
                ),
            ]
        );
    }

    // Fired means fired: the next sweep is quiet.
    notify::sweep_due_reminders(&state).await;
    assert_eq!(log.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn rescheduling_a_reminder_fires_again_but_content_edits_do_not() {
    let (state, log) = state_with_notifiers().await;
    let app = build_app(state.clone());
    let (ada, _) = register(&app, "ada").await;
    put_settings(&app, &ada, json!({"ntfy_url": "https://ntfy.sh/a"})).await;

    let note = create_note(
        &app,
        &ada,
        json!({"title": "Call mom", "reminder_at": "2020-01-05T10:00:00Z"}),
    )
    .await;
    let id = note["id"].as_str().unwrap();
    notify::sweep_due_reminders(&state).await;
    assert_eq!(log.lock().unwrap().len(), 1);

    // A content edit leaves the fired mark alone.
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"content": "and dad"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    notify::sweep_due_reminders(&state).await;
    assert_eq!(log.lock().unwrap().len(), 1);

    // Rescheduling (to another due time) clears it -> fires again.
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"reminder_at": "2020-02-01T08:00:00Z"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    notify::sweep_due_reminders(&state).await;
    assert_eq!(log.lock().unwrap().len(), 2);

    // Clearing the reminder stops everything.
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{id}"),
        Some(&ada),
        Some(json!({"reminder_at": null})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    notify::sweep_due_reminders(&state).await;
    assert_eq!(log.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn reminders_skip_future_trashed_disabled_and_unconfigured() {
    let (state, log) = state_with_notifiers().await;
    let app = build_app(state.clone());
    let (ada, _) = register(&app, "ada").await;
    put_settings(
        &app,
        &ada,
        json!({"ntfy_url": "https://ntfy.sh/a", "reminder_notifications": false}),
    )
    .await;

    // Future reminders wait; offsets compare as instants, not strings
    // ("+10:00" sorts before "Z" as text but names a future moment here).
    create_note(
        &app,
        &ada,
        json!({"title": "Future", "reminder_at": "2999-01-01T00:00:00+10:00"}),
    )
    .await;
    // Trashed notes never fire.
    let trashed = create_note(
        &app,
        &ada,
        json!({"title": "Trashed", "reminder_at": "2020-01-05T10:00:00Z"}),
    )
    .await;
    let trashed_id = trashed["id"].as_str().unwrap();
    let (status, _) = send(
        &app,
        "PATCH",
        &format!("/api/notes/{trashed_id}"),
        Some(&ada),
        Some(json!({"trashed": true})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    // Due, but the user turned notifications off: consumed silently (a
    // later opt-in must not replay old alarms).
    create_note(
        &app,
        &ada,
        json!({"title": "Muted", "reminder_at": "2020-01-05T10:00:00Z"}),
    )
    .await;

    notify::sweep_due_reminders(&state).await;
    assert!(log.lock().unwrap().is_empty());

    // Turning notifications back on doesn't resurrect the consumed reminder.
    put_settings(&app, &ada, json!({"ntfy_url": "https://ntfy.sh/a"})).await;
    notify::sweep_due_reminders(&state).await;
    assert!(log.lock().unwrap().is_empty());

    // An offset timestamp that IS past (as an instant) fires despite sorting
    // after "2020-..." UTC strings would suggest nothing; belt and braces for
    // the julianday comparison.
    create_note(
        &app,
        &ada,
        json!({"title": "Offset", "reminder_at": "2020-01-05T10:00:00+10:00"}),
    )
    .await;
    notify::sweep_due_reminders(&state).await;
    let sent = log.lock().unwrap();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].2, "Offset");
}

#[tokio::test]
async fn checklist_reminders_list_only_pending_items() {
    let (state, log) = state_with_notifiers().await;
    let app = build_app(state.clone());
    let (ada, _) = register(&app, "ada").await;
    put_settings(&app, &ada, json!({"ntfy_url": "https://ntfy.sh/a"})).await;

    create_note(
        &app,
        &ada,
        json!({
            "kind": "checklist",
            "title": "Groceries",
            "items": [
                {"id": "1", "text": "milk", "done": false},
                {"id": "2", "text": "bread", "done": true},
                {"id": "3", "text": "eggs", "done": false},
            ],
            "reminder_at": "2020-01-05T10:00:00Z",
        }),
    )
    .await;
    notify::sweep_due_reminders(&state).await;
    let sent = log.lock().unwrap();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].3, "milk\neggs");
}

#[tokio::test]
async fn notify_test_endpoint_sends_and_validates() {
    let (ok_state, log) = state_with_notifiers().await;
    let app = build_app(ok_state);
    let (ada, _) = register(&app, "ada").await;

    // Needs auth.
    let (status, _) = send(&app, "POST", "/api/notify/test", None, Some(json!({}))).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // Nothing configured in the probe body -> 400.
    let (status, _) = send(
        &app,
        "POST",
        "/api/notify/test",
        Some(&ada),
        Some(json!({})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // A configured channel gets a real test message; the body config is used
    // as-is (nothing needs to be saved in settings first).
    let (status, body) = send(
        &app,
        "POST",
        "/api/notify/test",
        Some(&ada),
        Some(json!({"ntfy_url": "https://ntfy.sh/probe"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["ok"], json!(true));
    {
        let sent = log.lock().unwrap();
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0].0, "ntfy");
        assert_eq!(sent[0].1, "https://ntfy.sh/probe");
    }

    // Failures are a result, not an HTTP error, and name the channel.
    let log: SentLog = Arc::default();
    let failing: Vec<Arc<dyn Connector>> = vec![Arc::new(FakeChannel {
        name: "ntfy",
        key: "ntfy_url",
        log: log.clone(),
        fail: true,
    })];
    let app = build_app(state().await.with_notifiers(failing));
    let (ada, _) = register(&app, "ada").await;
    let (status, body) = send(
        &app,
        "POST",
        "/api/notify/test",
        Some(&ada),
        Some(json!({"ntfy_url": "https://ntfy.sh/probe"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["ok"], json!(false));
    assert!(
        body["error"].as_str().unwrap().contains("ntfy: boom"),
        "{body}"
    );
}
