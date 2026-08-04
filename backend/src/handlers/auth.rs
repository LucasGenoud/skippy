//! Registration, login, and session endpoints.

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use std::time::Duration;

use crate::AppState;
use crate::auth::{AuthUser, SessionToken, hash_password, verify_password};
use crate::error::{ApiError, ApiResult};
use crate::models::*;

use super::{CHANGED_MSG, new_id};

const LOGIN_ATTEMPTS: usize = 8;
const LOGIN_WINDOW: Duration = Duration::from_secs(5 * 60);
const REGISTRATION_ATTEMPTS: usize = 20;
const REGISTRATION_WINDOW: Duration = Duration::from_secs(60);

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
    let email = request.email.trim().to_lowercase();
    let limit_key = format!("login:{email}");
    state
        .auth_attempts
        .check(&limit_key, LOGIN_ATTEMPTS, LOGIN_WINDOW)
        .map_err(ApiError::RateLimited)?;
    let user = state
        .repo
        .user_by_email(&email)
        .await?
        .filter(|u| verify_password(&request.password, &u.password_hash))
        .ok_or(ApiError::Unauthorized)?;
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
    if changing_email || request.new_password.is_some() {
        let current = request.current_password.as_deref().unwrap_or_default();
        if !verify_password(current, &user.password_hash) {
            return Err(ApiError::Forbidden("current password is incorrect"));
        }
    }

    let password_hash = match request.new_password {
        Some(password) => {
            validate_password(&password)?;
            hash_password(&password)?
        }
        None => user.password_hash,
    };
    state
        .repo
        .update_user(&user_id, &name, &email, &password_hash)
        .await?;
    if name_changed {
        let audience = state.repo.account_audience(&user_id).await?;
        state.hub.notify(&audience, CHANGED_MSG);
    }
    Ok(Json(AccountPublic {
        id: user_id,
        name,
        email,
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
    if !verify_password(&request.current_password, &user.password_hash) {
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
