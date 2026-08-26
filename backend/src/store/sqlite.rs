use std::collections::HashMap;

use async_trait::async_trait;
use sha2::{Digest, Sha256};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{Row, Sqlite, SqlitePool, Transaction};

pub(super) use super::sqlite_rows::now;
use super::sqlite_rows::{
    item_reminder_from_row, note_from_row, user_from_row, version_from_row, workspace_from_row,
};
use super::sqlite_schema;
use super::{
    AccountRepository, CleanupKind, DeletedAccount, DeletedWorkspace, NoteRepository,
    PasswordReset, PurgedNote, RepoError, RepoResult, TaxonomyRepository, WorkspaceRepository,
};
use crate::models::*;

/// The workspaces a user belongs to: the ones they own plus the ones they were
/// invited to. Binds the user id twice.
pub(super) const MY_WORKSPACES: &str = "SELECT id FROM workspaces WHERE owner_id = ?
     UNION SELECT workspace_id FROM workspace_members WHERE user_id = ?";

/// Predicate over the notes table (named by `alias`) for everything a user may
/// see: notes shared with them directly and notes owned by a workspace they
/// belong to. Binds the user id three times.
pub(super) fn visible_notes(alias: &str) -> String {
    format!(
        "({alias}.id IN (SELECT note_id FROM note_shares WHERE user_id = ?)
          OR {alias}.workspace_id IN ({MY_WORKSPACES}))"
    )
}

pub(super) async fn enqueue_cleanup_tx(
    tx: &mut Transaction<'_, Sqlite>,
    kind: CleanupKind,
    target_id: &str,
) -> RepoResult<()> {
    sqlx::query(
        "INSERT OR IGNORE INTO cleanup_jobs
         (kind, target_id, next_attempt_at, created_at) VALUES (?, ?, 0, ?)",
    )
    .bind(kind.as_str())
    .bind(target_id)
    .bind(now())
    .execute(&mut **tx)
    .await?;
    Ok(())
}

/// Every column of a share link, so the three lookups select the same shape.
pub(super) const SHARE_LINK_COLUMNS: &str =
    "SELECT token, created_by, target, note_id, workspace_id, label_id, created_at, expires_at
     FROM share_links";

fn session_token_digest(token: &str) -> String {
    hex::encode(Sha256::digest(token.as_bytes()))
}

pub struct SqliteRepository {
    pub(super) pool: SqlitePool,
}

impl SqliteRepository {
    /// `path` may be a file path or ":memory:" (used by the test suite).
    pub async fn connect(path: &str) -> anyhow::Result<Self> {
        let options = SqliteConnectOptions::new()
            .filename(path)
            .create_if_missing(true)
            .foreign_keys(true);
        let pool = SqlitePoolOptions::new()
            // A single connection keeps ":memory:" databases coherent and is
            // plenty for a personal notes server.
            .max_connections(if path == ":memory:" { 1 } else { 5 })
            .connect_with(options)
            .await?;
        sqlite_schema::initialize(&pool).await?;
        Ok(Self { pool })
    }
}

impl SqliteRepository {
    /// Public display names for every account, keyed by id. One query beats a
    /// lookup per row in the decoration paths, and the table is small.
    async fn user_directory(&self) -> RepoResult<HashMap<String, UserPublic>> {
        let mut users = HashMap::new();
        for row in sqlx::query("SELECT id, name FROM users")
            .fetch_all(&self.pool)
            .await?
        {
            let user = UserPublic {
                id: row.get("id"),
                name: row.get("name"),
            };
            users.insert(user.id.clone(), user);
        }
        Ok(users)
    }
}

#[async_trait]
impl AccountRepository for SqliteRepository {
    // -- users & sessions ---------------------------------------------------

