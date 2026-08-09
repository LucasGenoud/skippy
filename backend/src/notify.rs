//! Reminder notifications, delivered through pluggable connectors (ntfy and
//! Telegram out of the box). Like the LLM integration (and unlike
//! search/transcription) this is per-user configuration, not server wiring:
//! each user puts their channel details in their settings document, and the
//! reminder scheduler reads them when a note's `reminder_at` comes due. A
//! user with no channel configured simply never gets pushes.
//!
//! Adding a channel = implement [`Connector`] (a self-contained struct that
//! reads its own keys out of the settings document) and register it in
//! [`default_connectors`]. The sweep, the `/api/notify/test` endpoint and
//! per-user configuration pick it up with no further changes, the client
//! saves connector keys under the same names in the same document.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use chrono::{DateTime, Datelike, Months, Utc};
use serde_json::Value;

use crate::AppState;
use crate::models::NoteRecord;

/// How often the background scheduler looks for due reminders.
pub const REMINDER_SWEEP_SECS: u64 = 30;
/// Max characters of note content in a notification body.
const NOTIFICATION_BODY_CHARS: usize = 500;

/// A rendered notification, channel-agnostic.
#[derive(Debug, Clone, PartialEq)]
pub struct Notification {
    pub title: String,
    pub body: String,
}

