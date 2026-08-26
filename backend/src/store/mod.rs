pub mod sqlite;
mod sqlite_attachments;
mod sqlite_history;
mod sqlite_infrastructure;
mod sqlite_rows;
mod sqlite_schema;
mod sqlite_sharing;
mod sqlite_views;

use std::collections::HashMap;

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

/// External state that must be reconciled after a relational transaction.
/// Jobs are inserted in the same SQLite transaction as the row deletion, so a
/// process crash can delay cleanup but cannot lose the intent to perform it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CleanupKind {
    AttachmentBlob,
    NoteVector,
    WorkspaceVectors,
}

impl CleanupKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AttachmentBlob => "attachment_blob",
            Self::NoteVector => "note_vector",
            Self::WorkspaceVectors => "workspace_vectors",
        }
    }

    pub fn parse(value: &str) -> anyhow::Result<Self> {
        match value {
            "attachment_blob" => Ok(Self::AttachmentBlob),
            "note_vector" => Ok(Self::NoteVector),
            "workspace_vectors" => Ok(Self::WorkspaceVectors),
            _ => anyhow::bail!("unknown cleanup job kind '{value}'"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct CleanupJob {
    pub id: i64,
    pub kind: CleanupKind,
    pub target_id: String,
    pub attempts: u32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CleanupStats {
    pub pending: u64,
    pub failed: u64,
}

/// A note removed by a trash purge. External cleanup is already durably queued
/// before this result is returned.
pub struct PurgedNote {
    pub note_id: String,
}

/// Everything outside the relational database that must be refreshed after an
/// account is removed.
pub struct DeletedAccount {
    /// Accounts whose open clients need to refetch workspace/note rosters.
    pub audience: Vec<String>,
}

/// Result of permanently deleting a workspace and every note it contains.
/// Attachment and vector cleanup is durably queued before the transaction
/// commits; callers only need the audience for live-client invalidation.
pub struct DeletedWorkspace {
    /// Former roster members and direct note collaborators whose open clients
    /// need to refetch after the workspace and notes disappear.
    pub audience: Vec<String>,
}

/// An outstanding password reset grant, looked up by the token in the link.
pub struct PasswordReset {
    pub user_id: String,
    /// RFC3339 instant after which the grant no longer counts. Freshness is
    /// judged by the caller so the store stays free of clock policy.
    pub expires_at: String,
}

/// Account identities and durable sessions.
#[async_trait]
pub trait AccountRepository: Send + Sync {
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
    /// Permanently remove an account in one transaction. Its workspaces and
    /// every note they own are deleted. Notes created by the account in other
    /// users' workspaces survive with creator attribution cleared.
    async fn delete_account(&self, user_id: &str) -> RepoResult<Option<DeletedAccount>>;
    async fn create_session(&self, token: &str, user_id: &str) -> RepoResult<()>;
    async fn user_id_for_token(&self, token: &str) -> RepoResult<Option<String>>;
    async fn delete_session(&self, token: &str) -> RepoResult<()>;
    /// Drop every session an account holds. A password reset ends the old
    /// sessions along with the old password: whoever needed the reset should
    /// not stay signed in on a device they may have lost control of.
    async fn delete_sessions_for_user(&self, user_id: &str) -> RepoResult<()>;
    /// Record a reset grant, replacing any outstanding one for the account so
    /// only the newest link in someone's inbox works.
    async fn create_password_reset(
        &self,
        token: &str,
        user_id: &str,
        expires_at: &str,
    ) -> RepoResult<()>;
    /// Redeem a grant: the row is removed whether or not it had expired, so a
    /// link is good for exactly one attempt.
    async fn consume_password_reset(&self, token: &str) -> RepoResult<Option<PasswordReset>>;
}

/// Workspace lifecycle, membership, and roster views.
#[async_trait]
pub trait WorkspaceRepository: Send + Sync {
    /// Every workspace the user owns or has been invited to, default first.
    async fn workspaces_for_user(&self, user_id: &str) -> RepoResult<Vec<WorkspaceView>>;
    async fn workspace(&self, workspace_id: &str) -> RepoResult<Option<Workspace>>;
    /// The workspace created with the account. Every user has exactly one, and
    /// it is where notes land when no workspace is named.
    async fn default_workspace(&self, user_id: &str) -> RepoResult<Option<Workspace>>;
    async fn insert_workspace(&self, workspace: &Workspace) -> RepoResult<()>;
    async fn update_workspace(&self, workspace: &Workspace) -> RepoResult<bool>;
    /// Permanently delete a non-default workspace and every note it contains.
    /// Versions, shares, attachment metadata, labels, stages, and membership
    /// cascade with it; external cleanup is queued in the same transaction.
    /// `None` means the workspace doesn't exist or is the default.
    async fn delete_workspace(&self, workspace_id: &str) -> RepoResult<Option<DeletedWorkspace>>;
    /// The workspace's owner plus everyone invited to it.
    async fn workspace_member_ids(&self, workspace_id: &str) -> RepoResult<Vec<String>>;
    async fn is_workspace_member(&self, workspace_id: &str, user_id: &str) -> RepoResult<bool>;
    async fn add_workspace_member(&self, workspace_id: &str, user_id: &str) -> RepoResult<()>;
    /// Atomically remove a member. Workspace-owned notes stay in place.
    async fn remove_workspace_member(&self, workspace_id: &str, user_id: &str) -> RepoResult<bool>;
}

/// Notes, reminders, and version history.
#[async_trait]
pub trait NoteRepository: Send + Sync {
    /// Every note the user can see through workspace membership or a direct
    /// share, decorated for that user.
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
    /// Hard-delete trashed notes older than `cutoff`. Blob and vector cleanup
    /// is durably queued in the same transaction.
    async fn purge_trash_before(&self, cutoff: &str) -> RepoResult<Vec<PurgedNote>>;
    /// Every note id in the store (used for search reindexing at startup).
    async fn all_note_ids(&self) -> RepoResult<Vec<String>>;

    // -- reminders ------------------------------------------------------------
    /// Non-trashed notes whose reminder is due at or before `now` (RFC3339)
    /// and hasn't fired yet. Timestamps are compared as instants, so offsets
    /// other than UTC still come due at the right moment.
    async fn due_reminders(&self, now: &str) -> RepoResult<Vec<NoteRecord>>;
    /// Atomically claim a one-shot reminder for delivery. The expected due
    /// time makes overlapping sweeps harmless: exactly one can claim it.
    async fn mark_reminder_fired(
        &self,
        note_id: &str,
        reminder_at: &str,
        fired_at: &str,
    ) -> RepoResult<bool>;
    /// Atomically advance a recurring reminder after claiming the due
    /// occurrence. The next alarm remains live instead of carrying a fired
    /// mark, and the changed timestamp lets connected clients re-arm it.
    async fn advance_recurring_reminder(
        &self,
        note_id: &str,
        reminder_at: &str,
        next_reminder_at: &str,
        advanced_at: &str,
    ) -> RepoResult<bool>;

    // -- checklist item reminders --------------------------------------------
    /// A note's item reminders. Ordered by item id so a view is stable.
    async fn item_reminders(&self, note_id: &str) -> RepoResult<Vec<ItemReminder>>;
    /// Item reminders for several notes at once, keyed by note id. Used to
    /// decorate note views without one query per note.
    async fn item_reminders_for_notes(
        &self,
        note_ids: &[String],
    ) -> RepoResult<HashMap<String, Vec<ItemReminder>>>;
    /// Create or replace one item's reminder. Rescheduling clears the fired
    /// mark, so the new time is delivered like any other new alarm.
    async fn set_item_reminder(&self, note_id: &str, reminder: &ItemReminder) -> RepoResult<()>;
    /// Remove one item's reminder. Idempotent.
    async fn clear_item_reminder(&self, note_id: &str, item_id: &str) -> RepoResult<()>;
    /// Item reminders due at or before `now` that have not fired, each with
    /// the note holding it. Trashed notes are skipped, matching the note-level
    /// sweep.
    async fn due_item_reminders(&self, now: &str) -> RepoResult<Vec<DueItemReminder>>;
    /// Atomically claim a one-shot item reminder for delivery, the item-level
    /// counterpart of [`NoteRepository::mark_reminder_fired`].
    async fn mark_item_reminder_fired(
        &self,
        note_id: &str,
        item_id: &str,
        reminder_at: &str,
        fired_at: &str,
    ) -> RepoResult<bool>;
    /// Atomically advance a recurring item reminder to its next occurrence.
    async fn advance_recurring_item_reminder(
        &self,
        note_id: &str,
        item_id: &str,
        reminder_at: &str,
        next_reminder_at: &str,
    ) -> RepoResult<bool>;

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
    /// `Some`) its transcript text. Server-owned, the transcription pipeline
    /// is the only writer. Bumps `updated_at` so viewers refetch.
    async fn set_transcript(
        &self,
        note_id: &str,
        status: &str,
        content: Option<&str>,
    ) -> RepoResult<()>;
}

/// Direct collaboration and public-link capabilities.
#[async_trait]
pub trait SharingRepository: Send + Sync {
    /// Everyone who can see the note: direct collaborators and every member
    /// of the workspace that owns it.
    async fn participant_ids(&self, note_id: &str) -> RepoResult<Vec<String>>;
    async fn is_participant(&self, note_id: &str, user_id: &str) -> RepoResult<bool>;
    async fn add_collaborator(&self, note_id: &str, user_id: &str) -> RepoResult<()>;
    async fn remove_collaborator(&self, note_id: &str, user_id: &str) -> RepoResult<bool>;

    // -- public share links ----------------------------------------------------
    async fn insert_share_link(&self, link: &ShareLink) -> RepoResult<()>;
    /// Resolve a link by its token. Expiry is the caller's business: the
    /// storage layer has no clock of its own.
    async fn share_link(&self, token: &str) -> RepoResult<Option<ShareLink>>;
    async fn share_links_for_user(&self, user_id: &str) -> RepoResult<Vec<ShareLink>>;
    /// An existing link for the same thing, so publishing twice hands back one
    /// URL instead of quietly minting a second one the user cannot see.
    async fn share_link_for_target(
        &self,
        user_id: &str,
        target: &str,
        note_id: Option<&str>,
        workspace_id: Option<&str>,
        label_id: Option<&str>,
    ) -> RepoResult<Option<ShareLink>>;
    /// Revoke. Scoped to the owner, so a token alone cannot delete a link.
    async fn delete_share_link(&self, user_id: &str, token: &str) -> RepoResult<bool>;
}

/// Workspace labels and board stages. Their APIs remain deliberately
/// separate even though they share this storage capability boundary.
#[async_trait]
pub trait TaxonomyRepository: Send + Sync {
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
    /// Delete a stage, first sending the notes it held back to unassigned,
    /// removing a column never removes notes.
    async fn delete_stage(&self, user_id: &str, stage_id: &str) -> RepoResult<bool>;
    /// Where a newly created column goes: to the right of the existing ones.
    async fn max_stage_position(&self, workspace_id: &str) -> RepoResult<f64>;
    /// Clear a note's stage when the stage does not belong to the note's
    /// workspace, after a move, or when a stray id was patched in. The
    /// single-stage counterpart of [`Repository::prune_foreign_labels`], and
    /// the reason a foreign stage id can never stick.
    async fn prune_foreign_stage(&self, note_id: &str) -> RepoResult<()>;
}

/// Note-scoped checklist suggestion history.
#[async_trait]
pub trait HistoryRepository: Send + Sync {
    /// Remember item texts checked off in a note (upsert, bump use count).
    /// Scoped per note: suggestions never leak from one note to another.
    async fn record_checked_items(&self, note_id: &str, texts: &[String]) -> RepoResult<()>;
    /// Entries for every note the user can access, ranked by frequency then
    /// recency; the client filters per note as the user types.
    async fn checklist_history(&self, user_id: &str) -> RepoResult<Vec<HistoryEntry>>;
}

/// Relational attachment metadata. Blob bytes remain behind `FileStore`.
#[async_trait]
pub trait AttachmentRepository: Send + Sync {
    async fn insert_attachment(&self, attachment: &Attachment, note_id: &str) -> RepoResult<()>;
    /// Returns (note_id, attachment) when it exists.
    async fn attachment_info(
        &self,
        attachment_id: &str,
    ) -> RepoResult<Option<(String, Attachment)>>;
    async fn delete_attachment(&self, attachment_id: &str) -> RepoResult<bool>;

    // -- recognized image text -------------------------------------------------
    /// Record what an OCR service read out of an image. Empty text is a real
    /// result (a picture with no words in it) and still counts as read, so the
    /// backlog pass leaves it alone from then on.
    async fn set_attachment_ocr(&self, attachment_id: &str, text: &str) -> RepoResult<()>;
    /// Text recognized in a note's images, oldest attachment first. Feeds the
    /// note's embedding so a picture is findable by what it says.
    async fn note_ocr_text(&self, note_id: &str) -> RepoResult<Vec<String>>;
    /// Image attachments with no recognized text stored yet, oldest first.
    /// Covers pictures uploaded while OCR was disabled, down, or interrupted
    /// mid-recognition. Filtered loosely to `image/*` here; which formats are
    /// actually worth reading is the OCR module's policy, so the caller
    /// narrows further and `limit` bounds one pass, not the whole backlog.
    async fn attachments_awaiting_ocr(&self, limit: u32) -> RepoResult<Vec<OcrJob>>;
}

/// Per-user settings, server metadata, and durable maintenance jobs.
#[async_trait]
pub trait InfrastructureRepository: Send + Sync {
    /// Opaque JSON blob owned by the client (theme, date format, palette…).
    async fn settings_for_user(&self, user_id: &str) -> RepoResult<Option<String>>;
    async fn put_settings(&self, user_id: &str, data: &str) -> RepoResult<()>;

    // -- server metadata ----------------------------------------------------------
    /// Small server-owned key/value store (e.g. the file-URL signing secret).
    async fn meta_get(&self, key: &str) -> RepoResult<Option<String>>;
    async fn meta_set(&self, key: &str, value: &str) -> RepoResult<()>;

    // -- durable external cleanup ---------------------------------------------
    async fn enqueue_cleanup(&self, kind: CleanupKind, target_id: &str) -> RepoResult<()>;
    async fn due_cleanup_jobs(&self, now: i64, limit: u32) -> RepoResult<Vec<CleanupJob>>;
    async fn complete_cleanup_job(&self, job_id: i64) -> RepoResult<()>;
    async fn retry_cleanup_job(
        &self,
        job_id: i64,
        error: &str,
        next_attempt_at: i64,
    ) -> RepoResult<()>;
    async fn cleanup_stats(&self) -> RepoResult<CleanupStats>;
}

/// Complete persistence boundary used by application wiring. Domain traits
/// keep handlers and implementations auditable without forcing callers to
/// carry eight separate trait objects.
pub trait Repository:
    AccountRepository
    + WorkspaceRepository
    + NoteRepository
    + SharingRepository
    + TaxonomyRepository
    + HistoryRepository
    + AttachmentRepository
    + InfrastructureRepository
{
}

impl<T> Repository for T where
    T: AccountRepository
        + WorkspaceRepository
        + NoteRepository
        + SharingRepository
        + TaxonomyRepository
        + HistoryRepository
        + AttachmentRepository
        + InfrastructureRepository
{
}
