use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Users & auth

#[derive(Debug, Clone, Serialize)]
pub struct UserPublic {
    pub id: String,
    pub username: String,
}

#[derive(Debug, Clone)]
pub struct User {
    pub id: String,
    pub username: String,
    pub password_hash: String,
}

impl User {
    pub fn public(&self) -> UserPublic {
        UserPublic { id: self.id.clone(), username: self.username.clone() }
    }
}

#[derive(Debug, Deserialize)]
pub struct Credentials {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Serialize)]
pub struct AuthResponse {
    pub token: String,
    pub user: UserPublic,
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
    pub owner_id: String,
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
    /// Audio-note transcription state (`none`/`pending`/`done`/`failed`).
    pub transcript_status: String,
    pub created_at: String,
    pub updated_at: String,
    /// Who last edited the note's content. Drives version-history coalescing
    /// (edits by the same author in one sitting collapse to a single version)
    /// and starts out `None` until the first edit. Not exposed on the wire.
    pub last_editor_id: Option<String>,
}

/// A note as served to a specific user: includes that user's labels and the
/// sharing roster.
#[derive(Debug, Clone, Serialize)]
pub struct NoteView {
    #[serde(flatten)]
    pub note: NoteFields,
    /// Labels are personal: each participant sees only their own labels here.
    pub label_ids: Vec<String>,
    pub owner: UserPublic,
    pub collaborators: Vec<UserPublic>,
    pub attachments: Vec<Attachment>,
}

#[derive(Debug, Clone, Serialize)]
pub struct NoteFields {
    pub id: String,
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
    pub transcript_status: String,
    pub created_at: String,
    pub updated_at: String,
}

impl NoteRecord {
    pub fn fields(&self) -> NoteFields {
        NoteFields {
            id: self.id.clone(),
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
            transcript_status: self.transcript_status.clone(),
            created_at: self.created_at.clone(),
            updated_at: self.updated_at.clone(),
        }
    }
}

/// A past state of a note's content, kept for the version-history timeline.
/// Only content fields are versioned — organizational state (color, pin,
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
    pub name: String,
}

/// A checklist item text previously checked off in a note; powers typing
/// suggestions ("Mi…" -> "Milk") in that note's checklist rows. Scoped per
/// note — suggestions never leak from one note to another.
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
    pub position: Option<f64>,
    #[serde(default)]
    pub reminder_at: Option<String>,
}

/// Partial update: only fields present in the JSON body are applied.
/// `reminder_at` uses a nested Option so `"reminder_at": null` clears it
/// while an absent key leaves it untouched.
#[derive(Debug, Deserialize, Default)]
pub struct UpdateNote {
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
    pub label_ids: Option<Vec<String>>,
}

impl UpdateNote {
    /// Copy every provided field onto `record`. `label_ids` is not applied
    /// here: labels are per-viewer, so the handler routes them separately.
    pub fn apply_to(self, record: &mut NoteRecord) {
        // Exhaustive destructuring: adding a field to UpdateNote without
        // deciding how it patches the record fails to compile.
        let UpdateNote {
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
            label_ids: _,
        } = self;
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
    pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct AddCollaborator {
    pub username: String,
}
