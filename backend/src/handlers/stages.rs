//! Board-column CRUD. Stages belong to a workspace and are shared by everyone
//! in it, so any member may create, rename, restyle, reorder, or remove them.
//! Filing a note in a stage happens through the note-update endpoint
//! (`stage_id` on the patch body), not here.
//!
//! Stages are intentionally a separate system from labels: a note carries any
//! number of labels and at most one stage. Nothing in this module reads or
//! writes labels, and nothing in `labels.rs` reads or writes stages. The two
//! read alike on purpose — keeping them as two obvious modules is cheaper than
//! one shared abstraction that both have to be reasoned about through.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::models::*;

use super::{new_id, resolve_workspace};

pub async fn list_stages(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
) -> ApiResult<Json<Vec<Stage>>> {
    Ok(Json(state.repo.stages_for_user(&user_id).await?))
}

pub async fn create_stage(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Json(body): Json<StagePayload>,
) -> ApiResult<(StatusCode, Json<Stage>)> {
    let name = body.name.trim().to_string();
    if name.is_empty() {
        return Err(ApiError::BadRequest("stage name is empty".to_string()));
    }
    let workspace_id = resolve_workspace(&state, &user_id, body.workspace_id.as_deref()).await?;
    // A new column goes to the right of the board unless the caller places it.
    let position = match body.position {
        Some(p) => p,
        None => state.repo.max_stage_position(&workspace_id).await? + 1024.0,
    };
    let stage = Stage {
        id: body.id.filter(|id| !id.trim().is_empty()).unwrap_or_else(new_id),
        workspace_id,
        name,
        color: clean(body.color),
        position,
    };
    state.repo.insert_stage(&stage).await?;
    notify_workspace(&state, &stage.workspace_id).await;
    Ok((StatusCode::CREATED, Json(stage)))
}

/// A stage is workspace state: everyone in the workspace needs the change.
async fn notify_workspace(state: &AppState, workspace_id: &str) {
    if let Ok(ids) = state.repo.workspace_member_ids(workspace_id).await {
        state.hub.notify(&ids, super::CHANGED_MSG);
    }
}

/// Trim a presentation field; empty becomes `None` so the client's "clear"
/// (an empty string) resets the stage to the theme default.
fn clean(v: Option<String>) -> Option<String> {
    v.map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

pub async fn update_stage(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
    Json(body): Json<StagePayload>,
) -> ApiResult<Json<Stage>> {
    let name = body.name.trim().to_string();
    if name.is_empty() {
        return Err(ApiError::BadRequest("stage name is empty".to_string()));
    }
    let color = clean(body.color);
    if !state
        .repo
        .update_stage(&user_id, &id, &name, color.as_deref(), body.position)
        .await?
    {
        return Err(ApiError::NotFound);
    }
    let stage = find_stage(&state, &user_id, &id).await?.ok_or(ApiError::NotFound)?;
    notify_workspace(&state, &stage.workspace_id).await;
    Ok(Json(stage))
}

pub async fn delete_stage(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    // Read the workspace before the row goes away, so its members still get
    // told the column is gone.
    let workspace_id = find_stage(&state, &user_id, &id).await?.map(|s| s.workspace_id);
    // The repository sends the stage's notes back to unassigned in the same
    // transaction — deleting a column never deletes notes.
    if !state.repo.delete_stage(&user_id, &id).await? {
        return Err(ApiError::NotFound);
    }
    if let Some(workspace_id) = workspace_id {
        notify_workspace(&state, &workspace_id).await;
    }
    Ok(StatusCode::NO_CONTENT)
}

/// One of the caller's visible stages by id. A board is a handful of columns,
/// so this stays a filter over the existing membership-scoped query rather
/// than another repository method.
async fn find_stage(state: &AppState, user_id: &str, stage_id: &str) -> ApiResult<Option<Stage>> {
    Ok(state
        .repo
        .stages_for_user(user_id)
        .await?
        .into_iter()
        .find(|stage| stage.id == stage_id))
}
