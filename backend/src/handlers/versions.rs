//! Per-note version history: snapshot capture policy, timeline listing, and
//! restore. Snapshots are pre-images (the state BEFORE an edit), so the live
//! note is always "current" and versions are strictly past.

use std::collections::HashMap;

use axum::Json;
use axum::extract::{Path, State};
use chrono::Utc;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::models::*;

use super::{new_id, now, require_participant};

/// Edits to the same note by the same author within this window collapse into
/// one history entry, so the timeline records editing *sessions* rather than
/// every debounced autosave. A different editor, or a longer gap, opens a new
/// version.
pub(super) const VERSION_SESSION_GAP_SECS: i64 = 120;

/// Seconds elapsed since an RFC3339 timestamp. An unparseable stamp reads as
/// "long ago" so it never suppresses a snapshot.
pub(super) fn seconds_since(ts: &str) -> i64 {
    match chrono::DateTime::parse_from_rfc3339(ts) {
        Ok(t) => (Utc::now() - t.with_timezone(&Utc)).num_seconds(),
        Err(_) => i64::MAX,
    }
}

/// Build a history snapshot of a record's current content, attributed to
/// whoever last authored it (falling back to the owner for the first/legacy
/// snapshot, which carries no editor).
pub(super) fn version_of(record: &NoteRecord) -> NoteVersion {
    NoteVersion {
        id: new_id(),
        note_id: record.id.clone(),
        kind: record.kind.clone(),
        title: record.title.clone(),
        content: record.content.clone(),
        items: record.items.clone(),
        edited_by: record
            .last_editor_id
            .clone()
            .or_else(|| record.created_by.clone()),
        created_at: record.updated_at.clone(),
    }
}

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
    let version = state
        .repo
        .note_version(&id, &version_id)
        .await?
        .ok_or(ApiError::NotFound)?;

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

    let mut view = state
        .repo
        .note_view(&id, &user_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    state.sign_view(&mut view);
    Ok(Json(view))
}
