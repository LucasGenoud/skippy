//! Note CRUD, reordering, and trash purging. The create/update pipelines are
//! exposed as plain-argument helpers ([`create_note_for_user`],
//! [`apply_note_update`]) so the chat write path runs the exact same
//! indexing + labeling + history + notify flow as the HTTP handlers.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use chrono::Utc;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::models::*;

use super::versions::{VERSION_SESSION_GAP_SECS, seconds_since, version_of};
use super::{CHANGED_MSG, new_id, now, require_participant};

const TRASH_RETENTION_DAYS: i64 = 7;

pub(super) fn validate_kind(kind: &str) -> ApiResult<()> {
    if kind == KIND_TEXT || kind == KIND_CHECKLIST || kind == KIND_MARKDOWN || kind == KIND_AUDIO {
        Ok(())
    } else {
        Err(ApiError::BadRequest(format!("unknown note kind '{kind}'")))
    }
}

fn validate_reminder(value: &Option<String>) -> ApiResult<()> {
    if let Some(v) = value {
        chrono::DateTime::parse_from_rfc3339(v)
            .map_err(|_| ApiError::BadRequest("reminder_at must be RFC3339".to_string()))?;
    }
    Ok(())
}

fn validate_update(record: &NoteRecord, user_id: &str, body: &UpdateNote) -> ApiResult<()> {
    if body.trashed.is_some() && record.owner_id != user_id {
        return Err(ApiError::Forbidden(
            "only the owner can trash or restore a note",
        ));
    }
    if let Some(kind) = &body.kind {
        validate_kind(kind)?;
    }
    if let Some(reminder) = &body.reminder_at {
        validate_reminder(reminder)?;
    }
    Ok(())
}

fn changes_content(body: &UpdateNote, record: &NoteRecord) -> bool {
    body.kind.as_ref().is_some_and(|v| *v != record.kind)
        || body.title.as_ref().is_some_and(|v| *v != record.title)
        || body.content.as_ref().is_some_and(|v| *v != record.content)
        || body.items.as_ref().is_some_and(|v| *v != record.items)
}

fn reset_delivered_reminder_if_rescheduled(body: &UpdateNote, record: &mut NoteRecord) {
    if body
        .reminder_at
        .as_ref()
        .is_some_and(|reminder| *reminder != record.reminder_at)
    {
        // A rescheduled reminder is a new alarm and must be delivered again.
        record.reminder_fired_at = None;
    }
}

fn starts_new_edit_session(record: &NoteRecord, user_id: &str) -> bool {
    record.last_editor_id.as_deref() != Some(user_id)
        || seconds_since(&record.updated_at) >= VERSION_SESSION_GAP_SECS
}

fn newly_checked_texts(before: &[ChecklistItem], after: &[ChecklistItem]) -> Vec<String> {
    after
        .iter()
        .filter(|item| item.done && !before.iter().any(|old| old.id == item.id && old.done))
        .map(|item| item.text.clone())
        .collect()
}

pub async fn list_notes(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
) -> ApiResult<Json<Vec<NoteView>>> {
    purge_old_trash(&state).await?;
    let mut views = state.repo.notes_for_user(&user_id).await?;
    state.sign_views(&mut views);
    Ok(Json(views))
}

pub async fn purge_old_trash(state: &AppState) -> ApiResult<()> {
    let cutoff = (Utc::now() - chrono::Duration::days(TRASH_RETENTION_DAYS)).to_rfc3339();
    purge_trash(state, &cutoff).await
}

/// Hard-delete trashed notes older than `cutoff`, cleaning up the state that
/// lives outside their rows: attachment blobs and search-index entries.
/// Public with an explicit cutoff so tests can purge without waiting out the
/// retention window.
pub async fn purge_trash(state: &AppState, cutoff: &str) -> ApiResult<()> {
    for note in state.repo.purge_trash_before(cutoff).await? {
        for attachment_id in &note.attachment_ids {
            state.files.delete(&note.owner_id, attachment_id).await;
        }
        state.unindex_note_later(&note.note_id);
    }
    Ok(())
}

pub async fn create_note(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Json(body): Json<CreateNote>,
) -> ApiResult<(StatusCode, Json<NoteView>)> {
    let view = create_note_for_user(&state, &user_id, body).await?;
    Ok((StatusCode::CREATED, Json(view)))
}

