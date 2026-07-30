//! Collaborator management, plus the per-note checklist suggestion history.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::models::*;

use super::{CHANGED_MSG, require_participant};

pub async fn add_collaborator(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
    Json(body): Json<AddCollaborator>,
) -> ApiResult<Json<NoteView>> {
    let record = require_participant(&state, &id, &user_id).await?;
    if record.owner_id != user_id {
        return Err(ApiError::Forbidden("only the owner can share a note"));
    }
    let target = state
        .repo
        .user_by_email(body.email.trim())
        .await?
        .ok_or_else(|| ApiError::BadRequest(format!("no account for '{}'", body.email.trim())))?;
    if target.id == user_id {
        return Err(ApiError::Conflict(
            "that's you, the owner already has access".to_string(),
        ));
    }
    state.repo.add_collaborator(&id, &target.id).await?;
    state.index_note_later(&id); // participants changed -> access filter changed
    state.notify_note(&id).await;
    let mut view = state
        .repo
        .note_view(&id, &user_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    state.sign_view(&mut view);
    Ok(Json(view))
}

pub async fn remove_collaborator(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path((id, target_id)): Path<(String, String)>,
) -> ApiResult<StatusCode> {
    let record = require_participant(&state, &id, &user_id).await?;
    // Owners can remove anyone; collaborators can only remove themselves.
    if record.owner_id != user_id && target_id != user_id {
        return Err(ApiError::Forbidden(
            "collaborators can only remove themselves",
        ));
    }
    // Notify before removal so the removed user's client refreshes too.
    let participants = state.repo.participant_ids(&id).await?;
    if !state.repo.remove_collaborator(&id, &target_id).await? {
        return Err(ApiError::NotFound);
    }
    state.index_note_later(&id); // participants changed -> access filter changed
    state.hub.notify(&participants, CHANGED_MSG);
    Ok(StatusCode::NO_CONTENT)
}

/// The user's personal checked-item dictionary, most used first.
pub async fn checklist_history(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
) -> ApiResult<Json<Vec<HistoryEntry>>> {
    Ok(Json(state.repo.checklist_history(&user_id).await?))
}
