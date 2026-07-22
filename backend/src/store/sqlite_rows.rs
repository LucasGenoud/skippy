use sqlx::{Row, sqlite::SqliteRow};

use crate::models::{NoteRecord, NoteVersion, User};

pub(super) fn note_from_row(row: &SqliteRow) -> NoteRecord {
    let items_json: String = row.get("items");
    NoteRecord {
        id: row.get("id"),
        owner_id: row.get("owner_id"),
        kind: row.get("kind"),
        title: row.get("title"),
        content: row.get("content"),
        items: serde_json::from_str(&items_json).unwrap_or_default(),
        color: row.get("color"),
        pinned: row.get::<i64, _>("pinned") != 0,
        archived: row.get::<i64, _>("archived") != 0,
        trashed: row.get::<i64, _>("trashed") != 0,
        position: row.get("position"),
        reminder_at: row.get("reminder_at"),
        reminder_fired_at: row.get("reminder_fired_at"),
        transcript_status: row.get("transcript_status"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
        last_editor_id: row.get("last_editor_id"),
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

pub(super) fn user_from_row(row: &SqliteRow) -> User {
    User {
        id: row.get("id"),
        username: row.get("username"),
        password_hash: row.get("password_hash"),
    }
}

pub(super) fn now() -> String {
    chrono::Utc::now().to_rfc3339()
}
