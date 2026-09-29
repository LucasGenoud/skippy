use chrono::{Duration, Utc};
use sqlx::Row;
use sqlx::sqlite::SqliteRow;

use super::RepoResult;
use super::sqlite::{SqliteRepository, now, session_token_digest};
use crate::models::{ApiTokenView, TokenScope};

/// How stale `last_used_at` may get before a request rewrites it, so a busy
/// client does not turn every read into a write.
const LAST_USED_RESOLUTION_SECONDS: i64 = 60;

fn token_from_row(row: &SqliteRow) -> ApiTokenView {
    ApiTokenView {
        id: row.get("id"),
        name: row.get("name"),
        // The schema only admits known scopes; an unknown one reads as the
        // narrower of the two.
        scope: TokenScope::from_wire(row.get("scope")).unwrap_or(TokenScope::Read),
        created_at: row.get("created_at"),
        last_used_at: row.get("last_used_at"),
    }
}

impl SqliteRepository {
    pub async fn create_api_token(
        &self,
        id: &str,
        user_id: &str,
        name: &str,
        scope: TokenScope,
        secret: &str,
    ) -> RepoResult<ApiTokenView> {
        let created_at = now();
        sqlx::query(
            "INSERT INTO api_tokens (id, user_id, name, digest, scope, created_at)
             VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(id)
        .bind(user_id)
        .bind(name)
        .bind(session_token_digest(secret))
        .bind(scope.wire())
        .bind(&created_at)
        .execute(&self.pool)
        .await?;
        Ok(ApiTokenView {
            id: id.to_string(),
            name: name.to_string(),
            scope,
            created_at,
            last_used_at: None,
        })
    }

    pub async fn api_tokens_for_user(&self, user_id: &str) -> RepoResult<Vec<ApiTokenView>> {
        let rows = sqlx::query(
            "SELECT id, name, scope, created_at, last_used_at FROM api_tokens
             WHERE user_id = ? ORDER BY created_at, id",
        )
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(token_from_row).collect())
    }

    /// Revoke one of `user_id`'s tokens. False when they have none by that id.
    pub async fn delete_api_token(&self, id: &str, user_id: &str) -> RepoResult<bool> {
        let deleted = sqlx::query("DELETE FROM api_tokens WHERE id = ? AND user_id = ?")
            .bind(id)
            .bind(user_id)
            .execute(&self.pool)
            .await?;
        Ok(deleted.rows_affected() > 0)
    }

    pub async fn delete_api_tokens_for_user(&self, user_id: &str) -> RepoResult<()> {
        sqlx::query("DELETE FROM api_tokens WHERE user_id = ?")
            .bind(user_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// The account and scope behind a token secret, noting that it was used.
    pub async fn api_token_owner(&self, secret: &str) -> RepoResult<Option<(String, TokenScope)>> {
        let digest = session_token_digest(secret);
        let Some(row) = sqlx::query("SELECT id, user_id, scope FROM api_tokens WHERE digest = ?")
            .bind(&digest)
            .fetch_optional(&self.pool)
            .await?
        else {
            return Ok(None);
        };

        let stale = (Utc::now() - Duration::seconds(LAST_USED_RESOLUTION_SECONDS)).to_rfc3339();
        sqlx::query(
            "UPDATE api_tokens SET last_used_at = ?
             WHERE id = ? AND (last_used_at IS NULL OR last_used_at < ?)",
        )
        .bind(now())
        .bind(row.get::<String, _>("id"))
        .bind(stale)
        .execute(&self.pool)
        .await?;

        let scope = TokenScope::from_wire(row.get("scope")).unwrap_or(TokenScope::Read);
        Ok(Some((row.get("user_id"), scope)))
    }
}
