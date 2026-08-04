//! Attachment upload, deletion, transcription retry, and the signed-URL file
//! server.

use axum::Json;
use axum::extract::{Multipart, Path, Query, State};
use axum::http::{HeaderMap, HeaderName, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde::Deserialize;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::models::*;
use crate::store::CleanupKind;

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
        state.files.save(&attachment.id, &bytes).await?;
        if let Err(error) = state.repo.insert_attachment(&attachment, &id).await {
            // The blob exists but no relational row points at it. Persist the
            // cleanup intent before surfacing the database error.
            if let Err(queue_error) = state
                .repo
                .enqueue_cleanup(CleanupKind::AttachmentBlob, &attachment.id)
                .await
            {
                state.report_background_failure(
                    "attachment_cleanup_enqueue",
                    &format!("{queue_error:?}"),
                );
                // If SQLite itself is unavailable, still make the best
                // idempotent attempt to avoid stranding the just-written blob.
                if let Err(delete_error) = state.files.delete(&attachment.id).await {
                    state.report_background_failure("attachment_cleanup_fallback", &delete_error);
                }
                return Err(error.into());
            }
            state.drain_cleanup_jobs().await;
            return Err(error.into());
        }
        // An audio clip dropped onto an audio note kicks off transcription:
        // mark pending now (synchronously, so any refetch sees it) and run
        // Whisper in the background. No-op when transcription is disabled.
        if state.transcribe.is_some()
            && record.kind == KIND_AUDIO
            && attachment.mime.starts_with("audio/")
        {
            state
                .repo
                .set_transcript(&id, TRANSCRIPT_PENDING, None)
                .await?;
            state.transcribe_later(&id, &attachment.id, &attachment.filename, &user_id);
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
    require_participant(&state, &id, &user_id).await?;
    if state.transcribe.is_none() {
        return Err(ApiError::Unavailable(
            "audio transcription is not enabled on this server",
        ));
    }
    let view = state
        .repo
        .note_view(&id, &user_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    let clip = view
        .attachments
        .into_iter()
        .rev()
        .find(|a| a.mime.starts_with("audio/"))
        .ok_or_else(|| ApiError::BadRequest("note has no audio to transcribe".to_string()))?;
    state
        .repo
        .set_transcript(&id, TRANSCRIPT_PENDING, None)
        .await?;
    state.transcribe_later(&id, &clip.id, &clip.filename, &user_id);
    state.notify_note(&id).await;
    Ok(StatusCode::ACCEPTED)
}

fn sanitize_filename(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .filter(|c| !c.is_control() && !"\\/\"<>|:*?".contains(*c))
        .collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        "file".to_string()
    } else {
        trimmed.chars().take(120).collect()
    }
}

pub async fn delete_attachment(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let (note_id, _info) = state
        .repo
        .attachment_info(&id)
        .await?
        .ok_or(ApiError::NotFound)?;
    require_participant(&state, &note_id, &user_id).await?;
    state.repo.delete_attachment(&id).await?;
    state.drain_cleanup_jobs().await;
    state.notify_note(&note_id).await;
    Ok(StatusCode::NO_CONTENT)
}

/// Query carrying the signed, time-limited capability minted in note views.
#[derive(Deserialize)]
pub struct FileAccess {
    exp: Option<i64>,
    sig: Option<String>,
}

/// MIME types that browsers may render directly without interpreting active
/// document content. Keep this list explicit: broad families such as
/// `image/*` include SVG, which can contain scripts and external references.
const SAFE_INLINE_MIME_TYPES: &[&str] = &[
    "image/avif",
    "image/bmp",
    "image/gif",
    "image/jpeg",
    "image/png",
    "image/webp",
    "image/vnd.microsoft.icon",
    "image/x-icon",
    "audio/aac",
    "audio/flac",
    "audio/mp4",
    "audio/mpeg",
    "audio/ogg",
    "audio/wav",
    "audio/webm",
    "audio/x-m4a",
    "audio/x-wav",
    "video/mp4",
    "video/mpeg",
    "video/ogg",
    "video/quicktime",
    "video/webm",
    "video/x-m4v",
];

fn is_safe_inline_mime(mime: &str) -> bool {
    let essence = mime.split(';').next().unwrap_or_default().trim();
    SAFE_INLINE_MIME_TYPES
        .iter()
        .any(|candidate| essence.eq_ignore_ascii_case(candidate))
}

/// Serves attachment bytes, gated by a signed `?exp=..&sig=..` capability
/// rather than a bearer token, so plain `<img>`/`<audio>` element loads work
/// on web and mobile, while a stranger with just the id gets nothing. Only a
/// note's participants are ever handed a signed URL (they are minted into
/// access-checked note views), and the signature expires, so a leaked URL
/// stops working. See [`crate::files::signed_file_path`].
///
/// Explicitly allowlisted passive image, audio, and video formats render
/// inline; every other type is forced to download with its original filename.
/// This keeps active formats such as HTML and SVG from executing in the app's
/// origin. Byte-range requests are honored (`206`) so mobile media players can
/// stream and seek.
pub async fn serve_file(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(access): Query<FileAccess>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    let (Some(exp), Some(sig)) = (access.exp, access.sig) else {
        return Err(ApiError::Unauthorized);
    };
    if !crate::files::verify_file_access(&state.file_secret, &id, exp, &sig) {
        return Err(ApiError::Unauthorized);
    }
    let (note_id, attachment) = state
        .repo
        .attachment_info(&id)
        .await?
        .ok_or(ApiError::NotFound)?;
    // The signature proved access; the relational lookup above proved the
    // attachment still belongs to a live note and supplied its metadata.
    let _ = note_id;
    let bytes = state.files.read(&id).await.ok_or(ApiError::NotFound)?;
    // Only passive media types render inline. In particular, SVG is an active
    // document format despite its `image/*` MIME type and must be downloaded.
    let inline = is_safe_inline_mime(&attachment.mime);
    let disposition = if inline {
        "inline".to_string()
    } else {
        format!(
            "attachment; filename=\"{}\"",
            attachment.filename.replace('"', "")
        )
    };
    let total = bytes.len() as u64;
    // Common headers on every response. `Accept-Ranges` advertises range
    // support so iOS AVPlayer (via `just_audio`) will stream and seek m4a/mp4
    // audio, without it, remote audio playback silently fails on mobile.
    let mut resp_headers = HeaderMap::new();
    if let Ok(value) = attachment.mime.parse() {
        resp_headers.insert(header::CONTENT_TYPE, value);
    }
    if let Ok(value) = disposition.parse() {
        resp_headers.insert(header::CONTENT_DISPOSITION, value);
    }
    resp_headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        header::HeaderValue::from_static("nosniff"),
    );
    resp_headers.insert(
        header::ACCEPT_RANGES,
        header::HeaderValue::from_static("bytes"),
    );
    // These policies are defense in depth for a file opened as a top-level
    // document. They also constrain legacy records whose declared MIME type
    // may be inaccurate.
    resp_headers.insert(
        HeaderName::from_static("content-security-policy"),
        header::HeaderValue::from_static(
            "sandbox; default-src 'none'; base-uri 'none'; form-action 'none'",
        ),
    );
    resp_headers.insert(
        HeaderName::from_static("referrer-policy"),
        header::HeaderValue::from_static("no-referrer"),
    );
    // The URL is a per-user, expiring capability, never let a shared cache
    // store it. `private` scopes caching to the user's own browser.
    resp_headers.insert(
        header::CACHE_CONTROL,
        header::HeaderValue::from_static("private, max-age=3600"),
    );

    // Honor a single-range request with `206 Partial Content`; anything we
    // can't parse falls through to serving the whole body.
    if let Some(range) = headers.get(header::RANGE).and_then(parse_single_range) {
        if let Some((start, end)) = resolve_range(range, total) {
            let slice = bytes[start as usize..=end as usize].to_vec();
            if let Ok(value) = format!("bytes {start}-{end}/{total}").parse() {
                resp_headers.insert(header::CONTENT_RANGE, value);
            }
            return Ok((StatusCode::PARTIAL_CONTENT, resp_headers, slice).into_response());
        }
        // Unsatisfiable range → 416 with the current size.
        if let Ok(value) = format!("bytes */{total}").parse() {
            resp_headers.insert(header::CONTENT_RANGE, value);
        }
        return Ok((StatusCode::RANGE_NOT_SATISFIABLE, resp_headers).into_response());
    }

    Ok((resp_headers, bytes).into_response())
}

