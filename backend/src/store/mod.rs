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

/// Result of deleting a workspace container. Notes outlive the workspace and
/// are moved to their respective owners' default workspaces; callers use the
/// ids to refresh visibility-dependent state such as the semantic index.
pub struct DeletedWorkspace {
    pub moved_note_ids: Vec<String>,
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
    /// The account owner plus everyone who shares at least one note or
    /// workspace with them. Used to refresh public display names after a
    /// profile change.
    async fn account_audience(&self, user_id: &str) -> RepoResult<Vec<String>>;
    async fn create_session(&self, token: &str, user_id: &str) -> RepoResult<()>;
    async fn user_id_for_token(&self, token: &str) -> RepoResult<Option<String>>;
    async fn delete_session(&self, token: &str) -> RepoResult<()>;

    // -- workspaces -----------------------------------------------------------
    /// Every workspace the user owns or has been invited to, default first.
    async fn workspaces_for_user(&self, user_id: &str) -> RepoResult<Vec<WorkspaceView>>;
    async fn workspace(&self, workspace_id: &str) -> RepoResult<Option<Workspace>>;
    /// The workspace created with the account. Every user has exactly one, and
    /// it is where notes land when no workspace is named.
    async fn default_workspace(&self, user_id: &str) -> RepoResult<Option<Workspace>>;
    async fn insert_workspace(&self, workspace: &Workspace) -> RepoResult<()>;
    async fn rename_workspace(&self, workspace_id: &str, name: &str) -> RepoResult<bool>;
    /// Delete a non-default workspace after moving every note it held to that
    /// note owner's default workspace. Workspace labels and stages disappear,
    /// so moved notes lose both; content, versions, shares, and attachments
    /// survive. `None` means the workspace doesn't exist or is the default.
    async fn delete_workspace(&self, workspace_id: &str) -> RepoResult<Option<DeletedWorkspace>>;
    /// The workspace's owner plus everyone invited to it.
    async fn workspace_member_ids(&self, workspace_id: &str) -> RepoResult<Vec<String>>;
    async fn is_workspace_member(&self, workspace_id: &str, user_id: &str) -> RepoResult<bool>;
    async fn add_workspace_member(&self, workspace_id: &str, user_id: &str) -> RepoResult<()>;
    /// Atomically remove a member and move every note they own in that
    /// workspace back to their default workspace. `None` means they were not
    /// a member; `Some` carries the moved ids for visibility reindexing.
    async fn remove_workspace_member(
        &self,
        workspace_id: &str,
        user_id: &str,
    ) -> RepoResult<Option<Vec<String>>>;

    // -- notes ---------------------------------------------------------------
    /// Every note the user can see — owned, shared with them directly, or held
    /// by a workspace they belong to — decorated for that user.
    async fn notes_for_user(&self, user_id: &str) -> RepoResult<Vec<NoteView>>;
    async fn note_view(&self, note_id: &str, viewer_id: &str) -> RepoResult<Option<NoteView>>;
    /// One note only when `user_id` can currently see it. Use this at request
    /// authorization boundaries; [`Repository::note_record`] is for trusted
    /// background work that deliberately operates without a viewer.
    async fn note_record_for_user(
        &self,
        note_id: &str,
        user_id: &str,
    ) -> RepoResult<Option<NoteRecord>>;
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
    /// Everyone who can see the note: its owner, its direct collaborators, and
    /// every member of the workspace holding it.
    async fn participant_ids(&self, note_id: &str) -> RepoResult<Vec<String>>;
    async fn is_participant(&self, note_id: &str, user_id: &str) -> RepoResult<bool>;
    async fn add_collaborator(&self, note_id: &str, user_id: &str) -> RepoResult<()>;
    async fn remove_collaborator(&self, note_id: &str, user_id: &str) -> RepoResult<bool>;

    // -- labels ---------------------------------------------------------------
    /// Every label in every workspace the user belongs to. Labels are a shared
    /// workspace taxonomy, so members all see the same set.
    async fn labels_for_user(&self, user_id: &str) -> RepoResult<Vec<Label>>;
    async fn insert_label(&self, label: &Label) -> RepoResult<()>;
    async fn update_label(
        &self,
        user_id: &str,
        label_id: &str,
        name: &str,
        color: Option<&str>,
        icon: Option<&str>,
        position: Option<f64>,
    ) -> RepoResult<bool>;
    async fn delete_label(&self, user_id: &str, label_id: &str) -> RepoResult<bool>;
    /// Where a newly created label goes: to the end of the sidebar list.
    async fn max_label_position(&self, workspace_id: &str) -> RepoResult<f64>;
    /// Replace a note's labels. Only labels from the note's own workspace are
    /// accepted, so a move or a stray id can never attach a foreign label.
    async fn set_note_labels(&self, note_id: &str, label_ids: &[String]) -> RepoResult<()>;
    /// Drop labels that no longer belong to the note's workspace, after the
    /// note has been moved.
    async fn prune_foreign_labels(&self, note_id: &str) -> RepoResult<()>;

    // -- stages (board columns) ------------------------------------------------
    /// Every stage in every workspace the user belongs to, board order first.
    /// Stages are shared workspace state like labels, but an entirely separate
    /// system: nothing here reads or writes labels.
    async fn stages_for_user(&self, user_id: &str) -> RepoResult<Vec<Stage>>;
    async fn insert_stage(&self, stage: &Stage) -> RepoResult<()>;
    async fn update_stage(
        &self,
        user_id: &str,
        stage_id: &str,
        name: &str,
        color: Option<&str>,
        position: Option<f64>,
    ) -> RepoResult<bool>;
    /// Delete a stage, first sending the notes it held back to unassigned —
    /// removing a column never removes notes.
    async fn delete_stage(&self, user_id: &str, stage_id: &str) -> RepoResult<bool>;
    /// Where a newly created column goes: to the right of the existing ones.
    async fn max_stage_position(&self, workspace_id: &str) -> RepoResult<f64>;
    /// Clear a note's stage when the stage does not belong to the note's
    /// workspace — after a move, or when a stray id was patched in. The
    /// single-stage counterpart of [`Repository::prune_foreign_labels`], and
    /// the reason a foreign stage id can never stick.
    async fn prune_foreign_stage(&self, note_id: &str) -> RepoResult<()>;

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
