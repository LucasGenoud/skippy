use std::collections::HashMap;

use axum::extract::ws::{Message, WebSocket};
use axum::extract::{Multipart, Path, Query, State, WebSocketUpgrade};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::Json;
use chrono::Utc;
use futures::{SinkExt, StreamExt};
use serde::Deserialize;
use uuid::Uuid;

use crate::AppState;
use crate::auth::{AuthUser, SessionToken, hash_password, verify_password};
use crate::error::{ApiError, ApiResult};
use crate::models::*;

const CHANGED_MSG: &str = r#"{"type":"notes_changed"}"#;
const TRASH_RETENTION_DAYS: i64 = 7;

/// Edits to the same note by the same author within this window collapse into
/// one history entry, so the timeline records editing *sessions* rather than
/// every debounced autosave. A different editor, or a longer gap, opens a new
/// version.
const VERSION_SESSION_GAP_SECS: i64 = 120;

/// Seconds elapsed since an RFC3339 timestamp. An unparseable stamp reads as
/// "long ago" so it never suppresses a snapshot.
fn seconds_since(ts: &str) -> i64 {
    match chrono::DateTime::parse_from_rfc3339(ts) {
        Ok(t) => (Utc::now() - t.with_timezone(&Utc)).num_seconds(),
        Err(_) => i64::MAX,
    }
}

/// Build a history snapshot of a record's current content, attributed to
/// whoever last authored it (falling back to the owner for the first/legacy
/// snapshot, which carries no editor).
fn version_of(record: &NoteRecord) -> NoteVersion {
    NoteVersion {
        id: new_id(),
        note_id: record.id.clone(),
        kind: record.kind.clone(),
        title: record.title.clone(),
        content: record.content.clone(),
        items: record.items.clone(),
        edited_by: record.last_editor_id.clone().or_else(|| Some(record.owner_id.clone())),
        created_at: record.updated_at.clone(),
    }
}

fn now() -> String {
    Utc::now().to_rfc3339()
}

fn new_id() -> String {
    Uuid::new_v4().to_string()
}

impl AppState {
    /// Push a change event to everyone who can see the note.
    async fn notify_note(&self, note_id: &str) {
        if let Ok(ids) = self.repo.participant_ids(note_id).await {
            self.hub.notify(&ids, CHANGED_MSG);
        }
    }

    fn notify_user(&self, user_id: &str) {
        self.hub.notify(std::slice::from_ref(&user_id.to_string()), CHANGED_MSG);
    }

    /// Re-embed and index a note in the background (fire and forget); request
    /// latency never waits on the embedder.
    pub fn index_note_later(&self, note_id: &str) {
        let Some(search) = self.search.clone() else { return };
        let repo = self.repo.clone();
        let note_id = note_id.to_string();
        tokio::spawn(async move {
            let Ok(Some(record)) = repo.note_record(&note_id).await else { return };
            let participants = repo.participant_ids(&note_id).await.unwrap_or_default();
            if let Err(e) = search.index_note(&record, participants).await {
                eprintln!("semantic index failed for {note_id}: {e:#}");
            }
        });
    }

    pub fn unindex_note_later(&self, note_id: &str) {
        let Some(search) = self.search.clone() else { return };
        let note_id = note_id.to_string();
        tokio::spawn(async move {
            let _ = search.remove_note(&note_id).await;
        });
    }

    /// Transcribe an audio attachment in the background (fire and forget).
    /// The caller is expected to have already marked the note `pending`; this
    /// only runs Whisper, then stores the transcript (`done`) or marks
    /// `failed`, re-indexing for search on success. No-op when transcription
    /// is disabled.
    pub fn transcribe_later(&self, note_id: &str, attachment_id: &str, filename: &str) {
        let Some(transcriber) = self.transcribe.clone() else { return };
        let state = self.clone();
        let note_id = note_id.to_string();
        let attachment_id = attachment_id.to_string();
        let filename = filename.to_string();
        tokio::spawn(async move {
            let status_and_content = match state.files.read(&attachment_id).await {
                Some(bytes) => match transcriber.transcribe(bytes, &filename).await {
                    Ok(text) => (TRANSCRIPT_DONE, Some(text)),
                    Err(e) => {
                        eprintln!("transcription failed for {note_id}: {e:#}");
                        (TRANSCRIPT_FAILED, None)
                    }
                },
                None => (TRANSCRIPT_FAILED, None),
            };
            let (status, content) = status_and_content;
            let _ = state.repo.set_transcript(&note_id, status, content.as_deref()).await;
            if status == TRANSCRIPT_DONE {
                state.index_note_later(&note_id);
            }
            state.notify_note(&note_id).await;
        });
    }
}