    async fn create_user(&self, user: &User) -> RepoResult<()> {
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

    async fn user_by_email(&self, email: &str) -> RepoResult<Option<User>> {
        let row = sqlx::query("SELECT * FROM users WHERE email = ? COLLATE NOCASE")
            .bind(email)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|r| user_from_row(&r)))
    }

    async fn user_by_id(&self, id: &str) -> RepoResult<Option<User>> {
        let row = sqlx::query("SELECT * FROM users WHERE id = ?")
            .bind(id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|r| user_from_row(&r)))
    }

    async fn update_user(
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

    async fn account_audience(&self, user_id: &str) -> RepoResult<Vec<String>> {
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

    async fn delete_account(&self, user_id: &str) -> RepoResult<Option<DeletedAccount>> {
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

    async fn create_session(&self, token: &str, user_id: &str) -> RepoResult<()> {
        sqlx::query("INSERT INTO sessions (token, user_id, created_at) VALUES (?, ?, ?)")
            .bind(session_token_digest(token))
            .bind(user_id)
            .bind(now())
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn user_id_for_token(&self, token: &str) -> RepoResult<Option<String>> {
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

    async fn delete_session(&self, token: &str) -> RepoResult<()> {
        sqlx::query("DELETE FROM sessions WHERE token = ? OR token = ?")
            .bind(session_token_digest(token))
            .bind(token)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn delete_sessions_for_user(&self, user_id: &str) -> RepoResult<()> {
        sqlx::query("DELETE FROM sessions WHERE user_id = ?")
            .bind(user_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // -- password resets ----------------------------------------------------

    async fn create_password_reset(
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

    async fn consume_password_reset(&self, token: &str) -> RepoResult<Option<PasswordReset>> {
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

#[async_trait]
impl WorkspaceRepository for SqliteRepository {
    async fn workspaces_for_user(&self, user_id: &str) -> RepoResult<Vec<WorkspaceView>> {
        let rows = sqlx::query(&format!(
            "SELECT * FROM workspaces WHERE id IN ({MY_WORKSPACES})
             ORDER BY is_default DESC, created_at ASC"
        ))
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;
        let workspaces: Vec<Workspace> = rows.iter().map(workspace_from_row).collect();
        if workspaces.is_empty() {
            return Ok(vec![]);
        }

        let mut members_by_workspace: HashMap<String, Vec<UserPublic>> = HashMap::new();
        for row in sqlx::query(
            "SELECT m.workspace_id, u.id, u.name FROM workspace_members m
             JOIN users u ON u.id = m.user_id",
        )
        .fetch_all(&self.pool)
        .await?
        {
            members_by_workspace
                .entry(row.get("workspace_id"))
                .or_default()
                .push(UserPublic {
                    id: row.get("id"),
                    name: row.get("name"),
                });
        }
        let users = self.user_directory().await?;

        Ok(workspaces
            .into_iter()
            .map(|workspace| {
                let mut members = members_by_workspace
                    .get(&workspace.id)
                    .cloned()
                    .unwrap_or_default();
                members.sort_by(|a, b| a.name.cmp(&b.name));
                WorkspaceView {
                    owner: users
                        .get(&workspace.owner_id)
                        .cloned()
                        .unwrap_or(UserPublic {
                            id: workspace.owner_id.clone(),
                            name: "?".to_string(),
                        }),
                    members,
                    id: workspace.id,
                    name: workspace.name,
                    notes_enabled: workspace.notes_enabled,
                    board_enabled: workspace.board_enabled,
                    is_default: workspace.is_default,
                    created_at: workspace.created_at,
                }
            })
            .collect())
    }

    async fn workspace(&self, workspace_id: &str) -> RepoResult<Option<Workspace>> {
        let row = sqlx::query("SELECT * FROM workspaces WHERE id = ?")
            .bind(workspace_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.as_ref().map(workspace_from_row))
    }

    async fn default_workspace(&self, user_id: &str) -> RepoResult<Option<Workspace>> {
        let row = sqlx::query("SELECT * FROM workspaces WHERE owner_id = ? AND is_default = 1")
            .bind(user_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.as_ref().map(workspace_from_row))
    }

    async fn insert_workspace(&self, workspace: &Workspace) -> RepoResult<()> {
        let result = sqlx::query(
            "INSERT OR IGNORE INTO workspaces
                (id, owner_id, name, notes_enabled, board_enabled, is_default, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&workspace.id)
        .bind(&workspace.owner_id)
        .bind(&workspace.name)
        .bind(workspace.notes_enabled as i64)
        .bind(workspace.board_enabled as i64)
        .bind(workspace.is_default as i64)
        .bind(&workspace.created_at)
        .execute(&self.pool)
        .await?;
        if result.rows_affected() == 0 {
            return Err(RepoError::Conflict(
                "workspace id already exists".to_string(),
            ));
        }
        Ok(())
    }

    async fn update_workspace(&self, workspace: &Workspace) -> RepoResult<bool> {
        let result = sqlx::query(
            "UPDATE workspaces
             SET name = ?, notes_enabled = ?, board_enabled = ?
             WHERE id = ?",
        )
        .bind(&workspace.name)
        .bind(workspace.notes_enabled as i64)
        .bind(workspace.board_enabled as i64)
        .bind(&workspace.id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() > 0)
    }

    async fn delete_workspace(&self, workspace_id: &str) -> RepoResult<Option<DeletedWorkspace>> {
        let Some(workspace) = self.workspace(workspace_id).await? else {
            return Ok(None);
        };
        // The default workspace is the permanent home for notes created
        // without an explicit workspace. It has no delete button, but the
        // server does not trust that.
        if workspace.is_default {
            return Ok(None);
        }
        let mut tx = self.pool.begin().await?;
        let rows = sqlx::query("SELECT id FROM notes WHERE workspace_id = ?")
            .bind(workspace_id)
            .fetch_all(&mut *tx)
            .await?;
        let purged_notes: Vec<PurgedNote> = rows
            .iter()
            .map(|row| PurgedNote {
                note_id: row.get("id"),
            })
            .collect();
        for note in &purged_notes {
            let attachments = sqlx::query("SELECT id FROM attachments WHERE note_id = ?")
                .bind(&note.note_id)
                .fetch_all(&mut *tx)
                .await?;
            for row in attachments {
                let attachment_id: String = row.get("id");
                enqueue_cleanup_tx(&mut tx, CleanupKind::AttachmentBlob, &attachment_id).await?;
            }
        }

        // Capture everyone whose visible state changes before note shares and
        // workspace membership cascade away.
        let audience_rows = sqlx::query(
            "SELECT owner_id AS user_id FROM workspaces WHERE id = ?
             UNION SELECT user_id FROM workspace_members WHERE workspace_id = ?
             UNION SELECT ns.user_id FROM note_shares ns
                   JOIN notes n ON n.id = ns.note_id
                  WHERE n.workspace_id = ?",
        )
        .bind(workspace_id)
        .bind(workspace_id)
        .bind(workspace_id)
        .fetch_all(&mut *tx)
        .await?;
        let audience = audience_rows.iter().map(|row| row.get("user_id")).collect();

        enqueue_cleanup_tx(&mut tx, CleanupKind::WorkspaceVectors, workspace_id).await?;

        // Delete notes explicitly so their dependent rows cascade before the
        // workspace row. Attachment bytes and search rows live outside this
        // database and are cleaned up by the handler from the snapshot above.
        sqlx::query("DELETE FROM notes WHERE workspace_id = ?")
            .bind(workspace_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM workspaces WHERE id = ?")
            .bind(workspace_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(Some(DeletedWorkspace { audience }))
    }

    async fn workspace_member_ids(&self, workspace_id: &str) -> RepoResult<Vec<String>> {
        let rows = sqlx::query(
            "SELECT owner_id AS uid FROM workspaces WHERE id = ?
             UNION SELECT user_id AS uid FROM workspace_members WHERE workspace_id = ?",
        )
        .bind(workspace_id)
        .bind(workspace_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(|r| r.get("uid")).collect())
    }

    async fn is_workspace_member(&self, workspace_id: &str, user_id: &str) -> RepoResult<bool> {
        let is_member: i64 = sqlx::query_scalar(
            "SELECT EXISTS (
                 SELECT 1 FROM workspaces WHERE id = ? AND owner_id = ?
                 UNION ALL
                 SELECT 1 FROM workspace_members WHERE workspace_id = ? AND user_id = ?
             )",
        )
        .bind(workspace_id)
        .bind(user_id)
        .bind(workspace_id)
        .bind(user_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(is_member != 0)
    }

    async fn add_workspace_member(&self, workspace_id: &str, user_id: &str) -> RepoResult<()> {
        sqlx::query(
            "INSERT OR IGNORE INTO workspace_members (workspace_id, user_id) VALUES (?, ?)",
        )
        .bind(workspace_id)
        .bind(user_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn remove_workspace_member(&self, workspace_id: &str, user_id: &str) -> RepoResult<bool> {
        let removed =
            sqlx::query("DELETE FROM workspace_members WHERE workspace_id = ? AND user_id = ?")
                .bind(workspace_id)
                .bind(user_id)
                .execute(&self.pool)
                .await?;
        Ok(removed.rows_affected() > 0)
    }
}

#[async_trait]
impl NoteRepository for SqliteRepository {
    async fn notes_for_user(&self, user_id: &str) -> RepoResult<Vec<NoteView>> {
        let rows = sqlx::query(&format!(
            "SELECT * FROM notes WHERE {} ORDER BY position ASC",
            visible_notes("notes")
        ))
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;
        let records = rows.iter().map(note_from_row).collect();
        super::sqlite_views::build_note_views(&self.pool, records, user_id).await
    }

    async fn note_view(&self, note_id: &str, viewer_id: &str) -> RepoResult<Option<NoteView>> {
        let Some(record) = self.note_record_for_user(note_id, viewer_id).await? else {
            return Ok(None);
        };
        Ok(
            super::sqlite_views::build_note_views(&self.pool, vec![record], viewer_id)
                .await?
                .into_iter()
                .next(),
        )
    }

    async fn note_record_for_user(
        &self,
        note_id: &str,
        user_id: &str,
    ) -> RepoResult<Option<NoteRecord>> {
        let row = sqlx::query(&format!(
            "SELECT * FROM notes WHERE id = ? AND {}",
            visible_notes("notes")
        ))
        .bind(note_id)
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| note_from_row(&r)))
    }

    async fn note_record(&self, note_id: &str) -> RepoResult<Option<NoteRecord>> {
        let row = sqlx::query("SELECT * FROM notes WHERE id = ?")
            .bind(note_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|r| note_from_row(&r)))
    }

    async fn insert_note(&self, note: &NoteRecord) -> RepoResult<()> {
        let result = sqlx::query(
            "INSERT OR IGNORE INTO notes
             (id, workspace_id, created_by, kind, title, content, items, color, pinned, archived,
              trashed, position, reminder_at, reminder_repeat, reminder_fired_at, created_at, updated_at, trashed_at,
              stage_id, stage_position)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                     CASE WHEN ? THEN ? ELSE NULL END, ?, ?)",
        )
        .bind(&note.id)
        .bind(&note.workspace_id)
        .bind(&note.created_by)
        .bind(&note.kind)
        .bind(&note.title)
        .bind(&note.content)
        .bind(serde_json::to_string(&note.items)?)
        .bind(&note.color)
        .bind(note.pinned as i64)
        .bind(note.archived as i64)
        .bind(note.trashed as i64)
        .bind(note.position)
        .bind(&note.reminder_at)
        .bind(&note.reminder_repeat)
        .bind(&note.reminder_fired_at)
        .bind(&note.created_at)
        .bind(&note.updated_at)
        .bind(note.trashed as i64)
        .bind(now())
        .bind(&note.stage_id)
        .bind(note.stage_position)
        .execute(&self.pool)
        .await?;
        if result.rows_affected() == 0 {
            return Err(RepoError::Conflict("note id already exists".to_string()));
        }
        Ok(())
    }

    async fn update_note(&self, note: &NoteRecord) -> RepoResult<()> {
        // trashed_at drives the 7-day purge; set it on the false->true edge.
        let mut tx = self.pool.begin().await?;
        // Label membership includes workspace_id as a composite integrity
        // boundary. Clear it before an ownership transfer; the destination's
        // labels can be applied by the same API patch afterward.
        sqlx::query(
            "DELETE FROM note_labels
             WHERE note_id = ? AND workspace_id <> ?",
        )
        .bind(&note.id)
        .bind(&note.workspace_id)
        .execute(&mut *tx)
        .await?;
        sqlx::query(
            "UPDATE notes SET workspace_id = ?, kind = ?, title = ?, content = ?, items = ?,
             color = ?, pinned = ?, archived = ?, position = ?, reminder_at = ?,
             reminder_repeat = ?, reminder_fired_at = ?, updated_at = ?, last_editor_id = ?,
             stage_id = ?, stage_position = ?,
             trashed_at = CASE
                 WHEN ? AND trashed = 0 THEN ?
                 WHEN NOT ? THEN NULL
                 ELSE trashed_at
             END,
             trashed = ?
             WHERE id = ?",
        )
        .bind(&note.workspace_id)
        .bind(&note.kind)
        .bind(&note.title)
        .bind(&note.content)
        .bind(serde_json::to_string(&note.items)?)
        .bind(&note.color)
        .bind(note.pinned as i64)
        .bind(note.archived as i64)
        .bind(note.position)
        .bind(&note.reminder_at)
        .bind(&note.reminder_repeat)
        .bind(&note.reminder_fired_at)
        .bind(&note.updated_at)
        .bind(&note.last_editor_id)
        .bind(&note.stage_id)
        .bind(note.stage_position)
        .bind(note.trashed as i64)
        .bind(now())
        .bind(note.trashed as i64)
        .bind(note.trashed as i64)
        .bind(&note.id)
        .execute(&mut *tx)
        .await?;
        // An item reminder outlives neither its item nor its unchecked state.
        // Pruning here, in the transaction that writes `items`, is what makes
        // the rule impossible to forget: version restores, chat writes, and
        // anything added later all go through this one seam. The surviving
        // ids travel as JSON because SQLite has no array parameter.
        let live_items = serde_json::to_string(
            &note
                .items
                .iter()
                .filter(|item| !item.done)
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
        )?;
        sqlx::query(
            "DELETE FROM note_item_reminders
             WHERE note_id = ? AND item_id NOT IN (SELECT value FROM json_each(?))",
        )
        .bind(&note.id)
        .bind(&live_items)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }

    async fn delete_note(&self, note_id: &str) -> RepoResult<bool> {
        let mut tx = self.pool.begin().await?;
        let exists: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM notes WHERE id = ?")
            .bind(note_id)
            .fetch_one(&mut *tx)
            .await?;
        if exists == 0 {
            return Ok(false);
        }
        let attachments = sqlx::query("SELECT id FROM attachments WHERE note_id = ?")
            .bind(note_id)
            .fetch_all(&mut *tx)
            .await?;
        for row in attachments {
            let attachment_id: String = row.get("id");
            enqueue_cleanup_tx(&mut tx, CleanupKind::AttachmentBlob, &attachment_id).await?;
        }
        enqueue_cleanup_tx(&mut tx, CleanupKind::NoteVector, note_id).await?;
        sqlx::query("DELETE FROM notes WHERE id = ?")
            .bind(note_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(true)
    }

    async fn min_position_for_user(&self, user_id: &str) -> RepoResult<f64> {
        let row = sqlx::query(&format!(
            "SELECT COALESCE(MIN(position), 0.0) AS m FROM notes WHERE {}",
            visible_notes("notes")
        ))
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(row.get("m"))
    }

    async fn reorder_for_user(&self, user_id: &str, ids: &[String]) -> RepoResult<()> {
        let statement = format!(
            "UPDATE notes SET position = ? WHERE id = ? AND {}",
            visible_notes("notes")
        );
        let mut tx = self.pool.begin().await?;
        for (i, id) in ids.iter().enumerate() {
            sqlx::query(&statement)
                .bind(((i + 1) as f64) * 1024.0)
                .bind(id)
                .bind(user_id)
                .bind(user_id)
                .bind(user_id)
                .execute(&mut *tx)
                .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    async fn purge_trash_before(&self, cutoff: &str) -> RepoResult<Vec<PurgedNote>> {
        // Snapshot attachment ids before the DELETE cascades them away, the
        // caller still has to remove the blobs from the file store.
        let mut tx = self.pool.begin().await?;
        let rows = sqlx::query(
            "SELECT id FROM notes
             WHERE trashed = 1 AND trashed_at IS NOT NULL AND trashed_at < ?",
        )
        .bind(cutoff)
        .fetch_all(&mut *tx)
        .await?;
        let purged: Vec<PurgedNote> = rows
            .iter()
            .map(|r| PurgedNote {
                note_id: r.get("id"),
            })
            .collect();
        for note in &purged {
            let attachments = sqlx::query("SELECT id FROM attachments WHERE note_id = ?")
                .bind(&note.note_id)
                .fetch_all(&mut *tx)
                .await?;
            for row in attachments {
                let attachment_id: String = row.get("id");
                enqueue_cleanup_tx(&mut tx, CleanupKind::AttachmentBlob, &attachment_id).await?;
            }
            enqueue_cleanup_tx(&mut tx, CleanupKind::NoteVector, &note.note_id).await?;
            sqlx::query("DELETE FROM notes WHERE id = ?")
                .bind(&note.note_id)
                .execute(&mut *tx)
                .await?;
        }
        tx.commit().await?;
        Ok(purged)
    }

    async fn all_note_ids(&self) -> RepoResult<Vec<String>> {
        let rows = sqlx::query("SELECT id FROM notes")
            .fetch_all(&self.pool)
            .await?;
        Ok(rows.iter().map(|r| r.get("id")).collect())
    }

    // -- reminders ------------------------------------------------------------

    async fn due_reminders(&self, now: &str) -> RepoResult<Vec<NoteRecord>> {
        // julianday() understands RFC3339 offsets, so "10:00+02:00" compares
        // as the instant it names rather than as a string.
        let rows = sqlx::query(
            "SELECT * FROM notes
             WHERE reminder_at IS NOT NULL AND reminder_fired_at IS NULL
               AND trashed = 0 AND julianday(reminder_at) <= julianday(?)",
        )
        .bind(now)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(note_from_row).collect())
    }

    async fn mark_reminder_fired(
        &self,
        note_id: &str,
        reminder_at: &str,
        fired_at: &str,
    ) -> RepoResult<bool> {
        let result = sqlx::query(
            "UPDATE notes SET reminder_fired_at = ?
             WHERE id = ? AND reminder_at = ? AND reminder_fired_at IS NULL",
        )
        .bind(fired_at)
        .bind(note_id)
        .bind(reminder_at)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    async fn advance_recurring_reminder(
        &self,
        note_id: &str,
        reminder_at: &str,
        next_reminder_at: &str,
        advanced_at: &str,
    ) -> RepoResult<bool> {
        let result = sqlx::query(
            "UPDATE notes
             SET reminder_at = ?, reminder_fired_at = NULL, updated_at = ?
             WHERE id = ? AND reminder_at = ? AND reminder_fired_at IS NULL
               AND reminder_repeat IS NOT NULL",
        )
        .bind(next_reminder_at)
        .bind(advanced_at)
        .bind(note_id)
        .bind(reminder_at)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    // -- checklist item reminders --------------------------------------------

    async fn item_reminders(&self, note_id: &str) -> RepoResult<Vec<ItemReminder>> {
        let rows = sqlx::query(
            "SELECT item_id, reminder_at, reminder_repeat FROM note_item_reminders
             WHERE note_id = ? ORDER BY item_id",
        )
        .bind(note_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(item_reminder_from_row).collect())
    }

    async fn item_reminders_for_notes(
        &self,
        note_ids: &[String],
    ) -> RepoResult<HashMap<String, Vec<ItemReminder>>> {
        if note_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let ids = serde_json::to_string(note_ids)?;
        let rows = sqlx::query(
            "SELECT note_id, item_id, reminder_at, reminder_repeat FROM note_item_reminders
             WHERE note_id IN (SELECT value FROM json_each(?)) ORDER BY item_id",
        )
        .bind(&ids)
        .fetch_all(&self.pool)
        .await?;
        let mut by_note: HashMap<String, Vec<ItemReminder>> = HashMap::new();
        for row in &rows {
            by_note
                .entry(row.get("note_id"))
                .or_default()
                .push(item_reminder_from_row(row));
        }
        Ok(by_note)
    }

    async fn set_item_reminder(&self, note_id: &str, reminder: &ItemReminder) -> RepoResult<()> {
        // Writing the row clears fired_at: a rescheduled reminder is a new
        // alarm, exactly as `reset_delivered_reminder_if_rescheduled` treats a
        // moved note reminder.
        sqlx::query(
            "INSERT INTO note_item_reminders (note_id, item_id, reminder_at, reminder_repeat, fired_at)
             VALUES (?, ?, ?, ?, NULL)
             ON CONFLICT (note_id, item_id) DO UPDATE SET
                 reminder_at = excluded.reminder_at,
                 reminder_repeat = excluded.reminder_repeat,
                 fired_at = NULL",
        )
        .bind(note_id)
        .bind(&reminder.item_id)
        .bind(&reminder.reminder_at)
        .bind(&reminder.reminder_repeat)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn clear_item_reminder(&self, note_id: &str, item_id: &str) -> RepoResult<()> {
        sqlx::query("DELETE FROM note_item_reminders WHERE note_id = ? AND item_id = ?")
            .bind(note_id)
            .bind(item_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn due_item_reminders(&self, now: &str) -> RepoResult<Vec<DueItemReminder>> {
        // Aliased so the note's own reminder columns survive `n.*` untouched;
        // julianday() compares instants, so a non-UTC offset comes due at the
        // moment it names.
        let rows = sqlx::query(
            "SELECT n.*, r.item_id AS due_item_id,
                    r.reminder_at AS due_item_reminder_at,
                    r.reminder_repeat AS due_item_reminder_repeat
             FROM note_item_reminders r
             JOIN notes n ON n.id = r.note_id
             WHERE r.fired_at IS NULL AND n.trashed = 0
               AND julianday(r.reminder_at) <= julianday(?)",
        )
        .bind(now)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .iter()
            .map(|row| DueItemReminder {
                note: note_from_row(row),
                item_id: row.get("due_item_id"),
                reminder_at: row.get("due_item_reminder_at"),
                reminder_repeat: row.get("due_item_reminder_repeat"),
            })
            .collect())
    }

    async fn mark_item_reminder_fired(
        &self,
        note_id: &str,
        item_id: &str,
        reminder_at: &str,
        fired_at: &str,
    ) -> RepoResult<bool> {
        let result = sqlx::query(
            "UPDATE note_item_reminders SET fired_at = ?
             WHERE note_id = ? AND item_id = ? AND reminder_at = ? AND fired_at IS NULL",
        )
        .bind(fired_at)
        .bind(note_id)
        .bind(item_id)
        .bind(reminder_at)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    async fn advance_recurring_item_reminder(
        &self,
        note_id: &str,
        item_id: &str,
        reminder_at: &str,
        next_reminder_at: &str,
    ) -> RepoResult<bool> {
        let result = sqlx::query(
            "UPDATE note_item_reminders SET reminder_at = ?, fired_at = NULL
             WHERE note_id = ? AND item_id = ? AND reminder_at = ? AND fired_at IS NULL
               AND reminder_repeat IS NOT NULL",
        )
        .bind(next_reminder_at)
        .bind(note_id)
        .bind(item_id)
        .bind(reminder_at)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    // -- version history ----------------------------------------------------

    async fn insert_note_version(&self, version: &NoteVersion) -> RepoResult<()> {
        sqlx::query(
            "INSERT INTO note_versions
             (id, note_id, kind, title, content, items, edited_by, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&version.id)
        .bind(&version.note_id)
        .bind(&version.kind)
        .bind(&version.title)
        .bind(&version.content)
        .bind(serde_json::to_string(&version.items)?)
        .bind(&version.edited_by)
        .bind(&version.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn note_versions(&self, note_id: &str) -> RepoResult<Vec<NoteVersion>> {
        // rowid breaks ties for versions saved within the same second.
        let rows = sqlx::query(
            "SELECT id, note_id, kind, title, content, items, edited_by, created_at
             FROM note_versions WHERE note_id = ? ORDER BY created_at DESC, rowid DESC",
        )
        .bind(note_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(version_from_row).collect())
    }

    async fn note_version(
        &self,
        note_id: &str,
        version_id: &str,
    ) -> RepoResult<Option<NoteVersion>> {
        let row = sqlx::query(
            "SELECT id, note_id, kind, title, content, items, edited_by, created_at
             FROM note_versions WHERE id = ? AND note_id = ?",
        )
        .bind(version_id)
        .bind(note_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.as_ref().map(version_from_row))
    }

    async fn set_transcript(
        &self,
        note_id: &str,
        status: &str,
        content: Option<&str>,
    ) -> RepoResult<()> {
        // COALESCE keeps the existing content when we only move the status
        // (pending/failed pass content = NULL).
        sqlx::query(
            "UPDATE notes SET transcript_status = ?,
             content = COALESCE(?, content), updated_at = ? WHERE id = ?",
        )
        .bind(status)
        .bind(content)
        .bind(now())
        .bind(note_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}

#[async_trait]
impl TaxonomyRepository for SqliteRepository {
    async fn labels_for_user(&self, user_id: &str) -> RepoResult<Vec<Label>> {
        let rows = sqlx::query(&format!(
            "SELECT id, workspace_id, name, color, icon, position FROM labels
             WHERE workspace_id IN ({MY_WORKSPACES})
             ORDER BY position, name COLLATE NOCASE"
        ))
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

    async fn insert_label(&self, label: &Label) -> RepoResult<()> {
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

    async fn update_label(
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
        let result = sqlx::query(&format!(
            "UPDATE labels SET name = ?, color = ?, icon = ?, position = COALESCE(?, position)
             WHERE id = ? AND workspace_id IN ({MY_WORKSPACES})"
        ))
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

    async fn max_label_position(&self, workspace_id: &str) -> RepoResult<f64> {
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

    async fn delete_label(&self, user_id: &str, label_id: &str) -> RepoResult<bool> {
        let result = sqlx::query(&format!(
            "DELETE FROM labels WHERE id = ? AND workspace_id IN ({MY_WORKSPACES})"
        ))
        .bind(label_id)
        .bind(user_id)
        .bind(user_id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() > 0)
    }

    async fn set_note_labels(&self, note_id: &str, label_ids: &[String]) -> RepoResult<()> {
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

    async fn prune_foreign_labels(&self, note_id: &str) -> RepoResult<()> {
        // The composite foreign keys on note_labels make a mismatch
        // impossible. Kept at the repository seam for callers shared with
        // other storage implementations.
        let _ = note_id;
        Ok(())
    }

    // -- stages (board columns) ------------------------------------------------

    async fn stages_for_user(&self, user_id: &str) -> RepoResult<Vec<Stage>> {
        let rows = sqlx::query(&format!(
            "SELECT id, workspace_id, name, color, position FROM stages
             WHERE workspace_id IN ({MY_WORKSPACES})
             ORDER BY position, name COLLATE NOCASE"
        ))
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .iter()
            .map(|r| Stage {
                id: r.get("id"),
                workspace_id: r.get("workspace_id"),
                name: r.get("name"),
                color: r.get("color"),
                position: r.get("position"),
            })
            .collect())
    }

    async fn insert_stage(&self, stage: &Stage) -> RepoResult<()> {
        let result = sqlx::query(
            "INSERT OR IGNORE INTO stages (id, workspace_id, name, color, position)
             VALUES (?, ?, ?, ?, ?)",
        )
        .bind(&stage.id)
        .bind(&stage.workspace_id)
        .bind(&stage.name)
        .bind(&stage.color)
        .bind(stage.position)
        .execute(&self.pool)
        .await?;
        if result.rows_affected() == 0 {
            return Err(RepoError::Conflict("stage already exists".to_string()));
        }
        Ok(())
    }

    async fn update_stage(
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
        let result = sqlx::query(&format!(
            "UPDATE stages SET name = ?, color = ?, position = COALESCE(?, position)
             WHERE id = ? AND workspace_id IN ({MY_WORKSPACES})"
        ))
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

    async fn delete_stage(&self, user_id: &str, stage_id: &str) -> RepoResult<bool> {
        let mut tx = self.pool.begin().await?;
        // Resolve authorization before clearing dependent notes. The
        // composite stage/workspace foreign key then guarantees there are no
        // cross-workspace references hiding behind this operation.
        let exists: Option<i64> = sqlx::query_scalar(&format!(
            "SELECT 1 FROM stages WHERE id = ? AND workspace_id IN ({MY_WORKSPACES})"
        ))
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

    async fn max_stage_position(&self, workspace_id: &str) -> RepoResult<f64> {
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

    async fn prune_foreign_stage(&self, note_id: &str) -> RepoResult<()> {
        sqlx::query(
            "UPDATE notes SET stage_id = NULL
             WHERE id = ? AND stage_id IS NOT NULL AND stage_id NOT IN (
                 SELECT s.id FROM stages s
                 JOIN notes n ON n.workspace_id = s.workspace_id
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
