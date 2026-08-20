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
use super::{
    CHANGED_MSG, is_note_workspace_owner, new_id, now, require_participant, resolve_workspace,
};

const TRASH_RETENTION_DAYS: i64 = 7;

const REMINDER_REPEATS: &[&str] = &["daily", "weekly", "monthly", "yearly"];

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

fn validate_reminder_repeat(value: Option<&str>) -> ApiResult<()> {
    if let Some(value) = value
        && !REMINDER_REPEATS.contains(&value)
    {
        return Err(ApiError::BadRequest(
            "reminder_repeat must be daily, weekly, monthly, or yearly".to_string(),
        ));
    }
    Ok(())
}

/// Check one item reminder against the note it is meant for. An unchecked item
/// of that note must exist to carry it: the reminder's whole meaning is "this
/// row, still to do".
fn validate_item_reminder(record: &NoteRecord, reminder: &ItemReminder) -> ApiResult<()> {
    validate_reminder(&Some(reminder.reminder_at.clone()))?;
    validate_reminder_repeat(reminder.reminder_repeat.as_deref())?;
    let item = record
        .items
        .iter()
        .find(|item| item.id == reminder.item_id)
        .ok_or(ApiError::NotFound)?;
    if item.done {
        return Err(ApiError::BadRequest(
            "a checked item cannot carry a reminder".to_string(),
        ));
    }
    Ok(())
}

