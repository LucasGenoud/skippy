use async_trait::async_trait;
use sqlx::Row;

use super::sqlite::{SqliteRepository, now, visible_notes};
use super::{HistoryRepository, RepoResult};
use crate::models::HistoryEntry;

#[async_trait]
impl HistoryRepository for SqliteRepository {
    async fn record_checked_items(&self, note_id: &str, texts: &[String]) -> RepoResult<()> {
        let mut tx = self.pool.begin().await?;
        for text in texts {
            let text = text.trim();
            if text.is_empty() || text.len() > 200 {
                continue;
            }
            sqlx::query(
                "INSERT INTO checklist_history (note_id, text, uses, last_used_at)
                 VALUES (?, ?, 1, ?)
                 ON CONFLICT (note_id, text)
                 DO UPDATE SET uses = uses + 1, last_used_at = excluded.last_used_at",
            )
            .bind(note_id)
            .bind(text)
            .bind(now())
            .execute(&mut *tx)
            .await?;
        }
        sqlx::query(
            "DELETE FROM checklist_history WHERE note_id = ? AND text NOT IN (
                 SELECT text FROM checklist_history WHERE note_id = ?
                 ORDER BY last_used_at DESC LIMIT 500)",
        )
        .bind(note_id)
        .bind(note_id)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }

    async fn checklist_history(&self, user_id: &str) -> RepoResult<Vec<HistoryEntry>> {
        let rows = sqlx::query(&format!(
            "SELECT h.note_id, h.text, h.uses FROM checklist_history h
             JOIN notes n ON n.id = h.note_id
             WHERE {}
             ORDER BY h.uses DESC, h.last_used_at DESC",
            visible_notes("n")
        ))
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .iter()
            .map(|row| HistoryEntry {
                note_id: row.get("note_id"),
                text: row.get("text"),
                uses: row.get("uses"),
            })
            .collect())
    }
}
