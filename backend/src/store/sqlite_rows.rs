use sqlx::{Row, sqlite::SqliteRow};

use crate::models::{NoteRecord, NoteVersion, User, Workspace};

pub(super) fn note_from_row(row: &SqliteRow) -> NoteRecord {
    let items_json: String = row.get("items");
    let position: f64 = row.get("position");
    NoteRecord {
        id: row.get("id"),
        owner_id: row.get("owner_id"),
        workspace_id: row.get("workspace_id"),
        kind: row.get("kind"),
        title: row.get("title"),
        content: row.get("content"),
        items: serde_json::from_str(&items_json).unwrap_or_default(),
        color: row.get("color"),
        pinned: row.get::<i64, _>("pinned") != 0,
        archived: row.get::<i64, _>("archived") != 0,
        trashed: row.get::<i64, _>("trashed") != 0,
        position,
        reminder_at: row.get("reminder_at"),
        reminder_fired_at: row.get("reminder_fired_at"),
        transcript_status: row.get("transcript_status"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
        last_editor_id: row.get("last_editor_id"),
        stage_id: row.get("stage_id"),
        // The startup backfill fills this in for rows written before boards
        // existed; falling back to the grid position keeps the model non-null
        // for anything that slips past it (a row inserted by an older build
        // still running against the same file).
        stage_position: row
            .get::<Option<f64>, _>("stage_position")
            .unwrap_or(position),
    }
}

pub(super) fn version_from_row(row: &SqliteRow) -> NoteVersion {
    let items_json: String = row.get("items");
    NoteVersion {
        id: row.get("id"),
        note_id: row.get("note_id"),
        kind: row.get("kind"),
        title: row.get("title"),
        content: row.get("content"),
        items: serde_json::from_str(&items_json).unwrap_or_default(),
        edited_by: row.get("edited_by"),
        created_at: row.get("created_at"),
    }
}

pub(super) fn workspace_from_row(row: &SqliteRow) -> Workspace {
    Workspace {
        id: row.get("id"),
        owner_id: row.get("owner_id"),
        name: row.get("name"),
        is_default: row.get::<i64, _>("is_default") != 0,
        created_at: row.get("created_at"),
    }
}

pub(super) fn user_from_row(row: &SqliteRow) -> User {
    User {
        id: row.get("id"),
        name: row.get("name"),
        email: row.get("email"),
        password_hash: row.get("password_hash"),
    }
}

pub(super) fn now() -> String {
    chrono::Utc::now().to_rfc3339()
}
