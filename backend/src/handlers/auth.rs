//! Registration, login, session, and password reset endpoints.

use axum::Json;
use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Redirect, Response};
use chrono::{DateTime, TimeDelta, Utc};
use std::time::Duration;

use crate::AppState;
use crate::auth::{AuthUser, SessionToken, hash_password, verify_login, verify_password};
use crate::error::{ApiError, ApiResult};
use crate::models::*;

use super::{CHANGED_MSG, new_id, new_token};

const LOGIN_ATTEMPTS: usize = 8;
const LOGIN_WINDOW: Duration = Duration::from_secs(5 * 60);
const REGISTRATION_ATTEMPTS: usize = 20;
const REGISTRATION_WINDOW: Duration = Duration::from_secs(60);
/// Per-address ceiling on reset emails. Low, because each one costs the
/// operator a message and lands in someone else's inbox.
const RESET_REQUEST_ATTEMPTS: usize = 3;
const RESET_REQUEST_WINDOW: Duration = Duration::from_secs(15 * 60);
/// A second, address-independent ceiling: the per-address one alone would let
/// a stranger walk a word list and mail every account on the server.
const RESET_MAIL_ATTEMPTS: usize = 30;
const RESET_MAIL_WINDOW: Duration = Duration::from_secs(60 * 60);
/// Guessing ceiling on the token itself. The token is 192 random bits, so this
/// only exists to keep a broken client from hammering the endpoint.
const RESET_REDEEM_ATTEMPTS: usize = 20;
const RESET_REDEEM_WINDOW: Duration = Duration::from_secs(15 * 60);
/// How long an emailed link stays good. Long enough to survive a mail server
/// that queues, short enough that an old message in an inbox is inert.
const RESET_LINK_TTL: TimeDelta = TimeDelta::hours(1);
/// Path the app serves the reset form at. Anything under it reaches
/// `index.html` through the static-file fallback, exactly like `/s/<token>`.
const RESET_PATH: &str = "/reset/";
/// Guessing ceiling on SSO handoff codes. 256 random bits, single use; this
/// only keeps a broken client from hammering the endpoint.
const SSO_EXCHANGE_ATTEMPTS: usize = 30;
const SSO_EXCHANGE_WINDOW: Duration = Duration::from_secs(60);
/// Length of an S256 PKCE challenge: 32 digest bytes in unpadded base64url.
const PKCE_CHALLENGE_LEN: usize = 43;
/// Name given to an SSO account whose provider shared no usable one.
const FALLBACK_NAME: &str = "Skippy user";
const MAX_NAME_CHARS: usize = 100;

fn validate_name(name: &str) -> ApiResult<String> {
    let name = name.trim();
    let name_ok = (2..=100).contains(&name.chars().count()) && !name.chars().any(char::is_control);
    if !name_ok {
        return Err(ApiError::BadRequest(
            "name must be 2-100 characters".to_string(),
        ));
    }
    Ok(name.to_string())
}

fn validate_email(email: &str) -> ApiResult<String> {
    let email = email.trim().to_lowercase();
    let mut parts = email.split('@');
    let local = parts.next().unwrap_or_default();
    let domain = parts.next().unwrap_or_default();
    let valid = !local.is_empty()
        && !domain.is_empty()
        && parts.next().is_none()
        && !email.chars().any(char::is_whitespace)
        && email.len() <= 254;
    if !valid {
        return Err(ApiError::BadRequest(
            "enter a valid email address".to_string(),
        ));
    }
    Ok(email)
}

/// Refuse a password endpoint on a deployment that signs in only through
/// single sign-on (`PASSWORD_LOGIN=false`).
fn require_password_login(state: &AppState) -> ApiResult<()> {
    if !state.password_login {
        return Err(ApiError::Forbidden(
            "this server signs in with single sign-on only",
        ));
    }
    Ok(())
}

fn validate_password(password: &str) -> ApiResult<()> {
    if password.len() < 6 {
        return Err(ApiError::BadRequest(
            "password must be at least 6 characters".to_string(),
        ));
    }
    Ok(())
}

