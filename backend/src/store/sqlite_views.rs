//! Bulk decoration of note records into viewer-specific API views.
//!
//! This stays separate from the repository's CRUD implementation because view
//! assembly is a read model: it joins workspace ownership, labels, direct
//! shares, and attachments without changing any of those domains. Every query
//! is narrowed to the records being decorated; fetching one note must not scan
//! every attachment or collaborator in the installation.

use std::collections::HashMap;

use sqlx::{Row, SqlitePool};

use super::RepoResult;
use super::sqlite::MY_WORKSPACES;
use crate::models::{Attachment, ItemReminder, NoteRecord, NoteView, UserPublic};

pub(super) async fn build_note_views(
    pool: &SqlitePool,
    records: Vec<NoteRecord>,
    viewer_id: &str,
) -> RepoResult<Vec<NoteView>> {
    if records.is_empty() {
        return Ok(vec![]);
    }

    let note_ids = serde_json::to_string(
        &records
            .iter()
            .map(|record| record.id.as_str())
            .collect::<Vec<_>>(),
    )?;
    let workspace_ids = serde_json::to_string(
        &records
            .iter()
            .map(|record| record.workspace_id.as_str())
            .collect::<Vec<_>>(),
    )?;

    // Labels are workspace state. A direct collaborator outside the workspace
    // receives no label ids even though the note itself is visible.
    let mut labels_by_note: HashMap<String, Vec<String>> = HashMap::new();
    for row in sqlx::query(&format!(
        "SELECT nl.note_id, nl.label_id FROM note_labels nl
         JOIN labels l ON l.id = nl.label_id
         WHERE nl.note_id IN (SELECT value FROM json_each(?))
           AND l.workspace_id IN ({MY_WORKSPACES})"
    ))
    .bind(&note_ids)
    .bind(viewer_id)
    .bind(viewer_id)
    .fetch_all(pool)
    .await?
    {
        labels_by_note
            .entry(row.get("note_id"))
            .or_default()
            .push(row.get("label_id"));
    }

    let mut collaborators_by_note: HashMap<String, Vec<UserPublic>> = HashMap::new();
    for row in sqlx::query(
        "SELECT ns.note_id, u.id, u.name FROM note_shares ns
         JOIN users u ON u.id = ns.user_id
         WHERE ns.note_id IN (SELECT value FROM json_each(?))",
    )
    .bind(&note_ids)
    .fetch_all(pool)
    .await?
    {
        collaborators_by_note
            .entry(row.get("note_id"))
            .or_default()
            .push(UserPublic {
                id: row.get("id"),
                name: row.get("name"),
            });
    }

    let mut attachments_by_note: HashMap<String, Vec<Attachment>> = HashMap::new();
    for row in sqlx::query(
        "SELECT a.id, a.note_id, a.mime, a.filename, a.size, o.text AS ocr_text
         FROM attachments a
         LEFT JOIN attachment_ocr o ON o.attachment_id = a.id
         WHERE a.note_id IN (SELECT value FROM json_each(?))
         ORDER BY a.created_at",
    )
    .bind(&note_ids)
    .fetch_all(pool)
    .await?
    {
        attachments_by_note
            .entry(row.get("note_id"))
            .or_default()
            .push(Attachment {
                id: row.get("id"),
                mime: row.get("mime"),
                filename: row.get("filename"),
                size: row.get("size"),
                url: None,
                ocr_text: row.get("ocr_text"),
            });
    }

    // Item reminders are note state, not workspace state, so unlike labels
    // they are visible to a direct collaborator too.
    let mut item_reminders_by_note: HashMap<String, Vec<ItemReminder>> = HashMap::new();
    for row in sqlx::query(
        "SELECT note_id, item_id, reminder_at, reminder_repeat FROM note_item_reminders
         WHERE note_id IN (SELECT value FROM json_each(?))",
    )
    .bind(&note_ids)
    .fetch_all(pool)
    .await?
    {
        item_reminders_by_note
            .entry(row.get("note_id"))
            .or_default()
            .push(ItemReminder {
                item_id: row.get("item_id"),
                reminder_at: row.get("reminder_at"),
                reminder_repeat: row.get("reminder_repeat"),
            });
    }

    let workspace_owners: HashMap<String, UserPublic> = sqlx::query(
        "SELECT w.id AS workspace_id, u.id, u.name FROM workspaces w
         JOIN users u ON u.id = w.owner_id
         WHERE w.id IN (SELECT value FROM json_each(?))",
    )
    .bind(&workspace_ids)
    .fetch_all(pool)
    .await?
    .into_iter()
    .map(|row| {
        (
            row.get("workspace_id"),
            UserPublic {
                id: row.get("id"),
                name: row.get("name"),
            },
        )
    })
    .collect();

    records
        .into_iter()
        .map(|record| {
            let mut collaborators = collaborators_by_note
                .get(&record.id)
                .cloned()
                .unwrap_or_default();
            collaborators.sort_by(|a, b| a.name.cmp(&b.name));
            let owner = workspace_owners
                .get(&record.workspace_id)
                .cloned()
                .ok_or_else(|| {
                    anyhow::anyhow!(
                        "workspace {} has no owner while decorating note {}",
                        record.workspace_id,
                        record.id
                    )
                })?;
            // Item order, not id order: the list reads top to bottom, and a
            // reminder for a row the note no longer holds is not shown at all
            // (the storage layer prunes those, this only refuses to guess).
            let mut item_reminders = item_reminders_by_note
                .get(&record.id)
                .cloned()
                .unwrap_or_default();
            let item_order: HashMap<&str, usize> = record
                .items
                .iter()
                .enumerate()
                .map(|(index, item)| (item.id.as_str(), index))
                .collect();
            item_reminders.retain(|reminder| item_order.contains_key(reminder.item_id.as_str()));
            item_reminders.sort_by_key(|reminder| item_order[reminder.item_id.as_str()]);
            Ok(NoteView {
                label_ids: labels_by_note.get(&record.id).cloned().unwrap_or_default(),
                owner,
                collaborators,
                attachments: attachments_by_note
                    .get(&record.id)
                    .cloned()
                    .unwrap_or_default(),
                item_reminders,
                note: record.fields(),
            })
        })
        .collect()
}
