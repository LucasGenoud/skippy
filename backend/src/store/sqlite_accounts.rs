//! Users, sessions and password resets.

use sqlx::Row;

use super::sqlite::{
    SqliteRepository, USER_COLUMNS, enqueue_cleanup_tx, now, session_token_digest,
};
use super::sqlite_rows::user_from_row;
use super::{CleanupKind, DeletedAccount, PasswordReset, PurgedNote, RepoError, RepoResult};
use crate::models::*;

impl SqliteRepository {
    pub async fn create_user(&self, user: &User) -> RepoResult<()> {
        let result = sqlx::query(
            "INSERT OR IGNORE INTO users
             (id, name, email, password_hash, created_at)
             VALUES (?, ?, ?, ?, ?)",
        )
        .bind(&user.id)
        .bind(&user.name)
        .bind(&user.email)
        .bind(&user.password_hash)
        .bind(now())
        .execute(&self.pool)
        .await?;
        if result.rows_affected() == 0 {
            return Err(RepoError::Conflict(
                "email is already registered".to_string(),
            ));
        }
        Ok(())
    }

    pub async fn user_by_email(&self, email: &str) -> RepoResult<Option<User>> {
        let row = sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT {USER_COLUMNS} FROM users WHERE email = ? COLLATE NOCASE"
        )))
        .bind(email)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| user_from_row(&r)))
    }

    /// The account a single sign-on identity is tied to.
    pub async fn user_by_identity(&self, issuer: &str, subject: &str) -> RepoResult<Option<User>> {
        let row = sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT {USER_COLUMNS} FROM user_identities
             JOIN users ON users.id = user_identities.user_id
             WHERE issuer = ? AND subject = ?"
        )))
        .bind(issuer)
        .bind(subject)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| user_from_row(&r)))
    }

    /// Tie a single sign-on identity to an account. A no-op when the identity
    /// is already tied to one.
    pub async fn link_identity(
        &self,
        user_id: &str,
        issuer: &str,
        subject: &str,
    ) -> RepoResult<()> {
        sqlx::query(
            "INSERT OR IGNORE INTO user_identities (issuer, subject, user_id, created_at)
             VALUES (?, ?, ?, ?)",
        )
        .bind(issuer)
        .bind(subject)
        .bind(user_id)
        .bind(now())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn user_by_id(&self, id: &str) -> RepoResult<Option<User>> {
        let row = sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT {USER_COLUMNS} FROM users WHERE id = ?"
        )))
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| user_from_row(&r)))
    }

    pub async fn update_user(
        &self,
        id: &str,
        name: &str,
        email: &str,
        password_hash: &str,
    ) -> RepoResult<()> {
        let result = sqlx::query(
            "UPDATE OR IGNORE users
             SET name = ?, email = ?, password_hash = ?
             WHERE id = ?",
        )
        .bind(name)
        .bind(email)
        .bind(password_hash)
        .bind(id)
        .execute(&self.pool)
        .await?;
        if result.rows_affected() == 0 {
            return Err(RepoError::Conflict(
                "email is already registered".to_string(),
            ));
        }
        Ok(())
    }

    pub async fn account_audience(&self, user_id: &str) -> RepoResult<Vec<String>> {
        let rows = sqlx::query(
            "WITH my_workspaces(workspace_id) AS (
                 SELECT id FROM workspaces WHERE owner_id = ?
                 UNION
                 SELECT workspace_id FROM workspace_members WHERE user_id = ?
             ), affected_notes(note_id, workspace_id) AS (
                 SELECT id, workspace_id FROM notes
                 WHERE workspace_id IN (SELECT workspace_id FROM my_workspaces)
                 UNION
                 SELECT n.id, n.workspace_id FROM notes n
                 JOIN note_shares ns ON ns.note_id = n.id
                 WHERE ns.user_id = ?
             ), participants(user_id) AS (
                 SELECT ?
                 UNION
                 SELECT ns.user_id FROM note_shares ns
                 JOIN affected_notes n ON n.note_id = ns.note_id
                 UNION
                 SELECT w.owner_id FROM workspaces w
                 JOIN affected_notes n ON n.workspace_id = w.id
                 UNION
                 SELECT m.user_id FROM workspace_members m
                 JOIN affected_notes n ON n.workspace_id = m.workspace_id
             )
             SELECT user_id FROM participants",
        )
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|row| row.get("user_id")).collect())
    }

    pub async fn delete_account(&self, user_id: &str) -> RepoResult<Option<DeletedAccount>> {
        let mut tx = self.pool.begin().await?;
        let exists = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM users WHERE id = ?")
            .bind(user_id)
            .fetch_one(&mut *tx)
            .await?;
        if exists == 0 {
            return Ok(None);
        }

        // Capture everyone whose workspace roster or directly shared notes
        // will change before cascades remove those relationships.
        let audience_rows = sqlx::query(
            "WITH affected_workspaces(id) AS (
                 SELECT id FROM workspaces WHERE owner_id = ?
                 UNION SELECT workspace_id FROM workspace_members WHERE user_id = ?
             ), audience(user_id) AS (
                 SELECT w.owner_id FROM workspaces w
                 JOIN affected_workspaces a ON a.id = w.id
                 UNION SELECT wm.user_id FROM workspace_members wm
                 JOIN affected_workspaces a ON a.id = wm.workspace_id
                 UNION SELECT ns2.user_id FROM note_shares ns2
                 WHERE ns2.note_id IN (
                     SELECT note_id FROM note_shares WHERE user_id = ?
                 )
             )
             SELECT user_id FROM audience WHERE user_id <> ?",
        )
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&mut *tx)
        .await?;
        let audience = audience_rows.iter().map(|row| row.get("user_id")).collect();

        // Account deletion owns the whole workspace lifecycle: every note in
        // one of this account's workspaces is deleted even when another user
        // created it. Notes created in other workspaces are intentionally not
        // selected and survive with created_by cleared by the foreign key.
        let owned_rows = sqlx::query(
            "SELECT id FROM notes
             WHERE workspace_id IN (SELECT id FROM workspaces WHERE owner_id = ?)",
        )
        .bind(user_id)
        .fetch_all(&mut *tx)
        .await?;
        let purged_notes: Vec<PurgedNote> = owned_rows
            .iter()
            .map(|row| PurgedNote {
                note_id: row.get("id"),
            })
            .collect();
        for note in &purged_notes {
            let rows = sqlx::query("SELECT id FROM attachments WHERE note_id = ?")
                .bind(&note.note_id)
                .fetch_all(&mut *tx)
                .await?;
            for row in rows {
                let attachment_id: String = row.get("id");
                enqueue_cleanup_tx(&mut tx, CleanupKind::AttachmentBlob, &attachment_id).await?;
            }
        }
        let deleted_workspace_ids: Vec<String> =
            sqlx::query("SELECT id FROM workspaces WHERE owner_id = ?")
                .bind(user_id)
                .fetch_all(&mut *tx)
                .await?
                .into_iter()
                .map(|row| row.get("id"))
                .collect();
        for workspace_id in &deleted_workspace_ids {
            enqueue_cleanup_tx(&mut tx, CleanupKind::WorkspaceVectors, workspace_id).await?;
        }
        // Cascades owned workspaces (and their notes) while SET NULL preserves
        // notes and history attributed to this user in other workspaces.
        sqlx::query("DELETE FROM users WHERE id = ?")
            .bind(user_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;

        Ok(Some(DeletedAccount { audience }))
    }

    pub async fn create_session(&self, token: &str, user_id: &str) -> RepoResult<()> {
        sqlx::query("INSERT INTO sessions (token, user_id, created_at) VALUES (?, ?, ?)")
            .bind(session_token_digest(token))
            .bind(user_id)
            .bind(now())
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn user_id_for_token(&self, token: &str) -> RepoResult<Option<String>> {
        let digest = session_token_digest(token);
        let row = sqlx::query("SELECT token, user_id FROM sessions WHERE token = ? OR token = ?")
            .bind(&digest)
            // Legacy clean-break development databases may still contain the
            // bearer value. Accept it once and replace it with the digest.
            .bind(token)
            .fetch_optional(&self.pool)
            .await?;
        let Some(row) = row else {
            return Ok(None);
        };
        let stored: String = row.get("token");
        if stored == token {
            sqlx::query("UPDATE OR IGNORE sessions SET token = ? WHERE token = ?")
                .bind(&digest)
                .bind(token)
                .execute(&self.pool)
                .await?;
        }
        Ok(Some(row.get("user_id")))
    }

    pub async fn delete_session(&self, token: &str) -> RepoResult<()> {
        sqlx::query("DELETE FROM sessions WHERE token = ? OR token = ?")
            .bind(session_token_digest(token))
            .bind(token)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn delete_sessions_for_user(&self, user_id: &str) -> RepoResult<()> {
        sqlx::query("DELETE FROM sessions WHERE user_id = ?")
            .bind(user_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Every session of `user_id` except the one presenting `keep`.
    pub async fn delete_other_sessions(&self, user_id: &str, keep: &str) -> RepoResult<()> {
        sqlx::query("DELETE FROM sessions WHERE user_id = ? AND token != ? AND token != ?")
            .bind(user_id)
            .bind(session_token_digest(keep))
            .bind(keep)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // -- password resets ----------------------------------------------------

    pub async fn create_password_reset(
        &self,
        token: &str,
        user_id: &str,
        expires_at: &str,
    ) -> RepoResult<()> {
        let mut tx = self.pool.begin().await?;
        // Requesting a new link retires the previous one, and expired rows for
        // other accounts leave with it, so the table stays the size of the
        // resets actually in flight.
        sqlx::query("DELETE FROM password_resets WHERE user_id = ? OR expires_at < ?")
            .bind(user_id)
            .bind(now())
            .execute(&mut *tx)
            .await?;
        sqlx::query(
            "INSERT INTO password_resets (token, user_id, expires_at, created_at)
             VALUES (?, ?, ?, ?)",
        )
        .bind(session_token_digest(token))
        .bind(user_id)
        .bind(expires_at)
        .bind(now())
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }

    pub async fn consume_password_reset(&self, token: &str) -> RepoResult<Option<PasswordReset>> {
        let row = sqlx::query(
            "DELETE FROM password_resets WHERE token = ?
             RETURNING user_id, expires_at",
        )
        .bind(session_token_digest(token))
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|row| PasswordReset {
            user_id: row.get("user_id"),
            expires_at: row.get("expires_at"),
        }))
    }
}
