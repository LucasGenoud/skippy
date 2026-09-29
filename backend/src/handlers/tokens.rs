//! Personal access tokens: the credential an MCP client uses in place of a
//! signed-in session. Managed only from a session, so a token cannot mint or
//! revoke tokens.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::models::{ApiTokenView, CreateApiToken, CreatedApiToken, TokenScope};

use super::{new_id, new_token};

/// Marks a secret as a Skippy token wherever it ends up pasted.
const SECRET_PREFIX: &str = "skp_";
const MAX_NAME_CHARS: usize = 80;
const MAX_TOKENS_PER_USER: usize = 50;

pub async fn list_api_tokens(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
) -> ApiResult<Json<Vec<ApiTokenView>>> {
    Ok(Json(state.repo.api_tokens_for_user(&user_id).await?))
}

pub async fn create_api_token(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Json(body): Json<CreateApiToken>,
) -> ApiResult<(StatusCode, Json<CreatedApiToken>)> {
    let name = body.name.trim();
    if name.is_empty() || name.chars().count() > MAX_NAME_CHARS {
        return Err(ApiError::BadRequest(format!(
            "token name must be 1 to {MAX_NAME_CHARS} characters"
        )));
    }
    let scope = TokenScope::from_wire(&body.scope)
        .ok_or_else(|| ApiError::BadRequest("scope must be read or write".to_string()))?;
    if state.repo.api_tokens_for_user(&user_id).await?.len() >= MAX_TOKENS_PER_USER {
        return Err(ApiError::BadRequest(format!(
            "an account can hold at most {MAX_TOKENS_PER_USER} tokens"
        )));
    }

    let secret = format!("{SECRET_PREFIX}{}", new_token());
    let token = state
        .repo
        .create_api_token(&new_id(), &user_id, name, scope, &secret)
        .await?;
    Ok((StatusCode::CREATED, Json(CreatedApiToken { token, secret })))
}

pub async fn delete_api_token(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    if !state.repo.delete_api_token(&id, &user_id).await? {
        return Err(ApiError::NotFound);
    }
    Ok(StatusCode::NO_CONTENT)
}