/// A parsed single byte-range request; either bound may be open.
enum ByteRange {
    /// `bytes=start-` or `bytes=start-end`.
    From { start: u64, end: Option<u64> },
    /// `bytes=-suffix`, the last `suffix` bytes.
    Suffix(u64),
}

/// Parses a `Range` header value, accepting only a single `bytes=` range (all
/// any audio/video player issues). Multi-range and non-`bytes` units return
/// `None`, so the caller serves the whole body.
fn parse_single_range(value: &axum::http::HeaderValue) -> Option<ByteRange> {
    let spec = value.to_str().ok()?.strip_prefix("bytes=")?.trim();
    if spec.contains(',') {
        return None;
    }
    let (start, end) = spec.split_once('-')?;
    if start.is_empty() {
        return Some(ByteRange::Suffix(end.parse().ok()?));
    }
    let start = start.parse().ok()?;
    let end = if end.is_empty() {
        None
    } else {
        Some(end.parse().ok()?)
    };
    Some(ByteRange::From { start, end })
}

/// Resolves a parsed range against the total size to an inclusive `(start, end)`
/// byte pair, or `None` when it can't be satisfied (e.g. start past the end).
fn resolve_range(range: ByteRange, total: u64) -> Option<(u64, u64)> {
    if total == 0 {
        return None;
    }
    let (start, end) = match range {
        ByteRange::From { start, end } => (start, end.unwrap_or(total - 1).min(total - 1)),
        ByteRange::Suffix(len) => {
            if len == 0 {
                return None;
            }
            (total.saturating_sub(len), total - 1)
        }
    };
    if start > end || start >= total {
        return None;
    }
    Some((start, end))
}
