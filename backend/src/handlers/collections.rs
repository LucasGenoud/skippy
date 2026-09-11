//! Collection settings and lifecycle inherit workspace membership.
use crate::{
    AppState,
    auth::AuthUser,
    error::{ApiError, ApiResult},
    models::Collection,
};
use axum::{
    Json,
    extract::{Path, State},
    http::StatusCode,
};

pub async fn put_collection(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path((workspace_id, id)): Path<(String, String)>,
    Json(mut body): Json<Collection>,
) -> ApiResult<StatusCode> {
    body.name = body.name.trim().to_string();
    if body.id != id
        || body.workspace_id != workspace_id
        || id.is_empty()
        || id.len() > 128
        || body.name.is_empty()
        || body.name.chars().count() > 60
        || body.name.chars().any(char::is_control)
        || !["masonry", "list", "board"].contains(&body.layout.as_str())
        || !["custom", "edited", "newest", "oldest"].contains(&body.sort.as_str())
        || !body.position.is_finite()
        || body.icon.as_ref().is_some_and(|v| v.len() > 128)
        || body.color.as_ref().is_some_and(|v| v.len() > 32)
    {
        return Err(ApiError::BadRequest("invalid collection settings".into()));
    }
    if !state.repo.put_collection(&user_id, &body).await? {
        return Err(ApiError::NotFound);
    }
    let audience = state.repo.workspace_member_ids(&workspace_id).await?;
    state.hub.notify(&audience, super::CHANGED_MSG);
    Ok(StatusCode::NO_CONTENT)
}

pub async fn delete_collection(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path((workspace_id, id)): Path<(String, String)>,
) -> ApiResult<StatusCode> {
    let ids = state
        .repo
        .delete_collection(&user_id, &workspace_id, &id)
        .await?
        .ok_or(ApiError::NotFound)?;
    for id in ids {
        state.notify_note(&id).await;
        state.index_note_later(&id);
    }
    let audience = state.repo.workspace_member_ids(&workspace_id).await?;
    state.hub.notify(&audience, super::CHANGED_MSG);
    Ok(StatusCode::NO_CONTENT)
}

pub(super) async fn resolve_collection(
    state: &AppState,
    user_id: &str,
    workspace_id: &str,
    id: Option<&str>,
) -> ApiResult<String> {
    state
        .repo
        .collections_for_user(user_id)
        .await?
        .into_iter()
        .find(|c| c.workspace_id == workspace_id && id.is_none_or(|id| c.id == id))
        .map(|c| c.id)
        .ok_or_else(|| {
            ApiError::BadRequest("choose an existing collection in this workspace".into())
        })
}
