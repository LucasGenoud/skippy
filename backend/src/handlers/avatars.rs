//! Profile pictures. The app shrinks a picture to a small square before it
//! uploads it, so it is stored as bytes in SQLite rather than behind
//! `FileStore`, and user payloads carry only its version.

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};

/// Largest picture accepted. The app sends a 160 px square, well under it.
const MAX_AVATAR_BYTES: usize = 256 * 1024;

/// The image types accepted.
const AVATAR_TYPES: &[&str] = &["image/png", "image/jpeg", "image/webp"];

/// A picture's URL carries its version, so a copy never goes stale.
const AVATAR_CACHE_CONTROL: &str = "private, max-age=31536000, immutable";

pub async fn put_avatar(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    headers: HeaderMap,
    body: Bytes,
) -> ApiResult<StatusCode> {
    if body.len() > MAX_AVATAR_BYTES {
        return Err(ApiError::BadRequest("picture is too large".to_string()));
    }

    let mime = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    let Some(mime) = AVATAR_TYPES.iter().find(|m| **m == mime) else {
        return Err(ApiError::BadRequest(
            "picture must be PNG, JPEG or WebP".to_string(),
        ));
    };
    if !is_image_of(mime, &body) {
        return Err(ApiError::BadRequest(format!("picture is not {mime}")));
    }

    state.repo.set_avatar(&user_id, mime, &body).await?;
    notify_people_shown(&state, &user_id).await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn delete_avatar(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
) -> ApiResult<StatusCode> {
    if state.repo.delete_avatar(&user_id).await? {
        notify_people_shown(&state, &user_id).await?;
    }
    Ok(StatusCode::NO_CONTENT)
}

pub async fn get_avatar(
    State(state): State<AppState>,
    AuthUser(viewer): AuthUser,
    Path(user_id): Path<String>,
) -> ApiResult<Response> {
    let avatar = state
        .repo
        .avatar_for(&viewer, &user_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    let mime = HeaderValue::from_str(&avatar.mime).map_err(anyhow::Error::from)?;
    Ok((
        [
            (header::CONTENT_TYPE, mime),
            (
                header::CACHE_CONTROL,
                HeaderValue::from_static(AVATAR_CACHE_CONTROL),
            ),
        ],
        avatar.bytes,
    )
        .into_response())
}

/// Whether `bytes` start the way a file of type `mime` does.
fn is_image_of(mime: &str, bytes: &[u8]) -> bool {
    match mime {
        "image/png" => bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
        "image/jpeg" => bytes.starts_with(b"\xff\xd8\xff"),
        // RIFF, a four-byte length, then WEBP.
        "image/webp" => bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP"),
        _ => false,
    }
}

/// The user's own devices and everyone in their workspaces, who see the
/// picture on rosters and notes.
async fn notify_people_shown(state: &AppState, user_id: &str) -> ApiResult<()> {
    state.notify_user(user_id);
    for workspace in state.repo.workspaces_for_user(user_id).await? {
        if !workspace.members.is_empty() {
            state.notify_workspace(&workspace.id).await;
        }
    }
    Ok(())
}
