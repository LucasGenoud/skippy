pub mod sqlite;
mod sqlite_attachments;
mod sqlite_history;
mod sqlite_infrastructure;
mod sqlite_rows;
mod sqlite_schema;
mod sqlite_sharing;
mod sqlite_views;

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
