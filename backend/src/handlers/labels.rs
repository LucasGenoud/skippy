//! Label CRUD. Assigning labels to notes happens through the note-update
//! endpoint (`label_ids` on the patch body), not here.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::models::*;

use super::new_id;

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
    let label = Label {
        id: body.id.filter(|id| !id.trim().is_empty()).unwrap_or_else(new_id),
        name,
        color: clean(body.color),
        icon: clean(body.icon),
    };
    state.repo.insert_label(&user_id, &label).await?;
    state.notify_user(&user_id);
    Ok((StatusCode::CREATED, Json(label)))
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
        .update_label(&user_id, &id, &name, color.as_deref(), icon.as_deref())
        .await?
    {
        return Err(ApiError::NotFound);
    }
    state.notify_user(&user_id);
    Ok(Json(Label { id, name, color, icon }))
}

pub async fn delete_label(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    if !state.repo.delete_label(&user_id, &id).await? {
        return Err(ApiError::NotFound);
    }
    state.notify_user(&user_id);
    Ok(StatusCode::NO_CONTENT)
}
