//! The signed-out password reset: capability gating, the emailed link, and
//! what redeeming one does to the account's password and sessions.

use crate::helpers::*;

use async_trait::async_trait;
use sticky_notes_server::config::ManagedSettings;
use sticky_notes_server::notify::{Connector, Notification};

/// Every message the fake mail server accepted: (recipient, subject, body).
type Mailbox = Arc<std::sync::Mutex<Vec<(String, String, String)>>>;

/// Stands in for `SmtpConnector`, reading the same `smtp_to` key out of the
/// same settings document, so these tests exercise the real server-mail
/// contract with only the SMTP transport faked.
struct FakeMailer {
    sent: Mailbox,
    fail: bool,
}

#[async_trait]
impl Connector for FakeMailer {
    fn name(&self) -> &'static str {
        "email"
    }

    fn configured(&self, settings: &Value) -> bool {
        settings["smtp_to"]
            .as_str()
            .map(str::trim)
            .is_some_and(|to| !to.is_empty())
    }

    async fn send(&self, settings: &Value, notification: &Notification) -> anyhow::Result<()> {
        if self.fail {
            anyhow::bail!("relay refused");
        }
        self.sent.lock().unwrap().push((
            settings["smtp_to"].as_str().unwrap_or_default().to_string(),
            notification.title.clone(),
            notification.body.clone(),
        ));
        Ok(())
    }
}

/// What an operator pins to make the server able to send its own mail.
fn mail_env() -> ManagedSettings {
    let pairs = [
        ("SMTP_HOST", "mail.example.test"),
        ("SMTP_FROM", "skippy@example.test"),
    ];
    ManagedSettings::from_lookup(|key| {
        pairs
            .iter()
            .find(|(k, _)| *k == key)
            .map(|(_, v)| v.to_string())
    })
}

/// A server configured for reset: a mail server, a public address, and a
/// recording mailer in place of SMTP.
async fn state_with_mail() -> (AppState, Mailbox) {
    let sent: Mailbox = Arc::default();
    let connectors: Vec<Arc<dyn Connector>> = vec![Arc::new(FakeMailer {
        sent: sent.clone(),
        fail: false,
    })];
    let state = state()
        .await
        .with_notifiers(connectors)
        .with_managed(mail_env())
        .with_public_url("https://notes.example.test/");
    (state, sent)
}

/// The reset mail leaves on a detached task; give it a beat to land.
async fn settle_mail() {
    tokio::time::sleep(std::time::Duration::from_millis(80)).await;
}

async fn request_reset(app: &Router, email: &str) -> StatusCode {
    let (status, _) = send(
        app,
        "POST",
        "/api/auth/forgot-password",
        None,
        Some(json!({ "email": email })),
    )
    .await;
    status
}

/// The token out of the one link the mailer was handed.
fn emailed_token(sent: &Mailbox) -> String {
    let mail = sent.lock().unwrap();
    let (_, _, body) = mail.last().expect("a reset email was sent");
    let link = body
        .split_whitespace()
        .find(|word| word.contains("/reset/"))
        .expect("the email carries a reset link");
    assert!(
        link.starts_with("https://notes.example.test/reset/"),
        "link is built from PUBLIC_URL: {link}"
    );
    link.rsplit('/').next().unwrap().to_string()
}

async fn login(app: &Router, email: &str, password: &str) -> (StatusCode, Value) {
    send(
        app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"email": email, "password": password})),
    )
    .await
}

#[tokio::test]
async fn capabilities_advertise_reset_only_with_mail_and_a_public_url() {
    let cases = [
        (state().await, false),
        (state().await.with_managed(mail_env()), false),
        (
            state().await.with_public_url("https://notes.example.test"),
            false,
        ),
        (
            state()
                .await
                .with_managed(mail_env())
                .with_public_url("https://notes.example.test"),
            true,
        ),
        // A blank PUBLIC_URL is the same as never setting one.
        (
            state().await.with_managed(mail_env()).with_public_url("  "),
            false,
        ),
    ];
    for (state, expected) in cases {
        let app = build_app(state);
        let (status, body) = send(&app, "GET", "/api/capabilities", None, None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["password_reset"], json!(expected), "{body}");
    }
}

#[tokio::test]
async fn a_server_without_mail_refuses_to_start_a_reset() {
    let app = app().await;
    let (status, body) = send(
        &app,
        "POST",
        "/api/auth/forgot-password",
        None,
        Some(json!({"email": "ada@example.test"})),
    )
    .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert!(body["error"].as_str().unwrap().contains("password reset"));
}