/// Create a note for `user_id` and return its signed view. Shared by the HTTP
/// handler and the chat write path so both run the same insert + indexing +
/// auto-labeling + notify pipeline.
pub async fn create_note_for_user(
    state: &AppState,
    user_id: &str,
    body: CreateNote,
) -> ApiResult<NoteView> {
    let kind = body.kind.unwrap_or_else(|| KIND_TEXT.to_string());
    validate_kind(&kind)?;
    validate_reminder(&body.reminder_at)?;
    let restored_created = validate_restore_timestamp(body.created_at.as_deref())?;
    let restored_updated = validate_restore_timestamp(body.updated_at.as_deref())?;
    let id = match body.id {
        Some(id) if !id.trim().is_empty() => id,
        _ => new_id(),
    };
    let position = match body.position {
        Some(p) => p,
        // New notes go to the front of the grid.
        None => state.repo.min_position_for_user(user_id).await? - 1024.0,
    };
    let ts = now();
    let created_at = restored_created.unwrap_or_else(|| ts.clone());
    let updated_at = restored_updated.unwrap_or_else(|| ts.clone());
    let record = NoteRecord {
        id: id.clone(),
        owner_id: user_id.to_string(),
        kind,
        title: body.title,
        content: body.content,
        items: body.items.unwrap_or_default(),
        color: body.color.unwrap_or_else(|| "default".to_string()),
        pinned: body.pinned.unwrap_or(false),
        archived: body.archived.unwrap_or(false),
        trashed: false,
        position,
        reminder_at: body.reminder_at,
        reminder_fired_at: None,
        transcript_status: TRANSCRIPT_NONE.to_string(),
        created_at,
        updated_at,
        // Set on the first edit; until then there's nothing to attribute.
        last_editor_id: None,
    };
    state.repo.insert_note(&record).await?;
    if let Some(label_ids) = body.label_ids
        && let Err(error) = state
            .repo
            .set_note_labels(&record.id, user_id, &label_ids)
            .await
    {
        let _ = state.repo.delete_note(&record.id).await;
        return Err(error.into());
    }
    let pre_checked: Vec<String> = record
        .items
        .iter()
        .filter(|i| i.done)
        .map(|i| i.text.clone())
        .collect();
    if !pre_checked.is_empty() {
        state
            .repo
            .record_checked_items(&record.id, &pre_checked)
            .await?;
    }
    state.index_note_later(&id);
    state.label_note_later(&id, user_id);
    state.notify_user(user_id);
    let mut view = state
        .repo
        .note_view(&id, user_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    state.sign_view(&mut view);
    Ok(view)
}

fn validate_restore_timestamp(value: Option<&str>) -> ApiResult<Option<String>> {
    let Some(value) = value else {
        return Ok(None);
    };
    chrono::DateTime::parse_from_rfc3339(value)
        .map_err(|_| ApiError::BadRequest("invalid backup timestamp".to_string()))?;
    Ok(Some(value.to_string()))
}

pub async fn get_note(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
) -> ApiResult<Json<NoteView>> {
    require_participant(&state, &id, &user_id).await?;
    let mut view = state
        .repo
        .note_view(&id, &user_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    state.sign_view(&mut view);
    Ok(Json(view))
}

pub async fn update_note(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
    Json(body): Json<UpdateNote>,
) -> ApiResult<Json<NoteView>> {
    Ok(Json(apply_note_update(&state, &user_id, &id, body).await?))
}

/// Apply a patch to a note as `user_id` and return its signed view. Shared by
/// the HTTP handler and the chat append path, so both run the same version
/// capture + checklist-history + indexing + labeling + notify pipeline.
pub async fn apply_note_update(
    state: &AppState,
    user_id: &str,
    id: &str,
    mut body: UpdateNote,
) -> ApiResult<NoteView> {
    let mut record = require_participant(state, id, user_id).await?;
    let old_items = record.items.clone();
    validate_update(&record, user_id, &body)?;
    let content_changed = changes_content(&body, &record);
    reset_delivered_reminder_if_rescheduled(&body, &mut record);
    let label_ids = body.label_ids.take();

    // Version history: only content edits are versioned (color/pin/archive and
    // friends are organizational, not "content you'd roll back"). Capture the
    // pre-edit state as a snapshot when this edit opens a new session — a
    // different author, or a gap since the last content edit. Same-author
    // edits within the window coalesce, so history is one entry per sitting
    // rather than one per debounced save. The first-ever edit always snapshots
    // (last_editor_id is None), preserving how the note started.
    if content_changed {
        if starts_new_edit_session(&record, user_id) {
            state.repo.insert_note_version(&version_of(&record)).await?;
        }
        record.last_editor_id = Some(user_id.to_string());
    }

    body.apply_to(&mut record);
    record.updated_at = now();
    state.repo.update_note(&record).await?;

    // Items checked off in this patch feed this note's suggestion dictionary
    // ("Milk" checked today autocompletes on next week's list) — scoped per
    // note, so suggestions never leak across notes.
    let newly_checked = newly_checked_texts(&old_items, &record.items);
    if !newly_checked.is_empty() {
        state.repo.record_checked_items(id, &newly_checked).await?;
    }

    if let Some(label_ids) = label_ids {
        state.repo.set_note_labels(id, user_id, &label_ids).await?;
    }
    state.index_note_later(id);
    // Only content edits re-run auto-labeling; organizational patches
    // (color/pin/position/labels themselves) never cost an LLM call.
    if content_changed {
        state.label_note_later(id, user_id);
    }
    state.notify_note(id).await;
    let mut view = state
        .repo
        .note_view(id, user_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    state.sign_view(&mut view);
    Ok(view)
}

pub async fn delete_note(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let record = require_participant(&state, &id, &user_id).await?;
    if record.owner_id != user_id {
        return Err(ApiError::Forbidden("only the owner can delete a note"));
    }
    // Snapshot the roster and blobs before rows cascade away.
    let participants = state.repo.participant_ids(&id).await?;
    let attachments = state
        .repo
        .note_view(&id, &user_id)
        .await?
        .map(|v| v.attachments)
        .unwrap_or_default();
    state.repo.delete_note(&id).await?;
    for attachment in attachments {
        state.files.delete(&record.owner_id, &attachment.id).await;
    }
    state.unindex_note_later(&id);
    state.hub.notify(&participants, CHANGED_MSG);
    Ok(StatusCode::NO_CONTENT)
}

pub async fn reorder_notes(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Json(body): Json<ReorderRequest>,
) -> ApiResult<StatusCode> {
    state.repo.reorder_for_user(&user_id, &body.ids).await?;
    state.notify_user(&user_id);
    Ok(StatusCode::NO_CONTENT)
}
