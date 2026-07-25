//! Workspaces: the containers notes and labels live in. Every account starts
//! with one default workspace and may create more; membership is per
//! workspace, and a member sees every note it holds.
//!
//! Only the owner may rename, delete, or change the roster. Members can edit
//! the workspace's notes and labels, and can leave it.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::models::*;

use super::{CHANGED_MSG, new_id, now};

fn validate_name(name: &str) -> ApiResult<String> {
    let name = name.trim();
    let ok = (1..=60).contains(&name.chars().count()) && !name.chars().any(char::is_control);
    if !ok {
        return Err(ApiError::BadRequest(
            "workspace name must be 1-60 characters".to_string(),
        ));
    }
    Ok(name.to_string())
}

/// Load a workspace the caller belongs to. Non-members get 404 rather than
/// 403, so workspace ids leak nothing — the same rule notes follow.
async fn require_member(
    state: &AppState,
    workspace_id: &str,
    user_id: &str,
) -> ApiResult<Workspace> {
    let workspace = state
        .repo
        .workspace(workspace_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    if !state
        .repo
        .is_workspace_member(workspace_id, user_id)
        .await?
    {
        return Err(ApiError::NotFound);
    }
    Ok(workspace)
}

async fn require_owner(
    state: &AppState,
    workspace_id: &str,
    user_id: &str,
    action: &'static str,
) -> ApiResult<Workspace> {
    let workspace = require_member(state, workspace_id, user_id).await?;
    if workspace.owner_id != user_id {
        return Err(ApiError::Forbidden(action));
    }
    Ok(workspace)
}

/// Serve one workspace as the caller sees it, straight after a change.
async fn view_of(state: &AppState, workspace_id: &str, user_id: &str) -> ApiResult<WorkspaceView> {
    state
        .repo
        .workspaces_for_user(user_id)
        .await?
        .into_iter()
        .find(|w| w.id == workspace_id)
        .ok_or(ApiError::NotFound)
}

/// Push a change event to everyone in the workspace.
async fn notify_workspace(state: &AppState, workspace_id: &str) {
    if let Ok(ids) = state.repo.workspace_member_ids(workspace_id).await {
        state.hub.notify(&ids, CHANGED_MSG);
    }
}

pub async fn list_workspaces(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
) -> ApiResult<Json<Vec<WorkspaceView>>> {
    Ok(Json(ensure_workspaces(&state, &user_id).await?))
}

/// The caller's workspaces, creating the default one if the account somehow
/// has none — a registration that failed between the user row and its
/// workspace. A user without a workspace has nowhere to put notes, and
/// [`super::resolve_workspace`] depends on there always being one.
pub async fn ensure_workspaces(state: &AppState, user_id: &str) -> ApiResult<Vec<WorkspaceView>> {
    let workspaces = state.repo.workspaces_for_user(user_id).await?;
    if !workspaces.is_empty() {
        return Ok(workspaces);
    }
    create_default_workspace(state, user_id).await?;
    Ok(state.repo.workspaces_for_user(user_id).await?)
}

/// The workspace an account starts with. Created during registration, and
/// re-created by [`ensure_workspaces`] if an account ever ends up without one.
pub async fn create_default_workspace(state: &AppState, user_id: &str) -> ApiResult<Workspace> {
    let workspace = Workspace {
        id: new_id(),
        owner_id: user_id.to_string(),
        name: DEFAULT_WORKSPACE_NAME.to_string(),
        is_default: true,
        created_at: now(),
    };
    state.repo.insert_workspace(&workspace).await?;
    Ok(workspace)
}

pub async fn create_workspace(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Json(body): Json<CreateWorkspace>,
) -> ApiResult<(StatusCode, Json<WorkspaceView>)> {
    let name = validate_name(&body.name)?;
    let workspace = Workspace {
        id: match body.id {
            Some(id) if !id.trim().is_empty() => id,
            _ => new_id(),
        },
        owner_id: user_id.clone(),
        name,
        // Only the workspace created with the account is the default one.
        is_default: false,
        created_at: now(),
    };
    state.repo.insert_workspace(&workspace).await?;
    state.notify_user(&user_id);
    let view = view_of(&state, &workspace.id, &user_id).await?;
    Ok((StatusCode::CREATED, Json(view)))
}

pub async fn rename_workspace(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
    Json(body): Json<RenameWorkspace>,
) -> ApiResult<Json<WorkspaceView>> {
    require_owner(
        &state,
        &id,
        &user_id,
        "only the owner can rename a workspace",
    )
    .await?;
    let name = validate_name(&body.name)?;
    if !state.repo.rename_workspace(&id, &name).await? {
        return Err(ApiError::NotFound);
    }
    notify_workspace(&state, &id).await;
    Ok(Json(view_of(&state, &id, &user_id).await?))
}

pub async fn delete_workspace(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let workspace = require_owner(
        &state,
        &id,
        &user_id,
        "only the owner can delete a workspace",
    )
    .await?;
    if workspace.is_default {
        return Err(ApiError::Forbidden(
            "your default workspace cannot be deleted",
        ));
    }
    // Notify before the roster disappears, so every member's client refreshes.
    let members = state.repo.workspace_member_ids(&id).await?;
    // Notes are rehomed rather than destroyed, but their labels and their
    // visibility both change, so the search index has to be rebuilt for them.
    let moved: Vec<String> = state
        .repo
        .notes_for_user(&user_id)
        .await?
        .into_iter()
        .filter(|view| view.note.workspace_id == id)
        .map(|view| view.note.id)
        .collect();
    if !state.repo.delete_workspace(&id).await? {
        return Err(ApiError::NotFound);
    }
    for note_id in &moved {
        state.index_note_later(note_id);
    }
    state.hub.notify(&members, CHANGED_MSG);
    Ok(StatusCode::NO_CONTENT)
}

pub async fn add_workspace_member(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
    Json(body): Json<AddMember>,
) -> ApiResult<Json<WorkspaceView>> {
    require_owner(&state, &id, &user_id, "only the owner can invite members").await?;
    let target = state
        .repo
        .user_by_email(body.email.trim())
        .await?
        .ok_or_else(|| ApiError::BadRequest(format!("no account for '{}'", body.email.trim())))?;
    if target.id == user_id {
        return Err(ApiError::Conflict(
            "that's you — the owner already has access".to_string(),
        ));
    }
    state.repo.add_workspace_member(&id, &target.id).await?;
    // The new member can now see every note in the workspace, so each one's
    // access filter in the vector index has to be rewritten.
    reindex_workspace_notes(&state, &id, &user_id).await?;
    notify_workspace(&state, &id).await;
    Ok(Json(view_of(&state, &id, &user_id).await?))
}

pub async fn remove_workspace_member(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path((id, target_id)): Path<(String, String)>,
) -> ApiResult<StatusCode> {
    let workspace = require_member(&state, &id, &user_id).await?;
    // Owners can remove anyone; members can only remove themselves (leave).
    if workspace.owner_id != user_id && target_id != user_id {
        return Err(ApiError::Forbidden("members can only remove themselves"));
    }
    if target_id == workspace.owner_id {
        return Err(ApiError::Forbidden(
            "the owner cannot leave their own workspace",
        ));
    }
    // Notify before removal so the departing member's client refreshes too.
    let members = state.repo.workspace_member_ids(&id).await?;
    // Their own notes follow them out to their default workspace; notes owned
    // by others stay behind.
    let moved = state.repo.rehome_own_notes(&id, &target_id).await?;
    if !state.repo.remove_workspace_member(&id, &target_id).await? {
        return Err(ApiError::NotFound);
    }
    reindex_workspace_notes(&state, &id, &user_id).await?;
    for note_id in &moved {
        state.index_note_later(note_id);
    }
    state.hub.notify(&members, CHANGED_MSG);
    Ok(StatusCode::NO_CONTENT)
}

/// Re-embed every note in a workspace whose roster just changed: the vector
/// index stores one row per participant, so visibility only follows membership
/// once the notes are rewritten.
async fn reindex_workspace_notes(
    state: &AppState,
    workspace_id: &str,
    viewer_id: &str,
) -> ApiResult<()> {
    if state.search.is_none() {
        return Ok(());
    }
    for view in state.repo.notes_for_user(viewer_id).await? {
        if view.note.workspace_id == workspace_id {
            state.index_note_later(&view.note.id);
        }
    }
    Ok(())
}
