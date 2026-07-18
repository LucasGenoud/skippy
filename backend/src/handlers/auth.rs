//! Registration, login, and session endpoints.

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;

use crate::AppState;
use crate::auth::{AuthUser, SessionToken, hash_password, verify_password};
use crate::error::{ApiError, ApiResult};
use crate::models::*;

use super::new_id;

fn validate_credentials(creds: &Credentials) -> ApiResult<()> {
    let name_ok = creds.username.len() >= 3
        && creds.username.len() <= 32
        && creds
            .username
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.');
    if !name_ok {
        return Err(ApiError::BadRequest(
            "username must be 3-32 characters (letters, digits, _ - .)".to_string(),
        ));
    }
    if creds.password.len() < 6 {
        return Err(ApiError::BadRequest("password must be at least 6 characters".to_string()));
    }
    Ok(())
}

pub async fn register(
    State(state): State<AppState>,
    Json(creds): Json<Credentials>,
) -> ApiResult<(StatusCode, Json<AuthResponse>)> {
    validate_credentials(&creds)?;
    let user = User {
        id: new_id(),
        username: creds.username.trim().to_string(),
        password_hash: hash_password(&creds.password)?,
    };
    state.repo.create_user(&user).await?;
    let token = new_id();
    state.repo.create_session(&token, &user.id).await?;
    Ok((StatusCode::CREATED, Json(AuthResponse { token, user: user.public() })))
}

pub async fn login(
    State(state): State<AppState>,
    Json(creds): Json<Credentials>,
) -> ApiResult<Json<AuthResponse>> {
    let user = state
        .repo
        .user_by_username(creds.username.trim())
        .await?
        .filter(|u| verify_password(&creds.password, &u.password_hash))
        .ok_or(ApiError::Unauthorized)?;
    let token = new_id();
    state.repo.create_session(&token, &user.id).await?;
    Ok(Json(AuthResponse { token, user: user.public() }))
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
) -> ApiResult<Json<UserPublic>> {
    let user = state.repo.user_by_id(&user_id).await?.ok_or(ApiError::Unauthorized)?;
    Ok(Json(user.public()))
}
