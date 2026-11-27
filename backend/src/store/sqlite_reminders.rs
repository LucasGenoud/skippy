//! Note reminders and checklist item reminders, swept by the scheduler.

use sqlx::Row;
use std::collections::HashMap;

use super::RepoResult;
use super::sqlite::SqliteRepository;
use super::sqlite_rows::{item_reminder_from_row, note_from_row};
use crate::models::*;

impl SqliteRepository {
    pub async fn due_reminders(&self, now: &str) -> RepoResult<Vec<NoteRecord>> {
        // julianday() understands RFC3339 offsets, so "10:00+02:00" compares
        // as the instant it names rather than as a string.
        let rows = sqlx::query(
            "SELECT * FROM notes
             WHERE reminder_at IS NOT NULL AND reminder_fired_at IS NULL
               AND trashed = 0 AND julianday(reminder_at) <= julianday(?)",
        )
        .bind(now)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(note_from_row).collect())
    }

    pub async fn mark_reminder_fired(
        &self,
        note_id: &str,
        reminder_at: &str,
        fired_at: &str,
    ) -> RepoResult<bool> {
        let result = sqlx::query(
            "UPDATE notes SET reminder_fired_at = ?
             WHERE id = ? AND reminder_at = ? AND reminder_fired_at IS NULL",
        )
        .bind(fired_at)
        .bind(note_id)
        .bind(reminder_at)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn advance_recurring_reminder(
        &self,
        note_id: &str,
        reminder_at: &str,
        next_reminder_at: &str,
        advanced_at: &str,
    ) -> RepoResult<bool> {
        let result = sqlx::query(
            "UPDATE notes
             SET reminder_at = ?, reminder_fired_at = NULL, updated_at = ?
             WHERE id = ? AND reminder_at = ? AND reminder_fired_at IS NULL
               AND reminder_repeat IS NOT NULL",
        )
        .bind(next_reminder_at)
        .bind(advanced_at)
        .bind(note_id)
        .bind(reminder_at)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    // -- checklist item reminders --------------------------------------------

    pub async fn item_reminders(&self, note_id: &str) -> RepoResult<Vec<ItemReminder>> {
        let rows = sqlx::query(
            "SELECT item_id, reminder_at, reminder_repeat FROM note_item_reminders
             WHERE note_id = ? ORDER BY item_id",
        )
        .bind(note_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(item_reminder_from_row).collect())
    }

    pub async fn item_reminders_for_notes(
        &self,
        note_ids: &[String],
    ) -> RepoResult<HashMap<String, Vec<ItemReminder>>> {
        if note_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let ids = serde_json::to_string(note_ids)?;
        let rows = sqlx::query(
            "SELECT note_id, item_id, reminder_at, reminder_repeat FROM note_item_reminders
             WHERE note_id IN (SELECT value FROM json_each(?)) ORDER BY item_id",
        )
        .bind(&ids)
        .fetch_all(&self.pool)
        .await?;
        let mut by_note: HashMap<String, Vec<ItemReminder>> = HashMap::new();
        for row in &rows {
            by_note
                .entry(row.get("note_id"))
                .or_default()
                .push(item_reminder_from_row(row));
        }
        Ok(by_note)
    }

    pub async fn set_item_reminder(
        &self,
        note_id: &str,
        reminder: &ItemReminder,
    ) -> RepoResult<()> {
        // Writing the row clears fired_at: a rescheduled reminder is a new
        // alarm, exactly as `reset_delivered_reminder_if_rescheduled` treats a
        // moved note reminder.
        sqlx::query(
            "INSERT INTO note_item_reminders (note_id, item_id, reminder_at, reminder_repeat, fired_at)
             VALUES (?, ?, ?, ?, NULL)
             ON CONFLICT (note_id, item_id) DO UPDATE SET
                 reminder_at = excluded.reminder_at,
                 reminder_repeat = excluded.reminder_repeat,
                 fired_at = NULL",
        )
        .bind(note_id)
        .bind(&reminder.item_id)
        .bind(&reminder.reminder_at)
        .bind(&reminder.reminder_repeat)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn clear_item_reminder(&self, note_id: &str, item_id: &str) -> RepoResult<()> {
        sqlx::query("DELETE FROM note_item_reminders WHERE note_id = ? AND item_id = ?")
            .bind(note_id)
            .bind(item_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn due_item_reminders(&self, now: &str) -> RepoResult<Vec<DueItemReminder>> {
        // Aliased so the note's own reminder columns survive `n.*` untouched;
        // julianday() compares instants, so a non-UTC offset comes due at the
        // moment it names.
        let rows = sqlx::query(
            "SELECT n.*, r.item_id AS due_item_id,
                    r.reminder_at AS due_item_reminder_at,
                    r.reminder_repeat AS due_item_reminder_repeat
             FROM note_item_reminders r
             JOIN notes n ON n.id = r.note_id
             WHERE r.fired_at IS NULL AND n.trashed = 0
               AND julianday(r.reminder_at) <= julianday(?)",
        )
        .bind(now)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .iter()
            .map(|row| DueItemReminder {
                note: note_from_row(row),
                item_id: row.get("due_item_id"),
                reminder_at: row.get("due_item_reminder_at"),
                reminder_repeat: row.get("due_item_reminder_repeat"),
            })
            .collect())
    }

    pub async fn mark_item_reminder_fired(
        &self,
        note_id: &str,
        item_id: &str,
        reminder_at: &str,
        fired_at: &str,
    ) -> RepoResult<bool> {
        let result = sqlx::query(
            "UPDATE note_item_reminders SET fired_at = ?
             WHERE note_id = ? AND item_id = ? AND reminder_at = ? AND fired_at IS NULL",
        )
        .bind(fired_at)
        .bind(note_id)
        .bind(item_id)
        .bind(reminder_at)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn advance_recurring_item_reminder(
        &self,
        note_id: &str,
        item_id: &str,
        reminder_at: &str,
        next_reminder_at: &str,
    ) -> RepoResult<bool> {
        let result = sqlx::query(
            "UPDATE note_item_reminders SET reminder_at = ?, fired_at = NULL
             WHERE note_id = ? AND item_id = ? AND reminder_at = ? AND fired_at IS NULL
               AND reminder_repeat IS NOT NULL",
        )
        .bind(next_reminder_at)
        .bind(note_id)
        .bind(item_id)
        .bind(reminder_at)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }
}
