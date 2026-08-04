use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Users & auth

#[derive(Debug, Clone, Serialize)]
pub struct UserPublic {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct AccountPublic {
    pub id: String,
    pub name: String,
    pub email: String,
}

#[derive(Debug, Clone)]
pub struct User {
    pub id: String,
    pub name: String,
    pub email: String,
    pub password_hash: String,
}

impl User {
    pub fn public(&self) -> UserPublic {
        UserPublic {
            id: self.id.clone(),
            name: self.name.clone(),
        }
    }

    pub fn account(&self) -> AccountPublic {
        AccountPublic {
            id: self.id.clone(),
            name: self.name.clone(),
            email: self.email.clone(),
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct RegisterRequest {
    pub name: String,
    pub email: String,
    pub password: String,
}

#[derive(Debug, Deserialize)]
pub struct LoginRequest {
    pub email: String,
    pub password: String,
}

#[derive(Debug, Deserialize)]
pub struct UpdateAccountRequest {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub current_password: Option<String>,
    #[serde(default)]
    pub new_password: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct DeleteAccountRequest {
    pub current_password: String,
}

#[derive(Debug, Serialize)]
pub struct AuthResponse {
    pub token: String,
    pub user: AccountPublic,
}

// ---------------------------------------------------------------------------
// Workspaces

/// Name given to the workspace every account starts with.
pub const DEFAULT_WORKSPACE_NAME: &str = "My notes";

/// A container for notes and labels. Every user gets one default workspace at
/// registration and may create more. Membership is per workspace: a member
/// sees every note it holds, and its labels are a taxonomy shared by everyone
/// in it.
#[derive(Debug, Clone)]
pub struct Workspace {
    pub id: String,
    pub owner_id: String,
    pub name: String,
    /// Whether the ordinary grid/list entry point is shown for this
    /// workspace. At least one of this and `board_enabled` is always true.
    pub notes_enabled: bool,
    /// Whether the kanban board entry point is shown for this workspace.
    pub board_enabled: bool,
    /// The workspace created with the account. It cannot be deleted or left,
    /// so a user always has somewhere for their notes to live.
    pub is_default: bool,
    pub created_at: String,
}

/// A workspace as served to one of its members, with the roster resolved to
/// display names.
#[derive(Debug, Clone, Serialize)]
pub struct WorkspaceView {
    pub id: String,
    pub name: String,
    pub notes_enabled: bool,
    pub board_enabled: bool,
    pub owner: UserPublic,
    /// Everyone invited to the workspace, excluding the owner.
    pub members: Vec<UserPublic>,
    pub is_default: bool,
    pub created_at: String,
}

#[derive(Debug, Deserialize)]
pub struct CreateWorkspace {
    /// Client-generated id, so the optimistic UI can switch to a new workspace
    /// before the request round-trips. Server generates one when absent.
    #[serde(default)]
    pub id: Option<String>,
    pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct UpdateWorkspace {
    pub name: Option<String>,
    pub notes_enabled: Option<bool>,
    pub board_enabled: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct AddMember {
    pub email: String,
}

// ---------------------------------------------------------------------------
// Notes

pub const KIND_TEXT: &str = "text";
pub const KIND_CHECKLIST: &str = "checklist";
pub const KIND_MARKDOWN: &str = "markdown";
pub const KIND_AUDIO: &str = "audio";

/// Transcription lifecycle for an audio note. Non-audio notes are always
/// `none`. The server owns every transition (client never patches it).
pub const TRANSCRIPT_NONE: &str = "none";
pub const TRANSCRIPT_PENDING: &str = "pending";
pub const TRANSCRIPT_DONE: &str = "done";
pub const TRANSCRIPT_FAILED: &str = "failed";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ChecklistItem {
    pub id: String,
    pub text: String,
    pub done: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct Attachment {
    pub id: String,
    pub mime: String,
    pub filename: String,
    pub size: i64,
    /// Signed, time-limited relative URL for fetching the bytes
    /// (`/api/files/{id}?exp=..&sig=..`). Filled in by the handler layer when a
    /// note is served; `None` in the storage layer, which knows no signing key.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

/// A note as stored, without the per-viewer decorations.
#[derive(Debug, Clone)]
pub struct NoteRecord {
    pub id: String,
    /// The workspace owns the note and controls its lifecycle. Everyone in
    /// that workspace can see and edit it; per-note collaborators are an
    /// additional, narrower grant.
    pub workspace_id: String,
    /// Creator attribution only. It is nullable so a note in somebody else's
    /// workspace survives when its creator deletes their account.
    pub created_by: Option<String>,
    pub kind: String,
    pub title: String,
    pub content: String,
    pub items: Vec<ChecklistItem>,
    pub color: String,
    pub pinned: bool,
    pub archived: bool,
    pub trashed: bool,
    pub position: f64,
    pub reminder_at: Option<String>,
    /// Optional cadence for a reminder (`daily`, `weekly`, `monthly`, or
    /// `yearly`). A missing cadence keeps the existing one-shot behaviour.
    pub reminder_repeat: Option<String>,
    /// When the reminder scheduler last delivered `reminder_at` (server-owned,
    /// not on the wire). `None` means "not fired yet"; cleared whenever the
    /// reminder is rescheduled so the new time fires again.
    pub reminder_fired_at: Option<String>,
    /// Audio-note transcription state (`none`/`pending`/`done`/`failed`).
    pub transcript_status: String,
    pub created_at: String,
    pub updated_at: String,
    /// Who last edited the note's content. Drives version-history coalescing
    /// (edits by the same author in one sitting collapse to a single version)
    /// and starts out `None` until the first edit. Not exposed on the wire.
    pub last_editor_id: Option<String>,
    /// The board stage holding this note, or `None` for unassigned. Stages are
    /// deliberately independent of labels: a note has at most one stage, and
    /// the storage layer keeps it inside the note's own workspace.
    pub stage_id: Option<String>,
    /// Order within the note's stage. Separate from `position` so arranging a
    /// board never reshuffles the grid's custom order, and vice versa.
    pub stage_position: f64,
}

/// A note as served to a specific user: the labels they can see, plus the
/// sharing roster.
#[derive(Debug, Clone, Serialize)]
pub struct NoteView {
    #[serde(flatten)]
    pub note: NoteFields,
    /// Labels belong to the note's workspace, so its members all see the same
    /// set. A user who reached the note through a per-note share is not in that
    /// workspace and sees none of them.
    pub label_ids: Vec<String>,
    pub owner: UserPublic,
    pub collaborators: Vec<UserPublic>,
    pub attachments: Vec<Attachment>,
}

#[derive(Debug, Clone, Serialize)]
pub struct NoteFields {
    pub id: String,
    pub workspace_id: String,
    pub kind: String,
    pub title: String,
    pub content: String,
    pub items: Vec<ChecklistItem>,
    pub color: String,
    pub pinned: bool,
    pub archived: bool,
    pub trashed: bool,
    pub position: f64,
    pub reminder_at: Option<String>,
    pub reminder_repeat: Option<String>,
    pub transcript_status: String,
    pub created_at: String,
    pub updated_at: String,
    pub stage_id: Option<String>,
    pub stage_position: f64,
}

impl NoteRecord {
    pub fn fields(&self) -> NoteFields {
        NoteFields {
            id: self.id.clone(),
            workspace_id: self.workspace_id.clone(),
            kind: self.kind.clone(),
            title: self.title.clone(),
            content: self.content.clone(),
            items: self.items.clone(),
            color: self.color.clone(),
            pinned: self.pinned,
            archived: self.archived,
            trashed: self.trashed,
            position: self.position,
            reminder_at: self.reminder_at.clone(),
            reminder_repeat: self.reminder_repeat.clone(),
            transcript_status: self.transcript_status.clone(),
            created_at: self.created_at.clone(),
            updated_at: self.updated_at.clone(),
            stage_id: self.stage_id.clone(),
            stage_position: self.stage_position,
        }
    }
}

/// A past state of a note's content, kept for the version-history timeline.
/// Only content fields are versioned, organizational state (color, pin,
/// archive, labels, position) is not "content you'd want to roll back".
#[derive(Debug, Clone, Serialize)]
pub struct NoteVersion {
    pub id: String,
    pub note_id: String,
    pub kind: String,
    pub title: String,
    pub content: String,
    pub items: Vec<ChecklistItem>,
    /// User id that authored this state (`None` for the very first / legacy
    /// snapshot, which the handler attributes to the owner).
    pub edited_by: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Label {
    pub id: String,
    /// Labels belong to a workspace, not a user: every member shares the same
    /// taxonomy, and a label applied to a note is visible to all of them.
    pub workspace_id: String,
    pub name: String,
    /// Hex colour (`#RRGGBB`) for the label's chip/dot, or `None` for the
    /// theme default. Purely presentational, the server never interprets it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// Stable key into the client's curated icon set (e.g. `"work"`), or
    /// `None` for the default label glyph.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    /// Order in the sidebar's label list. Same sparse-position trick as
    /// [`Stage::position`].
    pub position: f64,
}

/// A board column. Stages are workspace state like labels, every member sees
/// and uses the same set, but they are a separate system on purpose: a note
/// carries any number of labels and at most one stage, so the exclusivity a
/// board needs is a schema fact rather than a rule the client has to maintain.
/// Nothing here references labels, and nothing in labels references stages.
#[derive(Debug, Clone, Serialize)]
pub struct Stage {
    pub id: String,
    pub workspace_id: String,
    pub name: String,
    /// Hex colour (`#RRGGBB`) for the column header, or `None` for the theme
    /// default. Purely presentational, the server never interprets it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// Left-to-right order of the column on the board.
    pub position: f64,
}

// ---------------------------------------------------------------------------
// Public share links

/// What a public link exposes. A link points at exactly one of these.
pub const SHARE_TARGET_NOTE: &str = "note";
/// A workspace's grid: its live notes, the way the owner sees them.
pub const SHARE_TARGET_NOTES: &str = "notes";
/// A workspace's board, columns included.
pub const SHARE_TARGET_BOARD: &str = "board";
/// One label's notes, across the workspace holding that label.
pub const SHARE_TARGET_LABEL: &str = "label";

pub const SHARE_TARGETS: &[&str] = &[
    SHARE_TARGET_NOTE,
    SHARE_TARGET_NOTES,
    SHARE_TARGET_BOARD,
    SHARE_TARGET_LABEL,
];

/// A read-only link handed out to people without an account.
///
/// The stored token is a random public identifier. HTTP responses append an
/// HMAC before exposing it as a bearer capability, so the stored row value is
/// not itself a working public URL. The identifier remains stored because a
/// share must be revocable and listable.
#[derive(Debug, Clone)]
pub struct ShareLink {
    pub token: String,
    /// Who published it. Only they can revoke it, and the public payload is
    /// assembled from what *they* can see.
    pub created_by: String,
    /// One of [`SHARE_TARGETS`].
    pub target: String,
    pub note_id: Option<String>,
    pub workspace_id: Option<String>,
    pub label_id: Option<String>,
    pub created_at: String,
    /// RFC3339 instant after which the link stops resolving, or `None` for a
    /// link that lasts until it is revoked.
    pub expires_at: Option<String>,
}

/// A share link as listed for its owner, with the target named so the manage
/// screen can label the row without resolving ids itself.
#[derive(Debug, Clone, Serialize)]
pub struct ShareLinkView {
    pub token: String,
    pub target: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label_id: Option<String>,
    /// What the link is called in the UI: the note's title, the workspace's
    /// name, or the label's name.
    pub title: String,
    pub created_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CreateShareLink {
    /// One of [`SHARE_TARGETS`].
    pub target: String,
    #[serde(default)]
    pub note_id: Option<String>,
    #[serde(default)]
    pub workspace_id: Option<String>,
    #[serde(default)]
    pub label_id: Option<String>,
    /// RFC3339. Absent means the link lasts until it is revoked.
    #[serde(default)]
    pub expires_at: Option<String>,
}

/// A note as served to an anonymous reader.
///
/// Deliberately its own struct rather than a trimmed [`NoteView`]: everything
/// public is listed here, so adding a field to the private note model can
/// never widen a public page by accident. Absent on purpose are the owner and
/// collaborator identities, reminders (someone's schedule is not part of
/// reading a note), archive/trash state, and the transcription status.
#[derive(Debug, Clone, Serialize)]
pub struct PublicNote {
    pub id: String,
    pub kind: String,
    pub title: String,
    pub content: String,
    pub items: Vec<ChecklistItem>,
    pub color: String,
    pub pinned: bool,
    pub position: f64,
    pub label_ids: Vec<String>,
    pub stage_id: Option<String>,
    pub stage_position: f64,
    pub created_at: String,
    pub updated_at: String,
    /// Signed, time-limited URLs, the same ones a signed-in reader gets.
    pub attachments: Vec<Attachment>,
}

/// The whole payload behind a public link.
#[derive(Debug, Clone, Serialize)]
pub struct PublicShare {
    /// One of [`SHARE_TARGETS`], so the reader can render a note, a grid, or a
    /// board.
    pub target: String,
    pub title: String,
    /// Display name of whoever published the link. No id, no email.
    pub shared_by: String,
    pub notes: Vec<PublicNote>,
    /// Labels the payload's notes reference, so chips can be drawn.
    pub labels: Vec<Label>,
    /// Board columns; empty unless the target is a board.
    pub stages: Vec<Stage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
}

/// A checklist item text previously checked off in a note; powers typing
/// suggestions ("Mi…" -> "Milk") in that note's checklist rows. Scoped per
/// note, suggestions never leak from one note to another.
#[derive(Debug, Clone, Serialize)]
pub struct HistoryEntry {
    pub note_id: String,
    pub text: String,
    pub uses: i64,
}

// ---------------------------------------------------------------------------
// Request payloads

#[derive(Debug, Deserialize, Default)]
pub struct CreateNote {
    /// Client-generated id, so optimistic UIs can create notes before the
    /// request round-trips. Server generates one when absent.
    #[serde(default)]
    pub id: Option<String>,
    /// Which workspace to file the note in. Absent means the caller's default
    /// workspace, the API's deliberate default, relied on by the chat write
    /// path and by any caller that has no workspace in hand.
    #[serde(default)]
    pub workspace_id: Option<String>,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub content: String,
    #[serde(default)]
    pub items: Option<Vec<ChecklistItem>>,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub pinned: Option<bool>,
    #[serde(default)]
    pub archived: Option<bool>,
    /// Accepted for backup restore. Ordinary creates omit it and start live.
    #[serde(default)]
    pub trashed: Option<bool>,
    #[serde(default)]
    pub position: Option<f64>,
    #[serde(default)]
    pub reminder_at: Option<String>,
    #[serde(default)]
    pub reminder_repeat: Option<String>,
    #[serde(default)]
    pub label_ids: Option<Vec<String>>,
    /// Board stage to file the note in. Absent or null means unassigned; a
    /// stage from another workspace is dropped, the same way a foreign label
    /// is.
    #[serde(default)]
    pub stage_id: Option<String>,
    /// Defaults to `position`, so a note starts out ordered the same way on
    /// the board as it is in the grid.
    #[serde(default)]
    pub stage_position: Option<f64>,
    #[serde(default)]
    pub created_at: Option<String>,
    #[serde(default)]
    pub updated_at: Option<String>,
}

/// Partial update: only fields present in the JSON body are applied.
/// `reminder_at` uses a nested Option so `"reminder_at": null` clears it
/// while an absent key leaves it untouched.
#[derive(Debug, Deserialize, Default)]
pub struct UpdateNote {
    /// Moves the note to another workspace (owner only, and only into a
    /// workspace they belong to).
    pub workspace_id: Option<String>,
    pub kind: Option<String>,
    pub title: Option<String>,
    pub content: Option<String>,
    pub items: Option<Vec<ChecklistItem>>,
    pub color: Option<String>,
    pub pinned: Option<bool>,
    pub archived: Option<bool>,
    pub trashed: Option<bool>,
    pub position: Option<f64>,
    #[serde(default, with = "double_option")]
    pub reminder_at: Option<Option<String>>,
    /// Optional recurrence cadence. Nested so a JSON `null` turns a
    /// recurring reminder back into a one-shot one without changing its due
    /// time, while an absent key leaves it alone.
    #[serde(default, with = "double_option")]
    pub reminder_repeat: Option<Option<String>>,
    pub label_ids: Option<Vec<String>>,
    /// Moves the note between board columns. Nested like `reminder_at` so
    /// `"stage_id": null` sends the note back to unassigned while an absent
    /// key leaves the stage untouched.
    #[serde(default, with = "double_option")]
    pub stage_id: Option<Option<String>>,
    pub stage_position: Option<f64>,
}

impl UpdateNote {
    /// Copy every provided field onto `record`. `label_ids` is not applied
    /// here: labels are per-viewer, so the handler routes them separately.
    pub fn apply_to(self, record: &mut NoteRecord) {
        // Exhaustive destructuring: adding a field to UpdateNote without
        // deciding how it patches the record fails to compile.
        let UpdateNote {
            workspace_id,
            kind,
            title,
            content,
            items,
            color,
            pinned,
            archived,
            trashed,
            position,
            reminder_at,
            reminder_repeat,
            label_ids: _,
            stage_id,
            stage_position,
        } = self;
        if let Some(v) = workspace_id {
            record.workspace_id = v;
        }
        if let Some(v) = kind {
            record.kind = v;
        }
        if let Some(v) = title {
            record.title = v;
        }
        if let Some(v) = content {
            record.content = v;
        }
        if let Some(v) = items {
            record.items = v;
        }
        if let Some(v) = color {
            record.color = v;
        }
        if let Some(v) = pinned {
            record.pinned = v;
        }
        if let Some(v) = archived {
            record.archived = v;
        }
        if let Some(v) = trashed {
            record.trashed = v;
        }
        if let Some(v) = position {
            record.position = v;
        }
        if let Some(v) = reminder_at {
            record.reminder_at = v;
            // A reminder cannot recur after it has been removed. Keeping this
            // invariant here also covers older clients that only send
            // `reminder_at: null`.
            if record.reminder_at.is_none() {
                record.reminder_repeat = None;
            }
        }
        if let Some(v) = reminder_repeat {
            record.reminder_repeat = v;
        }
        if let Some(v) = stage_id {
            record.stage_id = v;
        }
        if let Some(v) = stage_position {
            record.stage_position = v;
        }
    }
}

/// Distinguishes "key absent" (None) from "key: null" (Some(None)).
mod double_option {
    use serde::{Deserialize, Deserializer};

    pub fn deserialize<'de, D>(d: D) -> Result<Option<Option<String>>, D::Error>
    where
        D: Deserializer<'de>,
    {
        Option::<String>::deserialize(d).map(Some)
    }
}

#[derive(Debug, Deserialize)]
pub struct ReorderRequest {
    pub ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct LabelPayload {
    #[serde(default)]
    pub id: Option<String>,
    /// Which workspace the label belongs to. Absent means the caller's default
    /// workspace, mirroring note creation.
    #[serde(default)]
    pub workspace_id: Option<String>,
    pub name: String,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub icon: Option<String>,
    /// Absent on create (the label is appended to the sidebar list) and
    /// present when the list is reordered, mirroring [`StagePayload::position`].
    #[serde(default)]
    pub position: Option<f64>,
}

/// Create/update body for a board stage. `position` is absent on create (the
/// stage is appended to the board) and present when columns are reordered.
#[derive(Debug, Deserialize)]
pub struct StagePayload {
    #[serde(default)]
    pub id: Option<String>,
    /// Which workspace the stage belongs to. Absent means the caller's default
    /// workspace, mirroring note and label creation.
    #[serde(default)]
    pub workspace_id: Option<String>,
    pub name: String,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub position: Option<f64>,
}

#[derive(Debug, Deserialize)]
pub struct AddCollaborator {
    pub email: String,
}