/// Render a due reminder: the note title (falling back to "Reminder") over a
/// capped body, the note's content, or a checklist's still-pending items.
pub fn reminder_notification(record: &NoteRecord) -> Notification {
    let title = match record.title.trim() {
        "" => "Reminder".to_string(),
        t => t.to_string(),
    };
    let body = if record.items.is_empty() {
        record.content.trim().to_string()
    } else {
        record
            .items
            .iter()
            .filter(|item| !item.done)
            .map(|item| item.text.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    };
    let total = body.chars().count();
    let mut body: String = body.chars().take(NOTIFICATION_BODY_CHARS).collect();
    if total > NOTIFICATION_BODY_CHARS {
        body.push('…');
    }
    Notification { title, body }
}

/// Calculate the first future occurrence of a recurring reminder. Recurrence
/// is based on the reminder's RFC3339 offset. Missed occurrences coalesce into
/// one catch-up delivery; the next scheduled occurrence is always in the
/// future.
fn next_recurring_reminder(reminder_at: &str, repeat: &str, now: DateTime<Utc>) -> Option<String> {
    let due = DateTime::parse_from_rfc3339(reminder_at).ok()?;
    let now = now.with_timezone(due.offset());

    let advance = |months: u32| due.checked_add_months(Months::new(months));
    let mut next = match repeat {
        "daily" => {
            let days = now.signed_duration_since(due).num_days().max(0) + 1;
            due.checked_add_signed(chrono::Duration::days(days))?
        }
        "weekly" => {
            let weeks = now.signed_duration_since(due).num_weeks().max(0) + 1;
            due.checked_add_signed(chrono::Duration::weeks(weeks))?
        }
        "monthly" => {
            let months = (now.year() - due.year()) * 12 + now.month() as i32 - due.month() as i32;
            let months = months.max(1) as u32;
            let mut next = advance(months)?;
            if next <= now {
                next = advance(months + 1)?;
            }
            next
        }
        "yearly" => {
            let years = now.year() - due.year();
            let years = years.max(1) as u32;
            let mut next = advance(years * 12)?;
            if next <= now {
                next = advance((years + 1) * 12)?;
            }
            next
        }
        _ => return None,
    };
    // Daily and weekly use exact-duration arithmetic, so this only matters
    // for a future clock skew. It also protects callers if this helper gains
    // additional cadence kinds later.
    while next <= now {
        next = match repeat {
            "daily" => next.checked_add_signed(chrono::Duration::days(1))?,
            "weekly" => next.checked_add_signed(chrono::Duration::weeks(1))?,
            "monthly" => next.checked_add_months(Months::new(1))?,
            "yearly" => next.checked_add_months(Months::new(12))?,
            _ => return None,
        };
    }
    Some(next.to_rfc3339())
}

/// One push channel. Implementations are stateless senders; the per-user
/// destination details live in that user's settings document, and each
/// connector owns its keys there (`ntfy_url`, `telegram_bot_token`, …). The
/// trait is object-safe so connectors can sit in one registry.
#[async_trait]
pub trait Connector: Send + Sync {
    /// Stable channel name; prefixes delivery errors ("ntfy: …").
    fn name(&self) -> &'static str;
    /// Does this settings document fully configure the channel?
    fn configured(&self, settings: &Value) -> bool;
    /// Deliver. Only called when [`Connector::configured`] is true.
    async fn send(&self, settings: &Value, notification: &Notification) -> anyhow::Result<()>;
}

/// The production connector set, sharing one HTTP client. Register new
/// connectors here.
pub fn default_connectors() -> Vec<Arc<dyn Connector>> {
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("reqwest client");
    vec![
        Arc::new(NtfyConnector),
        Arc::new(TelegramConnector::new(client)),
    ]
}

/// A trimmed string setting; missing/non-string keys read as "".
fn text(settings: &Value, key: &str) -> String {
    settings[key]
        .as_str()
        .map(str::trim)
        .unwrap_or_default()
        .to_string()
}

/// Master toggle (`reminder_notifications`), defaulting on, it only matters
/// once a channel is configured.
pub fn notifications_enabled(settings: &Value) -> bool {
    settings["reminder_notifications"] != false
}

/// Parse a settings document string as stored by `put_settings`.
pub fn settings_value(settings_json: Option<&str>) -> Value {
    settings_json
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default()
}

/// Turn a non-2xx response into an error carrying a truncated body (and never
/// a token).
async fn status_error(service: &str, response: reqwest::Response) -> anyhow::Error {
    let status = response.status();
    let body = crate::outbound::read_body_prefix(response, 16 * 1024).await;
    let body = String::from_utf8_lossy(&body)
        .chars()
        .take(300)
        .collect::<String>();
    anyhow::anyhow!("{service} returned {status}: {body}")
}

// ---------------------------------------------------------------------------
// ntfy

/// Publishes to an ntfy topic. Keys: `ntfy_url` (the full topic URL as shown
/// in the ntfy apps, e.g. `https://ntfy.sh/my-secret-topic`) and optional
/// `ntfy_token` for protected topics.
pub struct NtfyConnector;

/// Split a full ntfy topic URL into (server base, topic). Publishing goes to
/// the server root as JSON, unlike the header-based `POST {url}` style this
/// keeps unicode titles intact. A missing scheme defaults to https.
pub fn split_ntfy_url(url: &str) -> Option<(String, String)> {
    let url = url.trim().trim_end_matches('/');
    let with_scheme = if url.contains("://") {
        url.to_string()
    } else {
        format!("https://{url}")
    };
    let (base, topic) = with_scheme.rsplit_once('/')?;
    if topic.is_empty() || base.ends_with(":/") || !base.contains("://") {
        return None;
    }
    Some((base.to_string(), topic.to_string()))
}

#[async_trait]
impl Connector for NtfyConnector {
    fn name(&self) -> &'static str {
        "ntfy"
    }

    fn configured(&self, settings: &Value) -> bool {
        !text(settings, "ntfy_url").is_empty()
    }

    async fn send(&self, settings: &Value, notification: &Notification) -> anyhow::Result<()> {
        let url = text(settings, "ntfy_url");
        let (base, topic) = split_ntfy_url(&url)
            .ok_or_else(|| anyhow::anyhow!("ntfy URL must look like https://ntfy.sh/your-topic"))?;
        let target = crate::outbound::resolve_http_url(
            &base,
            crate::outbound::allow_private_user_endpoints(),
        )
        .await?;
        let client = target
            .client_builder()
            .connect_timeout(crate::outbound::CONNECT_TIMEOUT)
            .timeout(Duration::from_secs(15))
            .build()?;
        let mut request = client.post(target.url).json(&serde_json::json!({
            "topic": topic,
            "title": notification.title,
            "message": notification.body,
            "tags": ["alarm_clock"],
        }));
        let token = text(settings, "ntfy_token");
        if !token.is_empty() {
            request = request.bearer_auth(&token);
        }
        let response = request.send().await?;
        if !response.status().is_success() {
            return Err(status_error("ntfy", response).await);
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Telegram

/// Messages a chat through a Telegram bot. Keys: `telegram_bot_token` (from
/// @BotFather) and `telegram_chat_id` (numeric id or `@channelname`).
/// Bring-your-own-bot matches the per-user LLM pattern and needs no
/// server-side coordination.
pub struct TelegramConnector {
    client: reqwest::Client,
    /// Bot API base; `TELEGRAM_API` overrides it (self-hosted
    /// bot-api servers, proxies, e2e stubs).
    base: String,
}

impl TelegramConnector {
    pub fn new(client: reqwest::Client) -> Self {
        let base = std::env::var("TELEGRAM_API")
            .unwrap_or_else(|_| "https://api.telegram.org".to_string());
        Self {
            client,
            base: base.trim_end_matches('/').to_string(),
        }
    }
}

#[async_trait]
impl Connector for TelegramConnector {
    fn name(&self) -> &'static str {
        "telegram"
    }

    fn configured(&self, settings: &Value) -> bool {
        !text(settings, "telegram_bot_token").is_empty()
            && !text(settings, "telegram_chat_id").is_empty()
    }

    async fn send(&self, settings: &Value, notification: &Notification) -> anyhow::Result<()> {
        let chat_id = text(settings, "telegram_chat_id");
        // Numeric ids go as numbers, "@channelname" as a string.
        let chat_id: Value = match chat_id.parse::<i64>() {
            Ok(n) => n.into(),
            Err(_) => chat_id.into(),
        };
        let message = if notification.body.is_empty() {
            format!("⏰ {}", notification.title)
        } else {
            format!("⏰ {}\n{}", notification.title, notification.body)
        };
        let url = format!(
            "{}/bot{}/sendMessage",
            self.base,
            text(settings, "telegram_bot_token")
        );
        let response = self
            .client
            .post(&url)
            .json(&serde_json::json!({ "chat_id": chat_id, "text": message }))
            .send()
            .await?;
        if !response.status().is_success() {
            // Telegram errors carry a useful `description`; surface it rather
            // than the raw body (and never echo the URL, which holds the token).
            let status = response.status();
            let body = crate::outbound::read_body_capped(response, 64 * 1024)
                .await
                .unwrap_or_default();
            let value: Value = serde_json::from_slice(&body).unwrap_or_default();
            let description = value["description"].as_str().unwrap_or("request failed");
            return Err(anyhow::anyhow!("telegram returned {status}: {description}"));
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Delivery & the reminder sweep

/// Deliver `notification` through every connector the settings document
/// configures, returning one error string per failed channel (empty = all
/// good, or nothing configured). Used by both the reminder sweep and the
/// settings "send test" endpoint.
pub async fn send_configured(
    connectors: &[Arc<dyn Connector>],
    settings: &Value,
    notification: &Notification,
) -> Vec<String> {
    let mut errors = Vec::new();
    for connector in connectors {
        if !connector.configured(settings) {
            continue;
        }
        if let Err(e) = connector.send(settings, notification).await {
            errors.push(format!("{}: {e:#}", connector.name()));
        }
    }
    errors
}

/// One scheduler pass: find due, unfired reminders and push them to every
/// participant with a configured channel. Each one-shot reminder is marked
/// fired, while a recurring one atomically advances to its next future
/// occurrence, *before* delivery. That keeps delivery at-most-once: a broken
/// channel can't wedge the sweep into resending forever. Delivery failures are
/// logged and dropped.
pub async fn sweep_due_reminders(state: &AppState) {
    let now_utc = chrono::Utc::now();
    let now = now_utc.to_rfc3339();
    let due = match state.repo.due_reminders(&now).await {
        Ok(due) => due,
        Err(e) => {
            state.report_background_failure("reminder_sweep", &format!("{e:?}"));
            return;
        }
    };
    for note in due {
        let Some(reminder_at) = note.reminder_at.as_deref() else {
            continue;
        };
        let recurring = note.reminder_repeat.is_some();
        let claimed = match note.reminder_repeat.as_deref() {
            Some(repeat) => {
                let Some(next) = next_recurring_reminder(reminder_at, repeat, now_utc) else {
                    continue;
                };
                state
                    .repo
                    .advance_recurring_reminder(&note.id, reminder_at, &next, &now)
                    .await
            }
            None => {
                state
                    .repo
                    .mark_reminder_fired(&note.id, reminder_at, &now)
                    .await
            }
        };
        match claimed {
            Ok(true) => {}
            Ok(false) => continue,
            Err(error) => {
                // Leave it for the next sweep rather than risk sending
                // without an atomic claim (= resending every 30s).
                state.report_background_failure("reminder_claim", &format!("{error:?}"));
                continue;
            }
        };
        // The recurrence advance changes the note's visible due time. Nudge
        // every participant so their clients re-arm the new local alarm.
        if recurring {
            state.notify_note(&note.id).await;
        }
        let notification = reminder_notification(&note);
        let participants = match state.repo.participant_ids(&note.id).await {
            Ok(participants) => participants,
            Err(error) => {
                state.report_background_failure("reminder_participants", &format!("{error:?}"));
                continue;
            }
        };
        for user_id in participants {
            let settings = match state.repo.settings_for_user(&user_id).await {
                Ok(settings) => settings,
                Err(error) => {
                    state.report_background_failure("reminder_settings", &format!("{error:?}"));
                    continue;
                }
            };
            let settings = settings_value(settings.as_deref());
            if !notifications_enabled(&settings) {
                continue;
            }
            for error in send_configured(&state.notifiers, &settings, &notification).await {
                state.report_background_failure("reminder_delivery", &error);
            }
        }
    }
}

/// Run [`sweep_due_reminders`] forever on a fixed cadence. Spawned once at
/// startup; the first pass runs immediately, catching up on anything that
/// came due while the server was down.
pub fn spawn_reminder_scheduler(state: AppState) {
    tokio::spawn(async move {
        loop {
            sweep_due_reminders(&state).await;
            tokio::time::sleep(Duration::from_secs(REMINDER_SWEEP_SECS)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::ChecklistItem;

    fn connectors() -> Vec<Arc<dyn Connector>> {
        default_connectors()
    }

    #[test]
    fn connector_configured_checks() {
        let ntfy = &connectors()[0];
        let telegram = &connectors()[1];

        let empty = settings_value(None);
        assert!(!ntfy.configured(&empty));
        assert!(!telegram.configured(&empty));
        assert!(notifications_enabled(&empty));

        let s = settings_value(Some(r#"{"ntfy_url":" https://ntfy.sh/t "}"#));
        assert!(ntfy.configured(&s));
        assert!(!telegram.configured(&s));

        // Telegram needs BOTH token and chat id.
        let s = settings_value(Some(r#"{"telegram_bot_token":"123:abc"}"#));
        assert!(!telegram.configured(&s));
        let s = settings_value(Some(
            r#"{"telegram_bot_token":"123:abc","telegram_chat_id":"42",
                "reminder_notifications":false}"#,
        ));
        assert!(telegram.configured(&s));
        assert!(!notifications_enabled(&s));

        // Garbage documents read as unconfigured, not as errors.
        let s = settings_value(Some("not json"));
        assert!(!ntfy.configured(&s));
    }

    #[test]
    fn ntfy_url_splitting() {
        assert_eq!(
            split_ntfy_url("https://ntfy.sh/mytopic"),
            Some(("https://ntfy.sh".into(), "mytopic".into()))
        );
        assert_eq!(
            split_ntfy_url("http://my.host:8080/alerts/"),
            Some(("http://my.host:8080".into(), "alerts".into()))
        );
        // Scheme defaults to https.
        assert_eq!(
            split_ntfy_url("ntfy.sh/mytopic"),
            Some(("https://ntfy.sh".into(), "mytopic".into()))
        );
        // No topic path -> unusable.
        assert_eq!(split_ntfy_url("https://ntfy.sh"), None);
        assert_eq!(split_ntfy_url("https://ntfy.sh/"), None);
        assert_eq!(split_ntfy_url(""), None);
    }

    fn record(title: &str, content: &str, items: Vec<ChecklistItem>) -> NoteRecord {
        NoteRecord {
            workspace_id: "w1".to_string(),
            id: "n1".into(),
            created_by: Some("u1".into()),
            kind: "text".into(),
            title: title.into(),
            content: content.into(),
            items,
            color: "default".into(),
            pinned: false,
            archived: false,
            trashed: false,
            position: 0.0,
            reminder_at: Some("2026-07-17T10:00:00+00:00".into()),
            reminder_repeat: None,
            reminder_fired_at: None,
            transcript_status: "none".into(),
            created_at: String::new(),
            updated_at: String::new(),
            last_editor_id: None,
            stage_id: None,
            stage_position: 0.0,
        }
    }

    #[test]
    fn reminder_rendering() {
        let n = reminder_notification(&record("Water plants", "the ficus too", vec![]));
        assert_eq!(n.title, "Water plants");
        assert_eq!(n.body, "the ficus too");

        // Untitled note falls back; checklist body lists only pending items.
        let items = vec![
            ChecklistItem {
                id: "1".into(),
                text: "milk".into(),
                done: false,
            },
            ChecklistItem {
                id: "2".into(),
                text: "bread".into(),
                done: true,
            },
            ChecklistItem {
                id: "3".into(),
                text: "eggs".into(),
                done: false,
            },
        ];
        let n = reminder_notification(&record("", "", items));
        assert_eq!(n.title, "Reminder");
        assert_eq!(n.body, "milk\neggs");

        // Long content is capped with an ellipsis.
        let long = "x".repeat(2_000);
        let n = reminder_notification(&record("t", &long, vec![]));
        assert_eq!(n.body.chars().count(), 501);
        assert!(n.body.ends_with('…'));
    }

    #[test]
    fn recurrence_advances_past_missed_occurrences() {
        let now = "2026-08-01T12:00:00Z".parse::<DateTime<Utc>>().unwrap();
        assert_eq!(
            next_recurring_reminder("2026-07-29T09:00:00Z", "daily", now).as_deref(),
            Some("2026-08-02T09:00:00+00:00"),
        );
        assert_eq!(
            next_recurring_reminder("2026-01-31T09:00:00Z", "monthly", now).as_deref(),
            Some("2026-08-31T09:00:00+00:00"),
        );
    }
}