/// Load a note, requiring the user to be owner or collaborator. Strangers get
/// 404 rather than 403 so note ids leak nothing.
async fn require_participant(
    state: &AppState,
    note_id: &str,
    user_id: &str,
) -> ApiResult<NoteRecord> {
    let record = state.repo.note_record(note_id).await?.ok_or(ApiError::NotFound)?;
    if !state.repo.is_participant(note_id, user_id).await? {
        return Err(ApiError::NotFound);
    }
    Ok(record)
}

pub async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "ok": true }))
}

/// Which optional, service-backed features this server has enabled. The client
/// uses it to show or hide the semantic-search toggle and the audio-note
/// recorder — a feature whose backing service isn't running simply never
/// appears. Unauthenticated, like [`health`]: it leaks nothing user-specific.
pub async fn capabilities(State(state): State<AppState>) -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "semantic_search": state.search.is_some(),
        "audio_transcription": state.transcribe.is_some(),
    }))
}

// ---------------------------------------------------------------------------
// Auth

fn validate_credentials(creds: &Credentials) -> ApiResult<()> {
    let name_ok = creds.username.len() >= 3
        && creds.username.len() <= 32
        && creds
            .username
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.');
    if !name_ok {
        return Err(ApiError::BadRequest(
            "username must be 3-32 characters (letters, digits, _ - .)".to_string(),
        ));
    }
    if creds.password.len() < 6 {
        return Err(ApiError::BadRequest("password must be at least 6 characters".to_string()));
    }
    Ok(())
}

pub async fn register(
    State(state): State<AppState>,
    Json(creds): Json<Credentials>,
) -> ApiResult<(StatusCode, Json<AuthResponse>)> {
    validate_credentials(&creds)?;
    let user = User {
        id: new_id(),
        username: creds.username.trim().to_string(),
        password_hash: hash_password(&creds.password)?,
    };
    state.repo.create_user(&user).await?;
    let token = new_id();
    state.repo.create_session(&token, &user.id).await?;
    Ok((StatusCode::CREATED, Json(AuthResponse { token, user: user.public() })))
}

pub async fn login(
    State(state): State<AppState>,
    Json(creds): Json<Credentials>,
) -> ApiResult<Json<AuthResponse>> {
    let user = state
        .repo
        .user_by_username(creds.username.trim())
        .await?
        .filter(|u| verify_password(&creds.password, &u.password_hash))
        .ok_or(ApiError::Unauthorized)?;
    let token = new_id();
    state.repo.create_session(&token, &user.id).await?;
    Ok(Json(AuthResponse { token, user: user.public() }))
}