pub async fn register(
    State(state): State<AppState>,
    Json(request): Json<RegisterRequest>,
) -> ApiResult<(StatusCode, Json<AuthResponse>)> {
    require_password_login(&state)?;
    state
        .auth_attempts
        .check("registration", REGISTRATION_ATTEMPTS, REGISTRATION_WINDOW)
        .map_err(ApiError::RateLimited)?;
    let name = validate_name(&request.name)?;
    let email = validate_email(&request.email)?;
    validate_password(&request.password)?;
    let user = User {
        id: new_id(),
        name,
        email,
        password_hash: hash_password(&request.password)?,
        avatar: None,
    };
    state.repo.create_user(&user).await?;
    // Every account starts with a workspace; notes have nowhere to live
    // without one.
    super::create_default_workspace(&state, &user.id).await?;
    let token = new_id();
    state.repo.create_session(&token, &user.id).await?;
    Ok((
        StatusCode::CREATED,
        Json(AuthResponse {
            token,
            user: user.account(),
        }),
    ))
}

pub async fn login(
    State(state): State<AppState>,
    Json(request): Json<LoginRequest>,
) -> ApiResult<Json<AuthResponse>> {
    require_password_login(&state)?;
    let email = request.email.trim().to_lowercase();
    let limit_key = format!("login:{email}");
    state
        .auth_attempts
        .check(&limit_key, LOGIN_ATTEMPTS, LOGIN_WINDOW)
        .map_err(ApiError::RateLimited)?;
    let user = state.repo.user_by_email(&email).await?;
    let stored = user.as_ref().map(|u| u.password_hash.as_str());
    if !verify_login(&request.password, stored) {
        return Err(ApiError::Unauthorized);
    }
    let user = user.ok_or(ApiError::Unauthorized)?;
    state.auth_attempts.reset(&limit_key);
    let token = new_id();
    state.repo.create_session(&token, &user.id).await?;
    Ok(Json(AuthResponse {
        token,
        user: user.account(),
    }))
}

