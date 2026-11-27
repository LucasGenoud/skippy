//! Workspace labels and note-label membership.

use sqlx::Row;

use super::sqlite::{MY_WORKSPACES, SqliteRepository};
use super::{RepoError, RepoResult};
use crate::models::*;

impl SqliteRepository {
    pub async fn labels_for_user(&self, user_id: &str) -> RepoResult<Vec<Label>> {
        let rows = sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT id, workspace_id, name, color, icon, position FROM labels
             WHERE workspace_id IN ({MY_WORKSPACES}) AND workspace_id NOT IN (SELECT workspace_id FROM workspace_copies)
             ORDER BY position, name COLLATE NOCASE"
        )))
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .iter()
            .map(|r| Label {
                id: r.get("id"),
                workspace_id: r.get("workspace_id"),
                name: r.get("name"),
                color: r.get("color"),
                icon: r.get("icon"),
                position: r.get("position"),
            })
            .collect())
    }

    pub async fn insert_label(&self, label: &Label) -> RepoResult<()> {
        let result = sqlx::query(
            "INSERT OR IGNORE INTO labels (id, workspace_id, name, color, icon, position)
             VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(&label.id)
        .bind(&label.workspace_id)
        .bind(&label.name)
        .bind(&label.color)
        .bind(&label.icon)
        .bind(label.position)
        .execute(&self.pool)
        .await?;
        if result.rows_affected() == 0 {
            return Err(RepoError::Conflict("label already exists".to_string()));
        }
        Ok(())
    }

    pub async fn update_label(
        &self,
        user_id: &str,
        label_id: &str,
        name: &str,
        color: Option<&str>,
        icon: Option<&str>,
        position: Option<f64>,
    ) -> RepoResult<bool> {
        // Membership, not authorship: a workspace's labels belong to everyone
        // in it. An absent position leaves the label where it is, so renaming
        // one never reshuffles the sidebar (mirrors update_stage).
        let result = sqlx::query(sqlx::AssertSqlSafe(format!(
            "UPDATE labels SET name = ?, color = ?, icon = ?, position = COALESCE(?, position)
             WHERE id = ? AND workspace_id IN ({MY_WORKSPACES})"
        )))
        .bind(name)
        .bind(color)
        .bind(icon)
        .bind(position)
        .bind(label_id)
        .bind(user_id)
        .bind(user_id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() > 0)
    }

    pub async fn max_label_position(&self, workspace_id: &str) -> RepoResult<f64> {
        // 0.0, not 0: an integer literal makes the empty-sidebar case decode as
        // INTEGER and the f64 read fails (mirrors max_stage_position).
        let row = sqlx::query(
            "SELECT COALESCE(MAX(position), 0.0) AS m FROM labels WHERE workspace_id = ?",
        )
        .bind(workspace_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(row.get("m"))
    }

    pub async fn delete_label(&self, user_id: &str, label_id: &str) -> RepoResult<bool> {
        let result = sqlx::query(sqlx::AssertSqlSafe(format!(
            "DELETE FROM labels WHERE id = ? AND workspace_id IN ({MY_WORKSPACES})"
        )))
        .bind(label_id)
        .bind(user_id)
        .bind(user_id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() > 0)
    }

    pub async fn set_note_labels(&self, note_id: &str, label_ids: &[String]) -> RepoResult<()> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("DELETE FROM note_labels WHERE note_id = ?")
            .bind(note_id)
            .execute(&mut *tx)
            .await?;
        for label_id in label_ids {
            // The workspace join keeps a stray id from attaching a label that
            // belongs to some other workspace.
            sqlx::query(
                "INSERT OR IGNORE INTO note_labels (workspace_id, note_id, label_id)
                 SELECT n.workspace_id, n.id, l.id FROM notes n
                 JOIN labels l ON l.workspace_id = n.workspace_id
                 WHERE n.id = ? AND l.id = ?",
            )
            .bind(note_id)
            .bind(label_id)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    pub async fn prune_foreign_labels(&self, note_id: &str) -> RepoResult<()> {
        // The composite foreign keys on note_labels make a mismatch
        // impossible. Kept at the repository seam for callers shared with
        // other storage implementations.
        let _ = note_id;
        Ok(())
    }
}
