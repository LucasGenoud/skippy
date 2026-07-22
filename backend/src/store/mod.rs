pub mod sqlite;
mod sqlite_rows;
mod sqlite_schema;

use async_trait::async_trait;

use crate::models::*;

#[derive(Debug)]
pub enum RepoError {
    /// Unique-constraint style conflicts (duplicate email, id, label name).
    Conflict(String),
    Other(anyhow::Error),
}

impl<E: Into<anyhow::Error>> From<E> for RepoError {
    fn from(e: E) -> Self {
        RepoError::Other(e.into())
    }
}

pub type RepoResult<T> = Result<T, RepoError>;

/// What `purge_trash_before` removed — enough for the caller to clean up the
/// state that lives outside the rows (attachment blobs keyed by the owner,
/// search-index entries).
pub struct PurgedNote {
    pub note_id: String,
    pub owner_id: String,
    pub attachment_ids: Vec<String>,
}

/// Storage boundary for the whole app. Handlers only talk to this trait, so
/// swapping SQLite for Postgres (or anything else) means implementing this
/// trait and changing one line of wiring in `main`.
#[async_trait]
pub trait Repository: Send + Sync {
    // -- users & sessions ---------------------------------------------------
    async fn create_user(&self, user: &User) -> RepoResult<()>;
    async fn user_by_email(&self, email: &str) -> RepoResult<Option<User>>;
    async fn user_by_id(&self, id: &str) -> RepoResult<Option<User>>;
    async fn update_user(
        &self,
        id: &str,
        name: &str,
        email: &str,
        password_hash: &str,
    ) -> RepoResult<()>;
    /// The account owner plus everyone who shares at least one note with them.
    /// Used to refresh public display names after a profile change.
    async fn account_audience(&self, user_id: &str) -> RepoResult<Vec<String>>;
    async fn create_session(&self, token: &str, user_id: &str) -> RepoResult<()>;
    async fn user_id_for_token(&self, token: &str) -> RepoResult<Option<String>>;
    async fn delete_session(&self, token: &str) -> RepoResult<()>;

    // -- notes ---------------------------------------------------------------
    /// Every note the user owns or collaborates on, decorated for that user.
    async fn notes_for_user(&self, user_id: &str) -> RepoResult<Vec<NoteView>>;
    async fn note_view(&self, note_id: &str, viewer_id: &str) -> RepoResult<Option<NoteView>>;
    async fn note_record(&self, note_id: &str) -> RepoResult<Option<NoteRecord>>;
    async fn insert_note(&self, note: &NoteRecord) -> RepoResult<()>;
    async fn update_note(&self, note: &NoteRecord) -> RepoResult<()>;
    async fn delete_note(&self, note_id: &str) -> RepoResult<bool>;
    async fn min_position_for_user(&self, user_id: &str) -> RepoResult<f64>;
    /// Renumber the given notes in order; silently skips notes the user
    /// cannot access.
    async fn reorder_for_user(&self, user_id: &str, ids: &[String]) -> RepoResult<()>;
    /// Hard-delete trashed notes older than `cutoff`, returning what was
    /// removed so blobs and index entries can be cleaned up too.
    async fn purge_trash_before(&self, cutoff: &str) -> RepoResult<Vec<PurgedNote>>;
    /// Every note id in the store (used for search reindexing at startup).
    async fn all_note_ids(&self) -> RepoResult<Vec<String>>;

    // -- reminders ------------------------------------------------------------
    /// Non-trashed notes whose reminder is due at or before `now` (RFC3339)
    /// and hasn't fired yet. Timestamps are compared as instants, so offsets
    /// other than UTC still come due at the right moment.
    async fn due_reminders(&self, now: &str) -> RepoResult<Vec<NoteRecord>>;
    /// Record that a note's current reminder was delivered, so the sweep
    /// doesn't pick it up again. Rescheduling clears the mark (handler-side).
    async fn mark_reminder_fired(&self, note_id: &str, fired_at: &str) -> RepoResult<()>;

    // -- version history ----------------------------------------------------
    /// Append a content snapshot to a note's history. Snapshots are permanent
    /// and cascade-deleted only when the note itself is hard-deleted.
    async fn insert_note_version(&self, version: &NoteVersion) -> RepoResult<()>;
    /// A note's history, newest first.
    async fn note_versions(&self, note_id: &str) -> RepoResult<Vec<NoteVersion>>;
    /// One history entry, scoped to its note (so a stray id can't cross notes).
    async fn note_version(
        &self,
        note_id: &str,
        version_id: &str,
    ) -> RepoResult<Option<NoteVersion>>;
    /// Set an audio note's transcription status, and (when `content` is
    /// `Some`) its transcript text. Server-owned — the transcription pipeline
    /// is the only writer. Bumps `updated_at` so viewers refetch.
    async fn set_transcript(
        &self,
        note_id: &str,
        status: &str,
        content: Option<&str>,
    ) -> RepoResult<()>;

    // -- sharing ---------------------------------------------------------------
    async fn participant_ids(&self, note_id: &str) -> RepoResult<Vec<String>>;
    async fn is_participant(&self, note_id: &str, user_id: &str) -> RepoResult<bool>;
    async fn add_collaborator(&self, note_id: &str, user_id: &str) -> RepoResult<()>;
    async fn remove_collaborator(&self, note_id: &str, user_id: &str) -> RepoResult<bool>;

    // -- labels ---------------------------------------------------------------
    async fn labels_for_user(&self, user_id: &str) -> RepoResult<Vec<Label>>;
    async fn insert_label(&self, user_id: &str, label: &Label) -> RepoResult<()>;
    async fn update_label(
        &self,
        user_id: &str,
        label_id: &str,
        name: &str,
        color: Option<&str>,
        icon: Option<&str>,
    ) -> RepoResult<bool>;
    async fn delete_label(&self, user_id: &str, label_id: &str) -> RepoResult<bool>;
    /// Replace the viewer's own labels on a note (never touches labels other
    /// participants attached).
    async fn set_note_labels(
        &self,
        note_id: &str,
        user_id: &str,
        label_ids: &[String],
    ) -> RepoResult<()>;

    // -- checklist history -------------------------------------------------------
    /// Remember item texts checked off in a note (upsert, bump use count).
    /// Scoped per note: suggestions never leak from one note to another.
    async fn record_checked_items(&self, note_id: &str, texts: &[String]) -> RepoResult<()>;
    /// Entries for every note the user can access, ranked by frequency then
    /// recency; the client filters per note as the user types.
    async fn checklist_history(&self, user_id: &str) -> RepoResult<Vec<HistoryEntry>>;

    // -- attachments ------------------------------------------------------------
    async fn insert_attachment(&self, attachment: &Attachment, note_id: &str) -> RepoResult<()>;
    /// Returns (note_id, attachment) when it exists.
    async fn attachment_info(
        &self,
        attachment_id: &str,
    ) -> RepoResult<Option<(String, Attachment)>>;
    async fn delete_attachment(&self, attachment_id: &str) -> RepoResult<bool>;

    // -- per-user settings --------------------------------------------------------
    /// Opaque JSON blob owned by the client (theme, date format, palette…).
    async fn settings_for_user(&self, user_id: &str) -> RepoResult<Option<String>>;
    async fn put_settings(&self, user_id: &str, data: &str) -> RepoResult<()>;

    // -- server metadata ----------------------------------------------------------
    /// Small server-owned key/value store (e.g. the file-URL signing secret).
    async fn meta_get(&self, key: &str) -> RepoResult<Option<String>>;
    async fn meta_set(&self, key: &str, value: &str) -> RepoResult<()>;
}
