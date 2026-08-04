use async_trait::async_trait;
use sqlx::Row;

use super::sqlite::{SqliteRepository, now};
use super::{
    CleanupJob, CleanupKind, CleanupStats, InfrastructureRepository, RepoError, RepoResult,
};

#[async_trait]
impl InfrastructureRepository for SqliteRepository {
    async fn settings_for_user(&self, user_id: &str) -> RepoResult<Option<String>> {
        let row = sqlx::query("SELECT data FROM user_settings WHERE user_id = ?")
            .bind(user_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|row| row.get("data")))
    }

    async fn put_settings(&self, user_id: &str, data: &str) -> RepoResult<()> {
        sqlx::query(
            "INSERT INTO user_settings (user_id, data) VALUES (?, ?)
             ON CONFLICT (user_id) DO UPDATE SET data = excluded.data",
        )
        .bind(user_id)
        .bind(data)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn meta_get(&self, key: &str) -> RepoResult<Option<String>> {
        let row = sqlx::query("SELECT value FROM app_meta WHERE key = ?")
            .bind(key)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|row| row.get("value")))
    }

    async fn meta_set(&self, key: &str, value: &str) -> RepoResult<()> {
        sqlx::query(
            "INSERT INTO app_meta (key, value) VALUES (?, ?)
             ON CONFLICT (key) DO UPDATE SET value = excluded.value",
        )
        .bind(key)
        .bind(value)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn enqueue_cleanup(&self, kind: CleanupKind, target_id: &str) -> RepoResult<()> {
        sqlx::query(
            "INSERT OR IGNORE INTO cleanup_jobs
             (kind, target_id, next_attempt_at, created_at) VALUES (?, ?, 0, ?)",
        )
        .bind(kind.as_str())
        .bind(target_id)
        .bind(now())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn due_cleanup_jobs(&self, now: i64, limit: u32) -> RepoResult<Vec<CleanupJob>> {
        let rows = sqlx::query(
            "SELECT id, kind, target_id, attempts FROM cleanup_jobs
             WHERE next_attempt_at <= ? ORDER BY id LIMIT ?",
        )
        .bind(now)
        .bind(i64::from(limit))
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|row| {
                let attempts: i64 = row.get("attempts");
                Ok(CleanupJob {
                    id: row.get("id"),
                    kind: CleanupKind::parse(row.get::<String, _>("kind").as_str())?,
                    target_id: row.get("target_id"),
                    attempts: attempts.max(0) as u32,
                })
            })
            .collect::<anyhow::Result<Vec<_>>>()
            .map_err(RepoError::from)
    }

    async fn complete_cleanup_job(&self, job_id: i64) -> RepoResult<()> {
        sqlx::query("DELETE FROM cleanup_jobs WHERE id = ?")
            .bind(job_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn retry_cleanup_job(
        &self,
        job_id: i64,
        error: &str,
        next_attempt_at: i64,
    ) -> RepoResult<()> {
        sqlx::query(
            "UPDATE cleanup_jobs SET attempts = attempts + 1,
             next_attempt_at = ?, last_error = ? WHERE id = ?",
        )
        .bind(next_attempt_at)
        .bind(error.chars().take(1000).collect::<String>())
        .bind(job_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn cleanup_stats(&self) -> RepoResult<CleanupStats> {
        let row = sqlx::query(
            "SELECT COUNT(*) AS pending,
             COALESCE(SUM(CASE WHEN attempts > 0 THEN 1 ELSE 0 END), 0) AS failed
             FROM cleanup_jobs",
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(CleanupStats {
            pending: row.get::<i64, _>("pending").max(0) as u64,
            failed: row.get::<i64, _>("failed").max(0) as u64,
        })
    }
}
