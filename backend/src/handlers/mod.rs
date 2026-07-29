//! HTTP and WebSocket handlers, grouped by API area. Route wiring lives in
//! [`crate::build_app`]; every handler is re-exported here so routes and tests
//! keep addressing them as `handlers::name` regardless of submodule.

mod attachments;
mod auth;
mod background;
mod chat;
mod events;
mod labels;
mod notes;
mod probes;
mod search;
mod settings;
mod sharing;
mod stages;
mod unfurl;
mod versions;
mod workspaces;
mod writing;

pub use attachments::{delete_attachment, serve_file, transcribe_note, upload_attachment};
pub use auth::{delete_account, login, logout, me, register, update_account};
pub use chat::chat_ws;
pub use events::ws_handler;
pub use labels::{create_label, delete_label, list_labels, update_label};
pub use notes::{
    apply_note_update, create_note, create_note_for_user, delete_note, get_note, list_notes,
    purge_old_trash, purge_trash, reorder_notes, update_note,
};
pub use probes::{llm_test, notify_test};
pub use search::{reindex_search, reindex_status, search_stats, semantic_search};
pub use settings::{get_settings, put_settings};
pub use sharing::{add_collaborator, checklist_history, remove_collaborator};
pub use stages::{create_stage, delete_stage, list_stages, update_stage};
pub use unfurl::unfurl;
pub use versions::{list_note_versions, restore_note_version};
pub use workspaces::{
    add_workspace_member, create_default_workspace, create_workspace, delete_workspace,
    list_workspaces, remove_workspace_member, rename_workspace,
};
pub use writing::rewrite_note;

use axum::Json;
use axum::extract::State;
use chrono::Utc;
use uuid::Uuid;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::models::NoteRecord;

/// The change-event frame pushed to clients; they respond with a refetch.
const CHANGED_MSG: &str = r#"{"type":"notes_changed"}"#;

fn now() -> String {
    Utc::now().to_rfc3339()
}

fn new_id() -> String {
    Uuid::new_v4().to_string()
}

/// Load a note, requiring the user to be owner or collaborator. Strangers get
/// 404 rather than 403 so note ids leak nothing.
async fn require_participant(
    state: &AppState,
    note_id: &str,
    user_id: &str,
) -> ApiResult<NoteRecord> {
    let record = state
        .repo
        .note_record(note_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    if !state.repo.is_participant(note_id, user_id).await? {
        return Err(ApiError::NotFound);
    }
    Ok(record)
}

/// Ids of the notes a user can see in one workspace. Used to narrow retrieval
/// (search, chat) to the workspace the client has open, which the vector index
/// cannot express on its own: it partitions by participant, not by workspace.
pub(super) async fn workspace_note_ids(
    state: &AppState,
    user_id: &str,
    workspace_id: &str,
) -> ApiResult<std::collections::HashSet<String>> {
    Ok(state
        .repo
        .notes_for_user(user_id)
        .await?
        .into_iter()
        .filter(|view| view.note.workspace_id == workspace_id)
        .map(|view| view.note.id)
        .collect())
}

/// Resolve the workspace a request targets: the one it names — which the
/// caller must belong to — or, when it names none, their default workspace.
/// Absent is a deliberate default rather than an error, so callers with no
/// workspace in hand (the chat write path, scripted creates) still work.
async fn resolve_workspace(
    state: &AppState,
    user_id: &str,
    requested: Option<&str>,
) -> ApiResult<String> {
    match requested.map(str::trim).filter(|id| !id.is_empty()) {
        Some(id) => {
            if !state.repo.is_workspace_member(id, user_id).await? {
                return Err(ApiError::NotFound);
            }
            Ok(id.to_string())
        }
        // `ensure_workspaces` repairs an account that somehow has none, so a
        // note always has somewhere to live.
        None => Ok(workspaces::ensure_workspaces(state, user_id)
            .await?
            .into_iter()
            .find(|w| w.is_default)
            .ok_or(ApiError::NotFound)?
            .id),
    }
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

/// Which settings keys the self-hoster has pinned via env vars. The client
/// locks these fields and reflects their values — except secrets, whose values
/// are redacted (`{"secret": true, "value": null}`) so an env-set API key never
/// reaches the frontend. Auth-gated: base URLs are server infrastructure, not
/// for anonymous callers.
pub async fn managed_settings(
    State(state): State<AppState>,
    AuthUser(_user_id): AuthUser,
) -> Json<serde_json::Value> {
    Json(state.managed.public_view())
}
