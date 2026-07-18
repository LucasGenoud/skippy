//! Attachment upload, deletion, transcription retry, and the signed-URL file
//! server.

use axum::extract::{Multipart, Path, Query, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Deserialize;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::models::*;

use super::{new_id, require_participant};

/// Any file type is accepted and stored; rendering vs download is decided at
/// serve time ([`serve_file`]), never by trusting the upload.
pub async fn upload_attachment(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
    mut multipart: Multipart,
) -> ApiResult<(StatusCode, Json<Attachment>)> {
    let record = require_participant(&state, &id, &user_id).await?;
    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| ApiError::BadRequest(format!("bad multipart body: {e}")))?
    {
        let Some(filename) = field.file_name().map(sanitize_filename) else {
            continue; // skip non-file form fields
        };
        let mime = field
            .content_type()
            .filter(|m| !m.is_empty())
            .unwrap_or("application/octet-stream")
            .to_string();
        let bytes = field
            .bytes()
            .await
            .map_err(|e| ApiError::BadRequest(format!("upload failed: {e}")))?;
        let mut attachment = Attachment {
            id: new_id(),
            mime,
            filename,
            size: bytes.len() as i64,
            url: None,
        };
        state.files.save(&record.owner_id, &attachment.id, &bytes).await?;
        state.repo.insert_attachment(&attachment, &id).await?;
        // An audio clip dropped onto an audio note kicks off transcription:
        // mark pending now (synchronously, so any refetch sees it) and run
        // Whisper in the background. No-op when transcription is disabled.
        if state.transcribe.is_some()
            && record.kind == KIND_AUDIO
            && attachment.mime.starts_with("audio/")
        {
            state.repo.set_transcript(&id, TRANSCRIPT_PENDING, None).await?;
            state.transcribe_later(&id, &record.owner_id, &attachment.id, &attachment.filename, &user_id);
        }
        state.notify_note(&id).await;
        state.sign_attachment(&mut attachment);
        return Ok((StatusCode::CREATED, Json(attachment)));
    }
    Err(ApiError::BadRequest("no file field in upload".to_string()))
}

/// Re-run transcription on an audio note's most recent audio clip. Powers the
/// "Retry" affordance after a failed transcription.
pub async fn transcribe_note(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let record = require_participant(&state, &id, &user_id).await?;
    if state.transcribe.is_none() {
        return Err(ApiError::Unavailable("audio transcription is not enabled on this server"));
    }
    let view = state.repo.note_view(&id, &user_id).await?.ok_or(ApiError::NotFound)?;
    let clip = view
        .attachments
        .into_iter()
        .rev()
        .find(|a| a.mime.starts_with("audio/"))
        .ok_or_else(|| ApiError::BadRequest("note has no audio to transcribe".to_string()))?;
    state.repo.set_transcript(&id, TRANSCRIPT_PENDING, None).await?;
    state.transcribe_later(&id, &record.owner_id, &clip.id, &clip.filename, &user_id);
    state.notify_note(&id).await;
    Ok(StatusCode::ACCEPTED)
}

fn sanitize_filename(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .filter(|c| !c.is_control() && !"\\/\"<>|:*?".contains(*c))
        .collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() { "file".to_string() } else { trimmed.chars().take(120).collect() }
}

pub async fn delete_attachment(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let (note_id, _info) =
        state.repo.attachment_info(&id).await?.ok_or(ApiError::NotFound)?;
    let record = require_participant(&state, &note_id, &user_id).await?;
    state.repo.delete_attachment(&id).await?;
    state.files.delete(&record.owner_id, &id).await;
    state.notify_note(&note_id).await;
    Ok(StatusCode::NO_CONTENT)
}

/// Query carrying the signed, time-limited capability minted in note views.
#[derive(Deserialize)]
pub struct FileAccess {
    exp: Option<i64>,
    sig: Option<String>,
}

/// Serves attachment bytes, gated by a signed `?exp=..&sig=..` capability
/// rather than a bearer token — so plain `<img>`/`<audio>` element loads work
/// on web and mobile, while a stranger with just the id gets nothing. Only a
/// note's participants are ever handed a signed URL (they are minted into
/// access-checked note views), and the signature expires, so a leaked URL
/// stops working. See [`crate::files::signed_file_path`].
///
/// Only images render inline; everything else is forced to download with its
/// original filename, so a user-uploaded HTML file can never execute in the
/// app's origin.
pub async fn serve_file(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(access): Query<FileAccess>,
) -> ApiResult<Response> {
    let (Some(exp), Some(sig)) = (access.exp, access.sig) else {
        return Err(ApiError::Unauthorized);
    };
    if !crate::files::verify_file_access(&state.file_secret, &id, exp, &sig) {
        return Err(ApiError::Unauthorized);
    }
    let (note_id, attachment) =
        state.repo.attachment_info(&id).await?.ok_or(ApiError::NotFound)?;
    // The blob lives under the note owner's identity (its S3 bucket); the
    // signature already proved access, this lookup just locates the bytes.
    let owner_id = state
        .repo
        .note_record(&note_id)
        .await?
        .map(|record| record.owner_id)
        .ok_or(ApiError::NotFound)?;
    let bytes = state.files.read(&owner_id, &id).await.ok_or(ApiError::NotFound)?;
    let inline = attachment.mime.starts_with("image/");
    let disposition = if inline {
        "inline".to_string()
    } else {
        format!("attachment; filename=\"{}\"", attachment.filename.replace('"', ""))
    };
    Ok((
        [
            (header::CONTENT_TYPE, attachment.mime),
            (header::CONTENT_DISPOSITION, disposition),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff".to_string()),
            // The URL is a per-user, expiring capability — never let a shared
            // cache store it. `private` scopes caching to the user's own browser.
            (header::CACHE_CONTROL, "private, max-age=3600".to_string()),
        ],
        bytes,
    )
        .into_response())
}