pub async fn logout(
    State(state): State<AppState>,
    SessionToken(token): SessionToken,
) -> ApiResult<StatusCode> {
    state.repo.delete_session(&token).await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn me(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
) -> ApiResult<Json<UserPublic>> {
    let user = state.repo.user_by_id(&user_id).await?.ok_or(ApiError::Unauthorized)?;
    Ok(Json(user.public()))
}

// ---------------------------------------------------------------------------
// Notes

fn validate_kind(kind: &str) -> ApiResult<()> {
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

pub async fn list_notes(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
) -> ApiResult<Json<Vec<NoteView>>> {
    purge_old_trash(&state).await?;
    Ok(Json(state.repo.notes_for_user(&user_id).await?))
}

pub async fn purge_old_trash(state: &AppState) -> ApiResult<()> {
    let cutoff = (Utc::now() - chrono::Duration::days(TRASH_RETENTION_DAYS)).to_rfc3339();
    for note_id in state.repo.purge_trash_before(&cutoff).await? {
        state.unindex_note_later(&note_id);
    }
    Ok(())
}

pub async fn create_note(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Json(body): Json<CreateNote>,
) -> ApiResult<(StatusCode, Json<NoteView>)> {
    let kind = body.kind.unwrap_or_else(|| KIND_TEXT.to_string());
    validate_kind(&kind)?;
    validate_reminder(&body.reminder_at)?;
    let id = match body.id {
        Some(id) if !id.trim().is_empty() => id,
        _ => new_id(),
    };
    let position = match body.position {
        Some(p) => p,
        // New notes go to the front of the grid.
        None => state.repo.min_position_for_user(&user_id).await? - 1024.0,
    };
    let ts = now();
    let record = NoteRecord {
        id: id.clone(),
        owner_id: user_id.clone(),
        kind,
        title: body.title,
        content: body.content,
        items: body.items.unwrap_or_default(),
        color: body.color.unwrap_or_else(|| "default".to_string()),
        pinned: body.pinned.unwrap_or(false),
        archived: false,
        trashed: false,
        position,
        reminder_at: body.reminder_at,
        transcript_status: TRANSCRIPT_NONE.to_string(),
        created_at: ts.clone(),
        updated_at: ts,
        // Set on the first edit; until then there's nothing to attribute.
        last_editor_id: None,
    };
    state.repo.insert_note(&record).await?;
    let pre_checked: Vec<String> =
        record.items.iter().filter(|i| i.done).map(|i| i.text.clone()).collect();
    if !pre_checked.is_empty() {
        state.repo.record_checked_items(&record.id, &pre_checked).await?;
    }
    state.index_note_later(&id);
    state.notify_user(&user_id);
    let view = state.repo.note_view(&id, &user_id).await?.ok_or(ApiError::NotFound)?;
    Ok((StatusCode::CREATED, Json(view)))
}

pub async fn get_note(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
) -> ApiResult<Json<NoteView>> {
    require_participant(&state, &id, &user_id).await?;
    let view = state.repo.note_view(&id, &user_id).await?.ok_or(ApiError::NotFound)?;
    Ok(Json(view))
}

pub async fn update_note(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
    Json(mut body): Json<UpdateNote>,
) -> ApiResult<Json<NoteView>> {
    let mut record = require_participant(&state, &id, &user_id).await?;
    let old_items = record.items.clone();

    // Trash lifecycle is the owner's call; everything else is shared editing.
    if body.trashed.is_some() && record.owner_id != user_id {
        return Err(ApiError::Forbidden("only the owner can trash or restore a note"));
    }
    if let Some(kind) = &body.kind {
        validate_kind(kind)?;
    }
    if let Some(reminder) = &body.reminder_at {
        validate_reminder(reminder)?;
    }

    let label_ids = body.label_ids.take();

    // Version history: only content edits are versioned (color/pin/archive and
    // friends are organizational, not "content you'd roll back"). Capture the
    // pre-edit state as a snapshot when this edit opens a new session — a
    // different author, or a gap since the last content edit. Same-author
    // edits within the window coalesce, so history is one entry per sitting
    // rather than one per debounced save. The first-ever edit always snapshots
    // (last_editor_id is None), preserving how the note started.
    let content_changed = body.kind.as_ref().is_some_and(|v| *v != record.kind)
        || body.title.as_ref().is_some_and(|v| *v != record.title)
        || body.content.as_ref().is_some_and(|v| *v != record.content)
        || body.items.as_ref().is_some_and(|v| *v != record.items);
    if content_changed {
        let same_session = record.last_editor_id.as_deref() == Some(user_id.as_str())
            && seconds_since(&record.updated_at) < VERSION_SESSION_GAP_SECS;
        if !same_session {
            state.repo.insert_note_version(&version_of(&record)).await?;
        }
        record.last_editor_id = Some(user_id.clone());
    }

    body.apply_to(&mut record);
    record.updated_at = now();
    state.repo.update_note(&record).await?;

    // Items checked off in this patch feed this note's suggestion dictionary
    // ("Milk" checked today autocompletes on next week's list) — scoped per
    // note, so suggestions never leak across notes.
    let newly_checked: Vec<String> = record
        .items
        .iter()
        .filter(|item| item.done && !old_items.iter().any(|o| o.id == item.id && o.done))
        .map(|item| item.text.clone())
        .collect();
    if !newly_checked.is_empty() {
        state.repo.record_checked_items(&id, &newly_checked).await?;
    }

    if let Some(label_ids) = label_ids {
        state.repo.set_note_labels(&id, &user_id, &label_ids).await?;
    }
    state.index_note_later(&id);
    state.notify_note(&id).await;
    let view = state.repo.note_view(&id, &user_id).await?.ok_or(ApiError::NotFound)?;
    Ok(Json(view))
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
        state.files.delete(&attachment.id).await;
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

// ---------------------------------------------------------------------------
// Version history

/// A note's edit history, newest first. Each entry carries the full content of
/// that past state plus the resolved editor, so the client can preview and
/// restore without a second round-trip.
pub async fn list_note_versions(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
) -> ApiResult<Json<Vec<serde_json::Value>>> {
    require_participant(&state, &id, &user_id).await?;
    let versions = state.repo.note_versions(&id).await?;
    // Resolve author ids to public users, caching lookups (a note usually has
    // one or two distinct editors across its whole history).
    let mut users: HashMap<String, Option<UserPublic>> = HashMap::new();
    let mut out = Vec::with_capacity(versions.len());
    for v in versions {
        let editor = match &v.edited_by {
            Some(uid) => {
                if !users.contains_key(uid) {
                    let public = state.repo.user_by_id(uid).await?.map(|u| u.public());
                    users.insert(uid.clone(), public);
                }
                users.get(uid).cloned().flatten()
            }
            None => None,
        };
        out.push(serde_json::json!({
            "id": v.id,
            "note_id": v.note_id,
            "kind": v.kind,
            "title": v.title,
            "content": v.content,
            "items": v.items,
            "edited_by": editor,
            "created_at": v.created_at,
        }));
    }
    Ok(Json(out))
}

/// Roll a note's content back to a past version. The pre-restore state is
/// checkpointed first, so a restore is itself reversible from the timeline.
pub async fn restore_note_version(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path((id, version_id)): Path<(String, String)>,
) -> ApiResult<Json<NoteView>> {
    let mut record = require_participant(&state, &id, &user_id).await?;
    let version = state.repo.note_version(&id, &version_id).await?.ok_or(ApiError::NotFound)?;

    // Nothing to do when the note already matches the target version.
    let unchanged = record.kind == version.kind
        && record.title == version.title
        && record.content == version.content
        && record.items == version.items;
    if !unchanged {
        state.repo.insert_note_version(&version_of(&record)).await?;
        record.kind = version.kind;
        record.title = version.title;
        record.content = version.content;
        record.items = version.items;
        record.last_editor_id = Some(user_id.clone());
        record.updated_at = now();
        state.repo.update_note(&record).await?;
        state.index_note_later(&id);
        state.notify_note(&id).await;
    }

    let view = state.repo.note_view(&id, &user_id).await?.ok_or(ApiError::NotFound)?;
    Ok(Json(view))
}

// ---------------------------------------------------------------------------
// Sharing

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
        .user_by_username(body.username.trim())
        .await?
        .ok_or_else(|| ApiError::BadRequest(format!("no user named '{}'", body.username.trim())))?;
    if target.id == user_id {
        return Err(ApiError::Conflict("that's you — the owner already has access".to_string()));
    }
    state.repo.add_collaborator(&id, &target.id).await?;
    state.index_note_later(&id); // participants changed -> access filter changed
    state.notify_note(&id).await;
    let view = state.repo.note_view(&id, &user_id).await?.ok_or(ApiError::NotFound)?;
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
        return Err(ApiError::Forbidden("collaborators can only remove themselves"));
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

// ---------------------------------------------------------------------------
// Labels

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

// ---------------------------------------------------------------------------
// Attachments

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
        let attachment = Attachment {
            id: new_id(),
            mime,
            filename,
            size: bytes.len() as i64,
        };
        state.files.save(&attachment.id, &bytes).await?;
        state.repo.insert_attachment(&attachment, &id).await?;
        // An audio clip dropped onto an audio note kicks off transcription:
        // mark pending now (synchronously, so any refetch sees it) and run
        // Whisper in the background. No-op when transcription is disabled.
        if state.transcribe.is_some()
            && record.kind == KIND_AUDIO
            && attachment.mime.starts_with("audio/")
        {
            state.repo.set_transcript(&id, TRANSCRIPT_PENDING, None).await?;
            state.transcribe_later(&id, &attachment.id, &attachment.filename);
        }
        state.notify_note(&id).await;
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
    state.transcribe_later(&id, &clip.id, &clip.filename);
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
    require_participant(&state, &note_id, &user_id).await?;
    state.repo.delete_attachment(&id).await?;
    state.files.delete(&id).await;
    state.notify_note(&note_id).await;
    Ok(StatusCode::NO_CONTENT)
}

/// Serves attachment bytes. Unauthenticated by design: ids are unguessable
/// UUIDs, which lets plain `<img>` tags work. Documented trade-off.
///
/// Only images render inline; everything else is forced to download with its
/// original filename, so a user-uploaded HTML file can never execute in the
/// app's origin.
pub async fn serve_file(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    let (_, attachment) =
        state.repo.attachment_info(&id).await?.ok_or(ApiError::NotFound)?;
    let bytes = state.files.read(&id).await.ok_or(ApiError::NotFound)?;
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
            (header::CACHE_CONTROL, "public, max-age=31536000, immutable".to_string()),
        ],
        bytes,
    )
        .into_response())
}