pub async fn logout(
    State(state): State<AppState>,
    SessionToken(token): SessionToken,
) -> ApiResult<StatusCode> {
    state.repo.delete_session(&token).await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn me(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
) -> ApiResult<Json<AccountPublic>> {
    let user = state
        .repo
        .user_by_id(&user_id)
        .await?
        .ok_or(ApiError::Unauthorized)?;
    Ok(Json(user.account()))
}

pub async fn update_account(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    SessionToken(session): SessionToken,
    Json(request): Json<UpdateAccountRequest>,
) -> ApiResult<Json<AccountPublic>> {
    if request.name.is_none() && request.email.is_none() && request.new_password.is_none() {
        return Err(ApiError::BadRequest("nothing to update".to_string()));
    }

    let user = state
        .repo
        .user_by_id(&user_id)
        .await?
        .ok_or(ApiError::Unauthorized)?;
    let name = match request.name {
        Some(name) => validate_name(&name)?,
        None => user.name.clone(),
    };
    let name_changed = name != user.name;
    let email = match request.email {
        Some(email) => validate_email(&email)?,
        None => user.email.clone(),
    };

    let changing_email = !email.eq_ignore_ascii_case(&user.email);
    let sensitive = changing_email || request.new_password.is_some();
    // Nothing to confirm such a change with; the provider owns the address,
    // and a password comes through the reset email instead.
    if sensitive && !user.has_password() {
        return Err(ApiError::Forbidden(
            "this account signs in with single sign-on",
        ));
    }
    if sensitive {
        let current = request.current_password.as_deref().unwrap_or_default();
        if !verify_password(current, &user.password_hash) {
            return Err(ApiError::Forbidden("current password is incorrect"));
        }
    }

    let changing_password = request.new_password.is_some();
    let password_hash = match request.new_password {
        Some(password) => {
            validate_password(&password)?;
            hash_password(&password)?
        }
        None => user.password_hash.clone(),
    };
    state
        .repo
        .update_user(&user_id, &name, &email, &password_hash)
        .await?;
    // Like a reset: whoever knew the old password keeps no way back in,
    // but the device making the change stays signed in.
    if changing_password {
        state.repo.delete_other_sessions(&user_id, &session).await?;
        state.repo.delete_api_tokens_for_user(&user_id).await?;
    }
    if name_changed {
        let audience = state.repo.account_audience(&user_id).await?;
        state.hub.notify(&audience, CHANGED_MSG);
    }
    Ok(Json(AccountPublic {
        id: user_id,
        name,
        email,
        has_password: user.has_password(),
        avatar: user.avatar,
    }))
}

pub async fn delete_account(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Json(request): Json<DeleteAccountRequest>,
) -> ApiResult<StatusCode> {
    let user = state
        .repo
        .user_by_id(&user_id)
        .await?
        .ok_or(ApiError::Unauthorized)?;
    // An account made by single sign-on has no password; the session is
    // all there is to go on.
    if user.has_password() && !verify_password(&request.current_password, &user.password_hash) {
        return Err(ApiError::Forbidden("current password is incorrect"));
    }

    let deleted = state
        .repo
        .delete_account(&user_id)
        .await?
        .ok_or(ApiError::Unauthorized)?;
    state.drain_cleanup_jobs().await;
    state.hub.notify(&deleted.audience, CHANGED_MSG);
    Ok(StatusCode::NO_CONTENT)
}

// ---------------------------------------------------------------------------
// Password reset

/// Whether this deployment can run a password reset at all: it needs a mail
/// server of its own to send from, and a public address to build the link
/// with. Advertised on `/api/capabilities` so the app only offers "Forgot
/// password?" where pressing it would do something.
pub fn password_reset_available(state: &AppState) -> bool {
    state.password_login
        && state.public_url.is_some()
        && crate::notify::server_mail_configured(&state.managed)
}

/// The message that lands in someone's inbox. Plain text: it has to survive
/// every mail client, and there is nothing here worth styling.
fn reset_notification(name: &str, link: &str) -> crate::notify::Notification {
    crate::notify::Notification {
        title: "Reset your Skippy password".to_string(),
        body: format!(
            "Hi {name},\n\n\
             Someone asked to reset the password on your Skippy account. Open \
             this link to choose a new one:\n\n\
             {link}\n\n\
             The link works once and expires in an hour. If this wasn't you, \
             ignore this message; nothing has changed.",
        ),
    }
}

/// Start a reset: mail a one-shot link to the address, if it has an account.
///
/// Answers 202 whatever happens, so the endpoint cannot be used to find out
/// which addresses are registered here. For the same reason the mail goes out
/// on a detached task: awaiting an SMTP round trip only when the account
/// exists would put the answer back into the response time. A send that fails
/// is reported through [`AppState::report_background_failure`], where the
/// operator can see it; the caller is told nothing either way.
pub async fn forgot_password(
    State(state): State<AppState>,
    Json(request): Json<ForgotPasswordRequest>,
) -> ApiResult<StatusCode> {
    if !password_reset_available(&state) {
        return Err(ApiError::Unavailable(
            "this server cannot send password reset email",
        ));
    }
    let email = request.email.trim().to_lowercase();
    state
        .auth_attempts
        .check("password-reset", RESET_MAIL_ATTEMPTS, RESET_MAIL_WINDOW)
        .map_err(ApiError::RateLimited)?;
    state
        .auth_attempts
        .check(
            &format!("password-reset:{email}"),
            RESET_REQUEST_ATTEMPTS,
            RESET_REQUEST_WINDOW,
        )
        .map_err(ApiError::RateLimited)?;

    if let Some(user) = state.repo.user_by_email(&email).await? {
        let token = new_token();
        let expires_at = (Utc::now() + RESET_LINK_TTL).to_rfc3339();
        state
            .repo
            .create_password_reset(&token, &user.id, &expires_at)
            .await?;
        let base = state.public_url.as_deref().unwrap_or_default();
        let link = format!("{base}{RESET_PATH}{token}");
        // `password_reset_available` already established that these resolve.
        if let Some(settings) = crate::notify::server_mail(&state.managed, &user.email) {
            let notification = reset_notification(&user.name, &link);
            let mailer = state.clone();
            tokio::spawn(async move {
                let errors =
                    crate::notify::send_configured(&mailer.notifiers, &settings, &notification)
                        .await;
                if !errors.is_empty() {
                    mailer.report_background_failure("password_reset_email", &errors.join("; "));
                }
            });
        }
    }
    Ok(StatusCode::ACCEPTED)
}

/// Redeem a reset link and set the new password.
///
/// The link is spent whether or not it had expired, and every session the
/// account holds is dropped: someone who needed a reset should not leave a
/// signed-in device behind them.
pub async fn reset_password(
    State(state): State<AppState>,
    Json(request): Json<ResetPasswordRequest>,
) -> ApiResult<Json<ResetPasswordResponse>> {
    require_password_login(&state)?;
    state
        .auth_attempts
        .check(
            "password-reset-redeem",
            RESET_REDEEM_ATTEMPTS,
            RESET_REDEEM_WINDOW,
        )
        .map_err(ApiError::RateLimited)?;
    // Checked before the token is spent, so a password the server was always
    // going to refuse does not cost someone their link.
    validate_password(&request.password)?;

    // One wording for every way a link can fail to resolve: which of them it
    // was is the holder's business to guess, not ours to confirm.
    let expired = || ApiError::Forbidden("this reset link has expired or was already used");
    let reset = state
        .repo
        .consume_password_reset(request.token.trim())
        .await?
        .ok_or_else(expired)?;
    let fresh =
        DateTime::parse_from_rfc3339(&reset.expires_at).is_ok_and(|instant| instant > Utc::now());
    if !fresh {
        return Err(expired());
    }
    let user = state
        .repo
        .user_by_id(&reset.user_id)
        .await?
        .ok_or_else(expired)?;

    let password_hash = hash_password(&request.password)?;
    state
        .repo
        .update_user(&user.id, &user.name, &user.email, &password_hash)
        .await?;
    state.repo.delete_sessions_for_user(&user.id).await?;
    // Tokens too: a reset is how someone takes an account back, and a token
    // left behind would keep whoever they took it back from inside.
    state.repo.delete_api_tokens_for_user(&user.id).await?;
    // A fresh password clears the failed-login penalty; otherwise someone who
    // locked themselves out has to wait out the window they just fixed.
    state.auth_attempts.reset(&format!("login:{}", user.email));
    Ok(Json(ResetPasswordResponse { email: user.email }))
}

// ---------------------------------------------------------------------------
// Single sign-on. The flow is described in `crate::oidc`.

fn require_sso(state: &AppState) -> ApiResult<&crate::oidc::OidcProvider> {
    state.oidc.as_deref().ok_or(ApiError::Unavailable(
        "single sign-on is not configured on this server",
    ))
}

#[derive(Debug, serde::Deserialize)]
pub struct SsoStartQuery {
    return_to: String,
    code_challenge: String,
}

/// Send the browser to the identity provider. `return_to` is where the
/// handoff code goes afterwards; `code_challenge` binds that code to the app
/// that asked.
pub async fn sso_start(
    State(state): State<AppState>,
    Query(query): Query<SsoStartQuery>,
) -> ApiResult<Redirect> {
    let oidc = require_sso(&state)?;
    if !oidc.allowed_return(&query.return_to) {
        return Err(ApiError::BadRequest(
            "return_to is not an address of this app".to_string(),
        ));
    }
    let challenge_ok = query.code_challenge.len() == PKCE_CHALLENGE_LEN
        && query
            .code_challenge
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    if !challenge_ok {
        return Err(ApiError::BadRequest(
            "code_challenge must be an S256 PKCE challenge".to_string(),
        ));
    }
    // A provider that cannot be reached is reported to the app, not shown as
    // JSON inside the auth session the person would have to cancel out of.
    let url = match oidc.begin(&query.return_to, &query.code_challenge).await {
        Ok(url) => url,
        Err(error) => crate::oidc::with_param(&query.return_to, "sso_error", error.message()),
    };
    Ok(Redirect::to(&url))
}

#[derive(Debug, serde::Deserialize)]
pub struct SsoCallbackQuery {
    #[serde(default)]
    code: Option<String>,
    #[serde(default)]
    state: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

/// Where the identity provider sends the browser back. Always answers with a
/// redirect to the app, carrying either `sso_code` or `sso_error`, unless the
/// sign-in it names is unknown, in which case there is nowhere safe to go.
pub async fn sso_callback(
    State(state): State<AppState>,
    Query(query): Query<SsoCallbackQuery>,
) -> Response {
    let Some(oidc) = state.oidc.clone() else {
        return ApiError::Unavailable("single sign-on is not configured on this server")
            .into_response();
    };
    let Some(login) = query.state.as_deref().and_then(|s| oidc.take_pending(s)) else {
        return (
            StatusCode::BAD_REQUEST,
            "This sign-in has expired. Go back to Skippy and try again.",
        )
            .into_response();
    };
    let fail = |message: &str| {
        Redirect::to(&crate::oidc::with_param(
            &login.return_to,
            "sso_error",
            message,
        ))
        .into_response()
    };

    if let Some(error) = query.error.as_deref() {
        return fail(match error {
            "access_denied" => "sign-in was cancelled",
            _ => "the identity provider refused the sign-in",
        });
    }
    let Some(code) = query.code.as_deref() else {
        return fail("the identity provider sent no sign-in code");
    };
    let identity = match oidc.finish(code, &login).await {
        Ok(identity) => identity,
        Err(error) => {
            crate::telemetry::event(
                "warn",
                "sso_rejected",
                serde_json::json!({ "reason": error.message() }),
            );
            return fail(error.message());
        }
    };
    let (user, created) = match sso_account(&state, &identity).await {
        Ok(found) => found,
        Err(SsoRefusal::Refused(message)) => return fail(message),
        Err(SsoRefusal::Failed(error)) => {
            state.report_background_failure("sso_account", &format!("{error:?}"));
            return fail("the account could not be opened, try again");
        }
    };
    let handoff = oidc.hand_off(&user.id, &login.app_challenge, created);
    Redirect::to(&crate::oidc::with_param(
        &login.return_to,
        "sso_code",
        &handoff,
    ))
    .into_response()
}

enum SsoRefusal {
    /// Shown to the person signing in.
    Refused(&'static str),
    Failed(ApiError),
}

impl From<ApiError> for SsoRefusal {
    fn from(error: ApiError) -> Self {
        SsoRefusal::Failed(error)
    }
}

impl From<crate::store::RepoError> for SsoRefusal {
    fn from(error: crate::store::RepoError) -> Self {
        SsoRefusal::Failed(error.into())
    }
}

/// The account an identity signs into, made on first sign-in, and whether
/// this sign-in made it.
///
/// An identity seen before keeps its account even if its email changed at the
/// provider. A new one takes over an existing account with the same address
/// only when the provider vouches for that address; otherwise whoever can set
/// an unverified email at the provider could walk into someone else's notes.
async fn sso_account(
    state: &AppState,
    identity: &crate::oidc::Identity,
) -> Result<(User, bool), SsoRefusal> {
    let repo = &state.repo;
    if let Some(user) = repo
        .user_by_identity(&identity.issuer, &identity.subject)
        .await?
    {
        return Ok((user, false));
    }

    let Some(email) = identity.email.as_deref() else {
        return Err(SsoRefusal::Refused(
            "the identity provider did not share an email address",
        ));
    };
    let Ok(email) = validate_email(email) else {
        return Err(SsoRefusal::Refused(
            "the identity provider shared an invalid email address",
        ));
    };

    if let Some(user) = repo.user_by_email(&email).await? {
        if !identity.email_verified {
            return Err(SsoRefusal::Refused(
                "an account with this email already exists, and the identity provider has not verified the address",
            ));
        }
        repo.link_identity(&user.id, &identity.issuer, &identity.subject)
            .await?;
        return Ok((user, false));
    }

    let user = User {
        id: new_id(),
        name: sso_name(identity.name.as_deref(), &email),
        email,
        password_hash: NO_PASSWORD.to_string(),
        avatar: None,
    };
    repo.create_user(&user).await?;
    super::create_default_workspace(state, &user.id).await?;
    repo.link_identity(&user.id, &identity.issuer, &identity.subject)
        .await?;
    Ok((user, true))
}

/// A display name for a new SSO account: the provider's, else the email's
/// local part, else a placeholder the person can rename.
fn sso_name(provided: Option<&str>, email: &str) -> String {
    let local = email.split('@').next().unwrap_or_default();
    [provided.unwrap_or_default(), local]
        .into_iter()
        .map(|name| name.chars().take(MAX_NAME_CHARS).collect::<String>())
        .find_map(|name| validate_name(&name).ok())
        .unwrap_or_else(|| FALLBACK_NAME.to_string())
}

/// Trade a handoff code for a session.
pub async fn sso_exchange(
    State(state): State<AppState>,
    Json(request): Json<SsoExchangeRequest>,
) -> ApiResult<Json<SsoExchangeResponse>> {
    let oidc = require_sso(&state)?;
    // Only failures count: a code is 256 random bits, so the ceiling is there
    // to slow a hammering client, and must never lock out real sign-ins.
    let Some((user_id, created)) = oidc.redeem(request.code.trim(), &request.code_verifier) else {
        state
            .auth_attempts
            .check("sso-exchange", SSO_EXCHANGE_ATTEMPTS, SSO_EXCHANGE_WINDOW)
            .map_err(ApiError::RateLimited)?;
        return Err(ApiError::Unauthorized);
    };
    let user = state
        .repo
        .user_by_id(&user_id)
        .await?
        .ok_or(ApiError::Unauthorized)?;
    let token = new_id();
    state.repo.create_session(&token, &user.id).await?;
    Ok(Json(SsoExchangeResponse {
        token,
        user: user.account(),
        created,
    }))
}
