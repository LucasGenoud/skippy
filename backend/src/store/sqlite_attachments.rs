use async_trait::async_trait;
use sqlx::Row;

use super::sqlite::{SqliteRepository, enqueue_cleanup_tx, now};
use super::{AttachmentRepository, CleanupKind, RepoResult};
use crate::models::{Attachment, OcrJob};

#[async_trait]
impl AttachmentRepository for SqliteRepository {
    async fn insert_attachment(&self, attachment: &Attachment, note_id: &str) -> RepoResult<()> {
        sqlx::query(
            "INSERT INTO attachments (id, note_id, mime, filename, size, created_at)
             VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(&attachment.id)
        .bind(note_id)
        .bind(&attachment.mime)
        .bind(&attachment.filename)
        .bind(attachment.size)
        .bind(now())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn attachment_info(
        &self,
        attachment_id: &str,
    ) -> RepoResult<Option<(String, Attachment)>> {
        let row = sqlx::query("SELECT note_id, mime, filename, size FROM attachments WHERE id = ?")
            .bind(attachment_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|row| {
            (
                row.get("note_id"),
                Attachment {
                    id: attachment_id.to_string(),
                    mime: row.get("mime"),
                    filename: row.get("filename"),
                    size: row.get("size"),
                    url: None,
                    ocr_text: None,
                },
            )
        }))
    }

    async fn set_attachment_ocr(&self, attachment_id: &str, text: &str) -> RepoResult<()> {
        // Re-running recognition (a retried backlog entry) replaces the old
        // reading rather than failing on the primary key.
        sqlx::query(
            "INSERT INTO attachment_ocr (attachment_id, text, created_at) VALUES (?, ?, ?)
             ON CONFLICT(attachment_id) DO UPDATE SET text = excluded.text",
        )
        .bind(attachment_id)
        .bind(text)
        .bind(now())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn note_ocr_text(&self, note_id: &str) -> RepoResult<Vec<String>> {
        let rows = sqlx::query(
            "SELECT o.text FROM attachment_ocr o
             JOIN attachments a ON a.id = o.attachment_id
             WHERE a.note_id = ? AND trim(o.text) <> ''
             ORDER BY a.created_at",
        )
        .bind(note_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .iter()
            .map(|row| row.get::<String, _>("text"))
            .collect())
    }

    async fn attachments_awaiting_ocr(&self, limit: u32) -> RepoResult<Vec<OcrJob>> {
        let rows = sqlx::query(
            "SELECT a.id, a.note_id, a.mime, a.filename FROM attachments a
             WHERE a.mime LIKE 'image/%'
               AND NOT EXISTS (SELECT 1 FROM attachment_ocr o WHERE o.attachment_id = a.id)
             ORDER BY a.created_at
             LIMIT ?",
        )
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .iter()
            .map(|row| OcrJob {
                attachment_id: row.get("id"),
                note_id: row.get("note_id"),
                mime: row.get("mime"),
                filename: row.get("filename"),
            })
            .collect())
    }

    async fn delete_attachment(&self, attachment_id: &str) -> RepoResult<bool> {
        let mut tx = self.pool.begin().await?;
        let exists: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM attachments WHERE id = ?")
            .bind(attachment_id)
            .fetch_one(&mut *tx)
            .await?;
        if exists == 0 {
            return Ok(false);
        }
        enqueue_cleanup_tx(&mut tx, CleanupKind::AttachmentBlob, attachment_id).await?;
        sqlx::query("DELETE FROM attachments WHERE id = ?")
            .bind(attachment_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(true)
    }
}
