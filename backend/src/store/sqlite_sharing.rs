use sqlx::Row;

use super::RepoResult;
use super::sqlite::{SHARE_LINK_COLUMNS, SqliteRepository};
use super::sqlite_rows::share_link_from_row;
use crate::models::ShareLink;

impl SqliteRepository {
    pub async fn participant_ids(&self, note_id: &str) -> RepoResult<Vec<String>> {
        let rows = sqlx::query(
            "SELECT user_id AS uid FROM note_shares WHERE note_id = ?
             UNION SELECT w.owner_id AS uid FROM workspaces w
                 JOIN notes n ON n.workspace_id = w.id WHERE n.id = ?
             UNION SELECT m.user_id AS uid FROM workspace_members m
                 JOIN notes n ON n.workspace_id = m.workspace_id WHERE n.id = ?",
        )
        .bind(note_id)
        .bind(note_id)
        .bind(note_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(|row| row.get("uid")).collect())
    }

    pub async fn is_participant(&self, note_id: &str, user_id: &str) -> RepoResult<bool> {
        let allowed: i64 = sqlx::query_scalar(
            "SELECT EXISTS (
                 SELECT 1 FROM notes n
                 JOIN workspaces w ON w.id = n.workspace_id
                 WHERE n.id = ? AND (
                     w.owner_id = ?
                     OR EXISTS (
                         SELECT 1 FROM workspace_members m
                         WHERE m.workspace_id = n.workspace_id AND m.user_id = ?
                     )
                     OR EXISTS (
                         SELECT 1 FROM note_shares s
                         WHERE s.note_id = n.id AND s.user_id = ?
                     )
                 )
             )",
        )
        .bind(note_id)
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(allowed != 0)
    }

    pub async fn add_collaborator(&self, note_id: &str, user_id: &str) -> RepoResult<()> {
        sqlx::query("INSERT OR IGNORE INTO note_shares (note_id, user_id) VALUES (?, ?)")
            .bind(note_id)
            .bind(user_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn remove_collaborator(&self, note_id: &str, user_id: &str) -> RepoResult<bool> {
        let result = sqlx::query("DELETE FROM note_shares WHERE note_id = ? AND user_id = ?")
            .bind(note_id)
            .bind(user_id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() > 0)
    }

    pub async fn insert_share_link(&self, link: &ShareLink) -> RepoResult<()> {
        sqlx::query(
            "INSERT INTO share_links
                (token, created_by, target, note_id, workspace_id, label_id, created_at, expires_at, collection_id)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&link.token)
        .bind(&link.created_by)
        .bind(&link.target)
        .bind(&link.note_id)
        .bind(&link.workspace_id)
        .bind(&link.label_id)
        .bind(&link.created_at)
        .bind(&link.expires_at)
        .bind(&link.collection_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn share_link(&self, token: &str) -> RepoResult<Option<ShareLink>> {
        let row = sqlx::query(&format!("{SHARE_LINK_COLUMNS} WHERE token = ?"))
            .bind(token)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.as_ref().map(share_link_from_row))
    }

    pub async fn share_links_for_user(&self, user_id: &str) -> RepoResult<Vec<ShareLink>> {
        let rows = sqlx::query(&format!(
            "{SHARE_LINK_COLUMNS} WHERE created_by = ? ORDER BY created_at DESC"
        ))
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(share_link_from_row).collect())
    }

    pub async fn share_link_for_target(
        &self,
        user_id: &str,
        target: &str,
        note_id: Option<&str>,
        workspace_id: Option<&str>,
        label_id: Option<&str>,
        collection_id: Option<&str>,
    ) -> RepoResult<Option<ShareLink>> {
        let row = sqlx::query(&format!(
            "{SHARE_LINK_COLUMNS}
             WHERE created_by = ? AND target = ?
               AND note_id IS ? AND workspace_id IS ? AND label_id IS ? AND collection_id IS ?"
        ))
        .bind(user_id)
        .bind(target)
        .bind(note_id)
        .bind(workspace_id)
        .bind(label_id)
        .bind(collection_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.as_ref().map(share_link_from_row))
    }

    pub async fn delete_share_link(&self, user_id: &str, token: &str) -> RepoResult<bool> {
        let result = sqlx::query("DELETE FROM share_links WHERE token = ? AND created_by = ?")
            .bind(token)
            .bind(user_id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() > 0)
    }
}
