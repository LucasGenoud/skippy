//! Board columns, independent of labels by design (see AGENTS.md).

use sqlx::Row;

use super::sqlite::{MY_WORKSPACES, SqliteRepository};
use super::{RepoError, RepoResult};
use crate::models::*;

impl SqliteRepository {
    pub async fn stages_for_user(&self, user_id: &str) -> RepoResult<Vec<Stage>> {
        let rows = sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT id, workspace_id, collection_id, name, color, position FROM stages
             WHERE collection_id IN (SELECT id FROM collections WHERE deleted=0) AND workspace_id IN ({MY_WORKSPACES}) AND workspace_id NOT IN (SELECT workspace_id FROM workspace_copies)
             ORDER BY position, name COLLATE NOCASE"
        )))
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .iter()
            .map(|r| Stage {
                id: r.get("id"),
                workspace_id: r.get("workspace_id"),
                collection_id: r.get("collection_id"),
                name: r.get("name"),
                color: r.get("color"),
                position: r.get("position"),
            })
            .collect())
    }

    pub async fn insert_stage(&self, stage: &Stage) -> RepoResult<()> {
        let result = sqlx::query(
            "INSERT OR IGNORE INTO stages (id, workspace_id, name, color, position, collection_id)
             VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(&stage.id)
        .bind(&stage.workspace_id)
        .bind(&stage.name)
        .bind(&stage.color)
        .bind(stage.position)
        .bind(&stage.collection_id)
        .execute(&self.pool)
        .await?;
        if result.rows_affected() == 0 {
            return Err(RepoError::Conflict("stage already exists".to_string()));
        }
        Ok(())
    }

    pub async fn update_stage(
        &self,
        user_id: &str,
        stage_id: &str,
        name: &str,
        color: Option<&str>,
        position: Option<f64>,
    ) -> RepoResult<bool> {
        // Membership, not authorship: a workspace's board belongs to everyone
        // in it. An absent position leaves the column where it is, so renaming
        // a stage never reshuffles the board.
        let result = sqlx::query(sqlx::AssertSqlSafe(format!(
            "UPDATE stages SET name = ?, color = ?, position = COALESCE(?, position)
             WHERE id = ? AND workspace_id IN ({MY_WORKSPACES})"
        )))
        .bind(name)
        .bind(color)
        .bind(position)
        .bind(stage_id)
        .bind(user_id)
        .bind(user_id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() > 0)
    }

    pub async fn delete_stage(&self, user_id: &str, stage_id: &str) -> RepoResult<bool> {
        let mut tx = self.pool.begin().await?;
        // Resolve authorization before clearing dependent notes. The
        // composite stage/workspace foreign key then guarantees there are no
        // cross-workspace references hiding behind this operation.
        let exists: Option<i64> = sqlx::query_scalar(sqlx::AssertSqlSafe(format!(
            "SELECT 1 FROM stages WHERE id = ? AND workspace_id IN ({MY_WORKSPACES})"
        )))
        .bind(stage_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await?;
        if exists.is_none() {
            tx.rollback().await?;
            return Ok(false);
        }
        sqlx::query("UPDATE notes SET stage_id = NULL WHERE stage_id = ?")
            .bind(stage_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM stages WHERE id = ?")
            .bind(stage_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(true)
    }

    pub async fn max_stage_position(&self, workspace_id: &str) -> RepoResult<f64> {
        // 0.0, not 0: an integer literal makes the empty-board case decode as
        // INTEGER and the f64 read fails.
        let row = sqlx::query(
            "SELECT COALESCE(MAX(position), 0.0) AS m FROM stages WHERE workspace_id = ?",
        )
        .bind(workspace_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(row.get("m"))
    }

    pub async fn prune_foreign_stage(&self, note_id: &str) -> RepoResult<()> {
        sqlx::query(
            "UPDATE notes SET stage_id = NULL
             WHERE id = ? AND stage_id IS NOT NULL AND stage_id NOT IN (
                 SELECT s.id FROM stages s
                 JOIN notes n ON n.workspace_id = s.workspace_id AND n.collection_id = s.collection_id
                 WHERE n.id = ?
             )",
        )
        .bind(note_id)
        .bind(note_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}
