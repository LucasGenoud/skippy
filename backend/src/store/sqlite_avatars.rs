use chrono::Utc;
use sqlx::Row;

use super::RepoResult;
use super::sqlite::{SqliteRepository, visible_notes};

/// A stored profile picture.
pub struct Avatar {
    pub mime: String,
    pub bytes: Vec<u8>,
}

impl SqliteRepository {
    /// Store `user_id`'s picture and return its new version. The version only
    /// ever grows, so a replacement made within the same millisecond still
    /// reads as new to clients.
    pub async fn set_avatar(&self, user_id: &str, mime: &str, bytes: &[u8]) -> RepoResult<i64> {
        let version: i64 = sqlx::query_scalar(
            "INSERT INTO user_avatars (user_id, mime, bytes, updated_at) VALUES (?, ?, ?, ?)
             ON CONFLICT(user_id) DO UPDATE SET
                 mime = excluded.mime,
                 bytes = excluded.bytes,
                 updated_at = max(excluded.updated_at, user_avatars.updated_at + 1)
             RETURNING updated_at",
        )
        .bind(user_id)
        .bind(mime)
        .bind(bytes)
        .bind(Utc::now().timestamp_millis())
        .fetch_one(&self.pool)
        .await?;
        Ok(version)
    }

    /// Remove `user_id`'s picture. False when there was none.
    pub async fn delete_avatar(&self, user_id: &str) -> RepoResult<bool> {
        let result = sqlx::query("DELETE FROM user_avatars WHERE user_id = ?")
            .bind(user_id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() > 0)
    }

    /// `target`'s picture, if `viewer` is shown that person anywhere: it is
    /// themselves, someone in a workspace they share, or the owner or a
    /// collaborator of a note the viewer can see. Anyone else gets nothing,
    /// so a picture never confirms that an account exists.
    pub async fn avatar_for(&self, viewer: &str, target: &str) -> RepoResult<Option<Avatar>> {
        let row = sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT mime, bytes FROM user_avatars WHERE user_id = ?1 AND (
                 ?1 = ?2
                 OR EXISTS (
                     SELECT 1 FROM ({ROSTER}) a JOIN ({ROSTER}) b ON a.wid = b.wid
                     WHERE a.uid = ?2 AND b.uid = ?1
                 )
                 OR EXISTS (
                     SELECT 1 FROM notes n JOIN workspaces w ON w.id = n.workspace_id
                     WHERE {visible}
                       AND (w.owner_id = ?1
                            OR n.id IN (SELECT note_id FROM note_shares WHERE user_id = ?1))
                 )
             )",
            visible = visible_notes("n").replace('?', "?2"),
        )))
        .bind(target)
        .bind(viewer)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|row| Avatar {
            mime: row.get("mime"),
            bytes: row.get("bytes"),
        }))
    }
}

/// Every (workspace, person) pair: owners and members alike.
const ROSTER: &str = "SELECT id AS wid, owner_id AS uid FROM workspaces
     UNION SELECT workspace_id AS wid, user_id AS uid FROM workspace_members";
