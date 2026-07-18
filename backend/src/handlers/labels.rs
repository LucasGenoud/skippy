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
    };
    state.repo.insert_label(&user_id, &label).await?;
    state.notify_user(&user_id);
    Ok((StatusCode::CREATED, Json(label)))
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
    if !state.repo.rename_label(&user_id, &id, &name).await? {
        return Err(ApiError::NotFound);
    }
    state.notify_user(&user_id);
    Ok(Json(Label { id, name }))
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
