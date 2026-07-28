//! Label CRUD. Labels belong to a workspace and are shared by everyone in it,
//! so any member may create, restyle, or remove them. Assigning labels to
//! notes happens through the note-update endpoint (`label_ids` on the patch
//! body), not here.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::models::*;

use super::{new_id, resolve_workspace};

pub async fn list_labels(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
) -> ApiResult<Json<Vec<Label>>> {
    Ok(Json(state.repo.labels_for_user(&user_id).await?))
}

pub async fn create_label(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Json(body): Json<LabelPayload>,
) -> ApiResult<(StatusCode, Json<Label>)> {
    let name = body.name.trim().to_string();
    if name.is_empty() {
        return Err(ApiError::BadRequest("label name is empty".to_string()));
    }
    let workspace_id = resolve_workspace(&state, &user_id, body.workspace_id.as_deref()).await?;
    // A new label goes to the end of the sidebar list unless the caller places it.
    let position = match body.position {
        Some(p) => p,
        None => state.repo.max_label_position(&workspace_id).await? + 1024.0,
    };
    let label = Label {
        id: body.id.filter(|id| !id.trim().is_empty()).unwrap_or_else(new_id),
        workspace_id,
        name,
        color: clean(body.color),
        icon: clean(body.icon),
        position,
    };
    state.repo.insert_label(&label).await?;
    notify_workspace(&state, &label.workspace_id).await;
    Ok((StatusCode::CREATED, Json(label)))
}

/// A label is workspace state: everyone in the workspace needs the change.
async fn notify_workspace(state: &AppState, workspace_id: &str) {
    if let Ok(ids) = state.repo.workspace_member_ids(workspace_id).await {
        state.hub.notify(&ids, super::CHANGED_MSG);
    }
}

/// Trim a presentation field; empty becomes `None` so the client's "clear"
/// (an empty string) resets the label to the theme default.
fn clean(v: Option<String>) -> Option<String> {
    v.map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

pub async fn update_label(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
    Json(body): Json<LabelPayload>,
) -> ApiResult<Json<Label>> {
    let name = body.name.trim().to_string();
    if name.is_empty() {
        return Err(ApiError::BadRequest("label name is empty".to_string()));
    }
    let color = clean(body.color);
    let icon = clean(body.icon);
    if !state
        .repo
        .update_label(
            &user_id,
            &id,
            &name,
            color.as_deref(),
            icon.as_deref(),
            body.position,
        )
        .await?
    {
        return Err(ApiError::NotFound);
    }
    let label = find_label(&state, &user_id, &id).await?.ok_or(ApiError::NotFound)?;
    notify_workspace(&state, &label.workspace_id).await;
    Ok(Json(label))
}

pub async fn delete_label(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    // Read the workspace before the row goes away, so its members still get
    // told the label is gone.
    let workspace_id = find_label(&state, &user_id, &id).await?.map(|label| label.workspace_id);
    if !state.repo.delete_label(&user_id, &id).await? {
        return Err(ApiError::NotFound);
    }
    if let Some(workspace_id) = workspace_id {
        notify_workspace(&state, &workspace_id).await;
    }
    Ok(StatusCode::NO_CONTENT)
}

/// One of the caller's visible labels by id. Their whole set is a handful of
/// rows, so this stays a filter over the existing membership-scoped query
/// rather than another repository method.
async fn find_label(state: &AppState, user_id: &str, label_id: &str) -> ApiResult<Option<Label>> {
    Ok(state
        .repo
        .labels_for_user(user_id)
        .await?
        .into_iter()
        .find(|label| label.id == label_id))
}