#[tokio::test]
async fn a_mailed_link_sets_a_new_password_and_ends_every_old_session() {
    let (state, sent) = state_with_mail().await;
    let app = build_app(state);
    let (session, _) = register(&app, "ada").await;

    assert_eq!(
        request_reset(&app, "ADA@example.test").await,
        StatusCode::ACCEPTED
    );
    settle_mail().await;
    let (to, subject, _) = sent.lock().unwrap().last().unwrap().clone();
    assert_eq!(to, "ada@example.test");
    assert!(subject.contains("Skippy"), "{subject}");
    let token = emailed_token(&sent);

    let (status, body) = send(
        &app,
        "POST",
        "/api/auth/reset-password",
        None,
        Some(json!({"token": token, "password": "new-hunter22"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["email"], "ada@example.test");

    // The old password is gone, the new one works.
    let (status, _) = login(&app, "ada@example.test", "hunter22").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, body) = login(&app, "ada@example.test", "new-hunter22").await;
    assert_eq!(status, StatusCode::OK, "{body}");

    // The session held before the reset no longer authenticates.
    let (status, _) = send(&app, "GET", "/api/auth/me", Some(&session), None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn a_link_works_once_and_a_new_request_retires_the_old_one() {
    let (state, sent) = state_with_mail().await;
    let app = build_app(state);
    register(&app, "ada").await;

    request_reset(&app, "ada@example.test").await;
    settle_mail().await;
    let first = emailed_token(&sent);
    request_reset(&app, "ada@example.test").await;
    settle_mail().await;
    let second = emailed_token(&sent);
    assert_ne!(first, second);

    // Asking again invalidated the earlier link.
    let (status, _) = send(
        &app,
        "POST",
        "/api/auth/reset-password",
        None,
        Some(json!({"token": first, "password": "new-hunter22"})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (status, _) = send(
        &app,
        "POST",
        "/api/auth/reset-password",
        None,
        Some(json!({"token": second.clone(), "password": "new-hunter22"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    // And the newest link is spent by that one use.
    let (status, _) = send(
        &app,
        "POST",
        "/api/auth/reset-password",
        None,
        Some(json!({"token": second, "password": "another-one"})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn a_rejected_password_does_not_spend_the_link() {
    let (state, sent) = state_with_mail().await;
    let app = build_app(state);
    register(&app, "ada").await;
    request_reset(&app, "ada@example.test").await;
    settle_mail().await;
    let token = emailed_token(&sent);

    let (status, body) = send(
        &app,
        "POST",
        "/api/auth/reset-password",
        None,
        Some(json!({"token": token.clone(), "password": "short"})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"].as_str().unwrap().contains("6 characters"));

    let (status, _) = send(
        &app,
        "POST",
        "/api/auth/reset-password",
        None,
        Some(json!({"token": token, "password": "long-enough"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn an_unknown_address_is_answered_the_same_way_and_mails_nobody() {
    let (state, sent) = state_with_mail().await;
    let app = build_app(state);
    register(&app, "ada").await;

    assert_eq!(
        request_reset(&app, "nobody@example.test").await,
        StatusCode::ACCEPTED
    );
    settle_mail().await;
    assert!(sent.lock().unwrap().is_empty(), "no mail for a stranger");
}

#[tokio::test]
async fn an_unknown_token_is_refused() {
    let (state, _sent) = state_with_mail().await;
    let app = build_app(state);
    register(&app, "ada").await;

    let (status, body) = send(
        &app,
        "POST",
        "/api/auth/reset-password",
        None,
        Some(json!({"token": "0".repeat(48), "password": "new-hunter22"})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert!(body["error"].as_str().unwrap().contains("reset link"));
}

#[tokio::test]
async fn repeated_requests_for_one_address_are_rate_limited() {
    let (state, _sent) = state_with_mail().await;
    let app = build_app(state);
    register(&app, "ada").await;

    for attempt in 0..3 {
        assert_eq!(
            request_reset(&app, "ada@example.test").await,
            StatusCode::ACCEPTED,
            "attempt {attempt}"
        );
    }
    assert_eq!(
        request_reset(&app, "ada@example.test").await,
        StatusCode::TOO_MANY_REQUESTS
    );
    // The ceiling is per address, so a different one still gets through.
    assert_eq!(
        request_reset(&app, "bob@example.test").await,
        StatusCode::ACCEPTED
    );
}

#[tokio::test]
async fn a_mail_server_that_refuses_is_recorded_but_not_reported_to_the_caller() {
    let sent: Mailbox = Arc::default();
    let connectors: Vec<Arc<dyn Connector>> = vec![Arc::new(FakeMailer { sent, fail: true })];
    let state = state()
        .await
        .with_notifiers(connectors)
        .with_managed(mail_env())
        .with_public_url("https://notes.example.test");
    let app = build_app(state);
    register(&app, "ada").await;

    assert_eq!(
        request_reset(&app, "ada@example.test").await,
        StatusCode::ACCEPTED
    );
    settle_mail().await;
    let (status, body) = send(&app, "GET", "/api/health", None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["background"]["failed_total"], json!(1), "{body}");
}
