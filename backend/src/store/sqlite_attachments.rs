use async_trait::async_trait;
use sqlx::Row;

use super::sqlite::{SqliteRepository, enqueue_cleanup_tx, now};
use super::{AttachmentRepository, CleanupKind, RepoResult};
use crate::models::Attachment;

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
                },
            )
        }))
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
