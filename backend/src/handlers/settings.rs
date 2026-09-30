//! Per-user settings: an opaque JSON document owned by the client.

use axum::Json;
use axum::extract::State;
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};

use super::{workspace_ai, workspaces};

const MAX_SETTINGS_BYTES: usize = 16 * 1024;

pub async fn get_settings(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
) -> ApiResult<Response> {
    let data = state
        .repo
        .settings_for_user(&user_id)
        .await?
        .unwrap_or_else(|| "{}".to_string());
    Ok(([(header::CONTENT_TYPE, "application/json")], data).into_response())
}

/// The settings document is an opaque JSON object owned by the client; the
/// server only validates shape and size and fans out a change event so other
/// devices pick it up.
pub async fn put_settings(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Json(body): Json<serde_json::Value>,
) -> ApiResult<StatusCode> {
    if !body.is_object() {
        return Err(ApiError::BadRequest(
            "settings must be a JSON object".to_string(),
        ));
    }
    let data = body.to_string();
    if data.len() > MAX_SETTINGS_BYTES {
        return Err(ApiError::BadRequest(
            "settings document too large".to_string(),
        ));
    }
    // Members of this user's workspaces are shown whether the owner has a
    // provider and what their rewrite tasks are called, so a change to either
    // has to reach their devices too.
    let before = workspace_ai::owner_view(&state, &user_id).await?;
    state.repo.put_settings(&user_id, &data).await?;
    state.notify_user(&user_id);
    if workspace_ai::owner_view(&state, &user_id).await? != before {
        for workspace in state.repo.workspaces_for_user(&user_id).await? {
            if workspace.owner.id == user_id && !workspace.members.is_empty() {
                workspaces::notify_workspace(&state, &workspace.id).await;
            }
        }
    }
    Ok(StatusCode::NO_CONTENT)
}