fn validate_update(record: &NoteRecord, is_owner: bool, body: &UpdateNote) -> ApiResult<()> {
    if body.trashed.is_some() && !is_owner {
        return Err(ApiError::Forbidden(
            "only the owner can trash or restore a note",
        ));
    }
    // Moving a note changes who can see it, which is the owner's call, the
    // same reasoning as trashing.
    if body
        .workspace_id
        .as_ref()
        .is_some_and(|id| *id != record.workspace_id)
        && !is_owner
    {
        return Err(ApiError::Forbidden(
            "only the owner can move a note to another workspace",
        ));
    }
    if let Some(kind) = &body.kind {
        validate_kind(kind)?;
    }
    if let Some(reminder) = &body.reminder_at {
        validate_reminder(reminder)?;
    }
    if let Some(repeat) = &body.reminder_repeat {
        validate_reminder_repeat(repeat.as_deref())?;
    }
    let clearing_reminder = body.reminder_at.as_ref().is_some_and(Option::is_none);
    if clearing_reminder && body.reminder_repeat.as_ref().is_some_and(Option::is_some) {
        return Err(ApiError::BadRequest(
            "reminder_repeat requires reminder_at".to_string(),
        ));
    }
    let reminder_at = body
        .reminder_at
        .as_ref()
        .map_or(record.reminder_at.as_ref(), |value| value.as_ref());
    let reminder_repeat = if clearing_reminder {
        None
    } else {
        body.reminder_repeat
            .as_ref()
            .map_or(record.reminder_repeat.as_ref(), |value| value.as_ref())
    };
    if reminder_repeat.is_some() && reminder_at.is_none() {
        return Err(ApiError::BadRequest(
            "reminder_repeat requires reminder_at".to_string(),
        ));
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
    if body
        .reminder_repeat
        .as_ref()
        .is_some_and(|repeat| *repeat != record.reminder_repeat)
    {
        // Changing recurrence makes the selected occurrence live again. This
        // matters when turning a completed one-shot reminder into a series.
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
    state.repo.purge_trash_before(cutoff).await?;
    state.drain_cleanup_jobs().await;
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
    validate_reminder_repeat(body.reminder_repeat.as_deref())?;
    if body.reminder_repeat.is_some() && body.reminder_at.is_none() {
        return Err(ApiError::BadRequest(
            "reminder_repeat requires reminder_at".to_string(),
        ));
    }
    let workspace_id = resolve_workspace(state, user_id, body.workspace_id.as_deref()).await?;
    let stage_id = match body.stage_id.filter(|id| !id.trim().is_empty()) {
        Some(stage_id)
            if state
                .repo
                .stages_for_user(user_id)
                .await?
                .into_iter()
                .any(|stage| stage.id == stage_id && stage.workspace_id == workspace_id) =>
        {
            Some(stage_id)
        }
        _ => None,
    };
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
        workspace_id,
        created_by: Some(user_id.to_string()),
        kind,
        title: body.title,
        content: body.content,
        items: {
            // A checklist arrives as a flat list carrying its own nesting, so
            // the shape is checked at the door: see `normalize_item_depths`.
            let mut items = body.items.unwrap_or_default();
            normalize_item_depths(&mut items);
            items
        },
        color: body.color.unwrap_or_else(|| "default".to_string()),
        pinned: body.pinned.unwrap_or(false),
        archived: body.archived.unwrap_or(false),
        trashed: body.trashed.unwrap_or(false),
        position,
        reminder_at: body.reminder_at,
        reminder_repeat: body.reminder_repeat,
        reminder_fired_at: None,
        transcript_status: TRANSCRIPT_NONE.to_string(),
        created_at,
        updated_at,
        // Set on the first edit; until then there's nothing to attribute.
        last_editor_id: None,
        stage_id,
        // Board order starts out matching grid order, so a note is in the same
        // relative place however you look at it.
        stage_position: body.stage_position.unwrap_or(position),
    };
    state.repo.insert_note(&record).await?;
    // A stage from another workspace is dropped rather than honoured, the same
    // way a foreign label is.
    if record.stage_id.is_some() {
        state.repo.prune_foreign_stage(&record.id).await?;
    }
    if let Some(label_ids) = body.label_ids
        && let Err(error) = state.repo.set_note_labels(&record.id, &label_ids).await
    {
        if let Err(rollback_error) = state.repo.delete_note(&record.id).await {
            state.report_background_failure("note_create_rollback", &format!("{rollback_error:?}"));
        }
        return Err(error.into());
    }
    // Reminders for the items this note was created with. A create is one
    // request, so an offline-composed checklist and a restored backup arrive
    // whole rather than as a note followed by a write per reminder.
    for reminder in body.item_reminders.into_iter().flatten() {
        validate_item_reminder(&record, &reminder)?;
        state.repo.set_item_reminder(&record.id, &reminder).await?;
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
    let is_owner = is_note_workspace_owner(state, &record, user_id).await?;
    validate_update(&record, is_owner, &body)?;
    // A move must land in a workspace the mover belongs to; anything else is
    // treated as a stray id rather than a way to file notes out of reach.
    let moving_to = match &body.workspace_id {
        Some(target) if *target != record.workspace_id => {
            let target = resolve_workspace(state, user_id, Some(target)).await?;
            let target_is_owned = state
                .repo
                .workspace(&target)
                .await?
                .is_some_and(|workspace| workspace.owner_id == user_id);
            if !target_is_owned {
                return Err(ApiError::Forbidden(
                    "a note can only be moved into a workspace you own",
                ));
            }
            Some(target)
        }
        _ => None,
    };
    // A move takes the note out of one roster and into another, so the people
    // losing sight of it have to be told before that happens.
    let audience_before_move = match moving_to {
        Some(_) => state.repo.participant_ids(id).await?,
        None => Vec::new(),
    };
    if moving_to.is_none()
        && let Some(Some(stage_id)) = body.stage_id.as_ref()
    {
        let valid = state
            .repo
            .stages_for_user(user_id)
            .await?
            .into_iter()
            .any(|stage| stage.id == *stage_id && stage.workspace_id == record.workspace_id);
        if !valid {
            body.stage_id = Some(None);
        }
    }
    let content_changed = changes_content(&body, &record);
    // Read before `apply_to` consumes the body. Present-but-null is a real
    // change (back to unassigned), so this asks whether the key was sent.
    let stage_changed = body.stage_id.is_some();
    reset_delivered_reminder_if_rescheduled(&body, &mut record);
    let label_ids = body.label_ids.take();

    // Version history: only content edits are versioned (color/pin/archive and
    // friends are organizational, not "content you'd roll back"). Capture the
    // pre-edit state as a snapshot when this edit opens a new session, a
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
    // Applies to every write, not just one carrying items: an edit that
    // changes the kind can leave rows behind that no longer have a parent.
    normalize_item_depths(&mut record.items);
    if moving_to.is_some() {
        // The stage foreign key includes workspace_id, so ownership transfer
        // returns the note to Unassigned before the row is updated.
        record.stage_id = None;
    }
    record.updated_at = now();
    state.repo.update_note(&record).await?;

    // Items checked off in this patch feed this note's suggestion dictionary
    // ("Milk" checked today autocompletes on next week's list), scoped per
    // note, so suggestions never leak across notes.
    let newly_checked = newly_checked_texts(&old_items, &record.items);
    if !newly_checked.is_empty() {
        state.repo.record_checked_items(id, &newly_checked).await?;
    }

    // A moved note leaves its old workspace's labels behind, they are that
    // workspace's taxonomy, not this note's. Runs before the patch's own
    // label_ids so an explicit set still wins.
    if moving_to.is_some() {
        state.repo.prune_foreign_labels(id).await?;
    }
    // Same rule for the board column, which is that workspace's too: a move
    // sends the note back to unassigned, and a stray stage id never sticks.
    if moving_to.is_some() || stage_changed {
        state.repo.prune_foreign_stage(id).await?;
    }
    // Labels belong to the note's workspace. Someone who reached the note
    // through a direct share is not in that workspace and sees none of them,
    // so their patch must not be able to clear them either.
    if let Some(label_ids) = label_ids
        && state
            .repo
            .is_workspace_member(&record.workspace_id, user_id)
            .await?
    {
        state.repo.set_note_labels(id, &label_ids).await?;
    }
    state.index_note_later(id);
    // Only content edits re-run auto-labeling; organizational patches
    // (color/pin/position/labels themselves) never cost an LLM call.
    if content_changed {
        state.label_note_later(id, user_id);
    }
    state.notify_note(id).await;
    state.hub.notify(&audience_before_move, CHANGED_MSG);
    let mut view = state
        .repo
        .note_view(id, user_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    state.sign_view(&mut view);
    Ok(view)
}

/// Set or clear the reminder on one checklist item.
///
/// A sub-resource rather than a field on the note patch, so two devices
/// working on two rows of the same list never overwrite each other, and so a
/// client that knows nothing about item reminders cannot clear them all by
/// sending a stale `items` array. Like the note-level reminder, it is shared
/// state: any participant may set one.
pub async fn set_item_reminder(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path((id, item_id)): Path<(String, String)>,
    Json(body): Json<SetItemReminder>,
) -> ApiResult<Json<NoteView>> {
    let record = require_participant(&state, &id, &user_id).await?;
    match body.reminder_at.filter(|value| !value.trim().is_empty()) {
        Some(reminder_at) => {
            let reminder = ItemReminder {
                item_id,
                reminder_at,
                reminder_repeat: body.reminder_repeat,
            };
            validate_item_reminder(&record, &reminder)?;
            state.repo.set_item_reminder(&id, &reminder).await?;
        }
        // Clearing is a delete and stays idempotent even for an item that is
        // already gone, so an offline client can always tidy up after itself.
        None => state.repo.clear_item_reminder(&id, &item_id).await?,
    }
    // Deliberately no `updated_at` bump and no content pipeline: an alarm
    // moving is not an edit of the note, and the note should not read as
    // "Edited just now" because of it. Participants are still nudged so their
    // devices re-arm.
    state.notify_note(&id).await;
    let mut view = state
        .repo
        .note_view(&id, &user_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    state.sign_view(&mut view);
    Ok(Json(view))
}

pub async fn delete_note(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let record = require_participant(&state, &id, &user_id).await?;
    if !is_note_workspace_owner(&state, &record, &user_id).await? {
        return Err(ApiError::Forbidden("only the owner can delete a note"));
    }
    // Snapshot the roster before rows cascade away. External cleanup intent is
    // recorded transactionally by the repository.
    let participants = state.repo.participant_ids(&id).await?;
    state.repo.delete_note(&id).await?;
    state.drain_cleanup_jobs().await;
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