// ---------------------------------------------------------------------------
// Semantic search

#[derive(Deserialize)]
pub struct SearchParams {
    q: String,
    #[serde(default)]
    limit: Option<usize>,
}

/// Meaning-based note search. Returns ranked note ids with scores; the
/// client maps them onto notes it already has.
pub async fn semantic_search(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Query(params): Query<SearchParams>,
) -> ApiResult<Json<serde_json::Value>> {
    let Some(search) = &state.search else {
        return Err(ApiError::Unavailable("semantic search is not enabled on this server"));
    };
    let query = params.q.trim();
    if query.is_empty() {
        return Ok(Json(serde_json::json!([])));
    }
    let limit = params.limit.unwrap_or(20).min(50);
    let hits: Vec<_> = search
        .search(&user_id, query, limit)
        .await?
        .into_iter()
        .map(|(note_id, score)| serde_json::json!({"note_id": note_id, "score": score}))
        .collect();
    Ok(Json(serde_json::json!(hits)))
}

// ---------------------------------------------------------------------------
// Per-user settings

const MAX_SETTINGS_BYTES: usize = 16 * 1024;

pub async fn get_settings(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
) -> ApiResult<Response> {
    let data = state
        .repo
        .settings_for_user(&user_id)
        .await?
        .unwrap_or_else(|| "{}".to_string());
    Ok(([(header::CONTENT_TYPE, "application/json")], data).into_response())
}

