pub mod sqlite;

use async_trait::async_trait;

use crate::models::*;

#[derive(Debug)]
pub enum RepoError {
    /// Unique-constraint style conflicts (duplicate username, id, label name).
    Conflict(String),
    Other(anyhow::Error),
}

impl<E: Into<anyhow::Error>> From<E> for RepoError {
    fn from(e: E) -> Self {
        RepoError::Other(e.into())
    }
}

pub type RepoResult<T> = Result<T, RepoError>;

/// Storage boundary for the whole app. Handlers only talk to this trait, so
/// swapping SQLite for Postgres (or anything else) means implementing this
/// trait and changing one line of wiring in `main`.
#[async_trait]
pub trait Repository: Send + Sync {
    // -- users & sessions ---------------------------------------------------
    async fn create_user(&self, user: &User) -> RepoResult<()>;
    async fn user_by_username(&self, username: &str) -> RepoResult<Option<User>>;
    async fn user_by_id(&self, id: &str) -> RepoResult<Option<User>>;
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
    async fn purge_trash_before(&self, cutoff: &str) -> RepoResult<Vec<String>>;
    /// Every note id in the store (used for search reindexing at startup).
    async fn all_note_ids(&self) -> RepoResult<Vec<String>>;
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
    async fn rename_label(&self, user_id: &str, label_id: &str, name: &str) -> RepoResult<bool>;
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
    async fn attachment_info(&self, attachment_id: &str)
        -> RepoResult<Option<(String, Attachment)>>;
    async fn delete_attachment(&self, attachment_id: &str) -> RepoResult<bool>;

    // -- per-user settings --------------------------------------------------------
    /// Opaque JSON blob owned by the client (theme, date format, palette…).
    async fn settings_for_user(&self, user_id: &str) -> RepoResult<Option<String>>;
    async fn put_settings(&self, user_id: &str, data: &str) -> RepoResult<()>;
}