/// The settings document is an opaque JSON object owned by the client; the
/// server only validates shape and size and fans out a change event so other
/// devices pick it up.
pub async fn put_settings(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Json(body): Json<serde_json::Value>,
) -> ApiResult<StatusCode> {
    if !body.is_object() {
        return Err(ApiError::BadRequest("settings must be a JSON object".to_string()));
    }
    let data = body.to_string();
    if data.len() > MAX_SETTINGS_BYTES {
        return Err(ApiError::BadRequest("settings document too large".to_string()));
    }
    state.repo.put_settings(&user_id, &data).await?;
    state.notify_user(&user_id);
    Ok(StatusCode::NO_CONTENT)
}

// ---------------------------------------------------------------------------
// WebSocket

#[derive(Deserialize)]
pub struct WsParams {
    token: String,
}

pub async fn ws_handler(
    State(state): State<AppState>,
    Query(params): Query<WsParams>,
    upgrade: WebSocketUpgrade,
) -> ApiResult<Response> {
    let user_id = state
        .repo
        .user_id_for_token(&params.token)
        .await?
        .ok_or(ApiError::Unauthorized)?;
    Ok(upgrade.on_upgrade(move |socket| ws_loop(socket, state, user_id)))
}

async fn ws_loop(socket: WebSocket, state: AppState, user_id: String) {
    let mut events = state.hub.subscribe(&user_id);
    let (mut sink, mut stream) = socket.split();
    loop {
        tokio::select! {
            event = events.recv() => {
                match event {
                    Ok(msg) => {
                        if sink.send(Message::text(msg)).await.is_err() {
                            break;
                        }
                    }
                    // Lagged: we dropped events; a generic nudge still works.
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                        if sink.send(Message::text(CHANGED_MSG)).await.is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            incoming = stream.next() => {
                match incoming {
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Err(_)) => break,
                    _ => {} // ignore pings/client chatter
                }
            }
        }
    }
}
