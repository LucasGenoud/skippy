use std::collections::{HashMap, HashSet};

use sha2::{Digest, Sha256};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{Row, Sqlite, SqlitePool, Transaction};

pub(super) use super::sqlite_rows::now;
use super::sqlite_rows::{note_from_row, version_from_row, workspace_from_row};
use super::sqlite_schema;
use super::{CleanupKind, DeletedWorkspace, PurgedNote, RepoError, RepoResult};
use crate::models::*;

/// The workspaces a user belongs to: the ones they own plus the ones they were
/// invited to. Binds the user id twice.
pub(super) const MY_WORKSPACES: &str = "SELECT id FROM workspaces WHERE owner_id = ?
     UNION SELECT workspace_id FROM workspace_members WHERE user_id = ?";

/// A `users` row plus its picture version, for [`user_from_row`].
pub(super) const USER_COLUMNS: &str =
    "users.*, (SELECT updated_at FROM user_avatars a WHERE a.user_id = users.id) AS avatar";

/// The picture version of the user aliased `u`, for building a [`UserPublic`].
pub(super) const AVATAR_OF_U: &str =
    "(SELECT updated_at FROM user_avatars a WHERE a.user_id = u.id) AS avatar";

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
    "SELECT token, created_by, target, note_id, workspace_id, collection_id, label_id, created_at, expires_at
     FROM share_links";

pub(super) fn session_token_digest(token: &str) -> String {
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
        let repo = Self { pool };
        // Only unfinished copies are reclaimed, never source workspaces.
        let copies: Vec<String> = sqlx::query_scalar("SELECT workspace_id FROM workspace_copies")
            .fetch_all(&repo.pool)
            .await?;
        for id in copies {
            repo.delete_workspace(&id)
                .await
                .map_err(|error| anyhow::anyhow!("{error:?}"))?;
        }
        Ok(repo)
    }
}

impl SqliteRepository {
    pub async fn insert_workspace_copy(&self, workspace: &Workspace) -> RepoResult<()> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("INSERT INTO workspaces(id,owner_id,name,created_at) VALUES(?,?,?,?)")
            .bind(&workspace.id)
            .bind(&workspace.owner_id)
            .bind(&workspace.name)
            .bind(&workspace.created_at)
            .execute(&mut *tx)
            .await?;
        sqlx::query("INSERT INTO workspace_copies(workspace_id) VALUES(?)")
            .bind(&workspace.id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(())
    }
    pub async fn finish_workspace_copy(&self, id: &str) -> RepoResult<()> {
        sqlx::query("DELETE FROM workspace_copies WHERE workspace_id=?")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn collections_for_user(&self, user_id: &str) -> RepoResult<Vec<Collection>> {
        Ok(sqlx::query_as::<_, Collection>(sqlx::AssertSqlSafe(format!("SELECT * FROM collections WHERE deleted=0 AND workspace_id IN ({MY_WORKSPACES}) AND workspace_id NOT IN (SELECT workspace_id FROM workspace_copies) ORDER BY position,id")))
            .bind(user_id).bind(user_id).fetch_all(&self.pool).await?)
    }

    pub async fn put_collection(&self, user_id: &str, c: &Collection) -> RepoResult<bool> {
        let result = sqlx::query(sqlx::AssertSqlSafe(format!("INSERT INTO collections(id,workspace_id,name,icon,color,layout,sort,position)
            SELECT ?,id,?,?,?,?,?,? FROM workspaces WHERE id=? AND id IN ({MY_WORKSPACES})
            ON CONFLICT(id) DO UPDATE SET name=excluded.name,icon=excluded.icon,color=excluded.color,
            layout=excluded.layout,sort=excluded.sort,position=excluded.position
            WHERE collections.workspace_id=excluded.workspace_id AND collections.deleted=0")))
            .bind(&c.id).bind(&c.name).bind(&c.icon).bind(&c.color).bind(&c.layout).bind(&c.sort).bind(c.position)
            .bind(&c.workspace_id).bind(user_id).bind(user_id).execute(&self.pool).await?;
        Ok(result.rows_affected() > 0)
    }

    pub async fn delete_collection(
        &self,
        user_id: &str,
        workspace_id: &str,
        id: &str,
    ) -> RepoResult<Option<Vec<String>>> {
        let mut tx = self.pool.begin().await?;
        let result = sqlx::query(sqlx::AssertSqlSafe(format!("UPDATE collections SET deleted=1 WHERE id=? AND workspace_id=? AND workspace_id IN ({MY_WORKSPACES})")))
            .bind(id).bind(workspace_id).bind(user_id).bind(user_id).execute(&mut *tx).await?;
        if result.rows_affected() == 0 {
            return Ok(None);
        }
        let ids = sqlx::query_scalar::<_, String>("SELECT id FROM notes WHERE collection_id=?")
            .bind(id)
            .fetch_all(&mut *tx)
            .await?;
        sqlx::query("UPDATE notes SET trashed=1,stage_id=NULL,trashed_at=COALESCE(trashed_at,?),updated_at=? WHERE collection_id=?")
            .bind(now()).bind(now()).bind(id).execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(Some(ids))
    }

    pub async fn put_smart_view(
        &self,
        user_id: &str,
        workspace_id: &str,
        view: &SavedView,
    ) -> RepoResult<bool> {
        let result = sqlx::query(sqlx::AssertSqlSafe(format!(
            "INSERT INTO smart_views (workspace_id, id, data)
             SELECT id, ?, ? FROM workspaces WHERE id = ? AND id IN ({MY_WORKSPACES})
             ON CONFLICT(workspace_id, id) DO UPDATE SET data = excluded.data"
        )))
        .bind(&view.id)
        .bind(serde_json::to_string(view)?)
        .bind(workspace_id)
        .bind(user_id)
        .bind(user_id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() > 0)
    }

    pub async fn delete_smart_view(
        &self,
        user_id: &str,
        workspace_id: &str,
        id: &str,
    ) -> RepoResult<bool> {
        let result = sqlx::query(sqlx::AssertSqlSafe(format!(
            "DELETE FROM smart_views WHERE workspace_id = ? AND id = ? AND workspace_id IN ({MY_WORKSPACES})"
        )))
        .bind(workspace_id).bind(id).bind(user_id).bind(user_id)
        .execute(&self.pool).await?;
        Ok(result.rows_affected() > 0)
    }

    pub async fn workspaces_for_user(&self, user_id: &str) -> RepoResult<Vec<WorkspaceView>> {
        let rows = sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT w.*, u.name AS owner_name, {AVATAR_OF_U} FROM workspaces w
             JOIN users u ON u.id = w.owner_id WHERE w.id IN ({MY_WORKSPACES}) AND w.id NOT IN (SELECT workspace_id FROM workspace_copies)
             ORDER BY w.is_default DESC, w.created_at ASC"
        )))
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;
        let owners: HashMap<String, UserPublic> = rows
            .iter()
            .map(|row| {
                (
                    row.get("id"),
                    UserPublic {
                        id: row.get("owner_id"),
                        name: row.get("owner_name"),
                        avatar: row.get("avatar"),
                    },
                )
            })
            .collect();
        let workspaces: Vec<Workspace> = rows.iter().map(workspace_from_row).collect();
        if workspaces.is_empty() {
            return Ok(vec![]);
        }

        let mut views: HashMap<String, Vec<SavedView>> = HashMap::new();
        for row in sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT workspace_id, data FROM smart_views WHERE workspace_id IN ({MY_WORKSPACES}) ORDER BY json_extract(data, '$.position'), id"
        ))).bind(user_id).bind(user_id).fetch_all(&self.pool).await? {
            views.entry(row.get("workspace_id")).or_default()
                .push(serde_json::from_str(row.get::<&str, _>("data"))?);
        }
        let collections = self.collections_for_user(user_id).await?;
        let mut members_by_workspace: HashMap<String, Vec<UserPublic>> = HashMap::new();
        for row in sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT m.workspace_id, u.id, u.name, {AVATAR_OF_U} FROM workspace_members m
             JOIN users u ON u.id = m.user_id WHERE m.workspace_id IN ({MY_WORKSPACES})"
        )))
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?
        {
            members_by_workspace
                .entry(row.get("workspace_id"))
                .or_default()
                .push(UserPublic {
                    id: row.get("id"),
                    name: row.get("name"),
                    avatar: row.get("avatar"),
                });
        }
        Ok(workspaces
            .into_iter()
            .map(|workspace| {
                let mut members = members_by_workspace
                    .get(&workspace.id)
                    .cloned()
                    .unwrap_or_default();
                members.sort_by(|a, b| a.name.cmp(&b.name));
                WorkspaceView {
                    collections: collections
                        .iter()
                        .filter(|c| c.workspace_id == workspace.id)
                        .cloned()
                        .collect(),
                    smart_views: views.remove(&workspace.id).unwrap_or_default(),
                    owner: owners[&workspace.id].clone(),
                    members,
                    id: workspace.id,
                    name: workspace.name,
                    notes_enabled: workspace.notes_enabled,
                    board_enabled: workspace.board_enabled,
                    is_default: workspace.is_default,
                    created_at: workspace.created_at,
                    // Resolved against the owner's provider by the handlers.
                    ai: WorkspaceAiView {
                        switches: workspace.ai,
                        ..Default::default()
                    },
                }
            })
            .collect())
    }

    pub async fn workspace(&self, workspace_id: &str) -> RepoResult<Option<Workspace>> {
        let row = sqlx::query("SELECT * FROM workspaces WHERE id = ?")
            .bind(workspace_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.as_ref().map(workspace_from_row))
    }

    pub async fn default_workspace(&self, user_id: &str) -> RepoResult<Option<Workspace>> {
        let row = sqlx::query("SELECT * FROM workspaces WHERE owner_id = ? AND is_default = 1")
            .bind(user_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.as_ref().map(workspace_from_row))
    }

    pub async fn insert_workspace(&self, workspace: &Workspace) -> RepoResult<()> {
        let result = sqlx::query(
            "INSERT OR IGNORE INTO workspaces
                (id, owner_id, name, notes_enabled, board_enabled, is_default, created_at,
                 ai_enabled, ai_labeling, ai_chat, ai_writing, assistant_access)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&workspace.id)
        .bind(&workspace.owner_id)
        .bind(&workspace.name)
        .bind(workspace.notes_enabled as i64)
        .bind(workspace.board_enabled as i64)
        .bind(workspace.is_default as i64)
        .bind(&workspace.created_at)
        .bind(workspace.ai.enabled as i64)
        .bind(workspace.ai.labeling as i64)
        .bind(workspace.ai.chat as i64)
        .bind(workspace.ai.writing as i64)
        .bind(workspace.ai.assistant_access as i64)
        .execute(&self.pool)
        .await?;
        if result.rows_affected() == 0 {
            return Err(RepoError::Conflict(
                "workspace id already exists".to_string(),
            ));
        }
        Ok(())
    }

    pub async fn update_workspace(&self, workspace: &Workspace) -> RepoResult<bool> {
        let result = sqlx::query(
            "UPDATE workspaces
             SET name = ?, notes_enabled = ?, board_enabled = ?, ai_enabled = ?,
                 ai_labeling = ?, ai_chat = ?, ai_writing = ?, assistant_access = ?
             WHERE id = ?",
        )
        .bind(&workspace.name)
        .bind(workspace.notes_enabled as i64)
        .bind(workspace.board_enabled as i64)
        .bind(workspace.ai.enabled as i64)
        .bind(workspace.ai.labeling as i64)
        .bind(workspace.ai.chat as i64)
        .bind(workspace.ai.writing as i64)
        .bind(workspace.ai.assistant_access as i64)
        .bind(&workspace.id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() > 0)
    }

    pub async fn delete_workspace(
        &self,
        workspace_id: &str,
    ) -> RepoResult<Option<DeletedWorkspace>> {
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

    pub async fn workspace_member_ids(&self, workspace_id: &str) -> RepoResult<Vec<String>> {
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

    pub async fn is_workspace_member(&self, workspace_id: &str, user_id: &str) -> RepoResult<bool> {
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

    pub async fn add_workspace_member(&self, workspace_id: &str, user_id: &str) -> RepoResult<()> {
        sqlx::query(
            "INSERT OR IGNORE INTO workspace_members (workspace_id, user_id) VALUES (?, ?)",
        )
        .bind(workspace_id)
        .bind(user_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn remove_workspace_member(
        &self,
        workspace_id: &str,
        user_id: &str,
    ) -> RepoResult<bool> {
        let removed =
            sqlx::query("DELETE FROM workspace_members WHERE workspace_id = ? AND user_id = ?")
                .bind(workspace_id)
                .bind(user_id)
                .execute(&self.pool)
                .await?;
        Ok(removed.rows_affected() > 0)
    }
}

impl SqliteRepository {
    pub async fn notes_for_user(&self, user_id: &str) -> RepoResult<Vec<NoteView>> {
        let rows = sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT * FROM notes WHERE {} AND workspace_id NOT IN (SELECT workspace_id FROM workspace_copies) ORDER BY position ASC",
            visible_notes("notes")
        )))
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;
        let records = rows.iter().map(note_from_row).collect();
        super::sqlite_views::build_note_views(&self.pool, records, user_id).await
    }

    /// Ids of the notes `user_id` can see in one workspace, without building
    /// their views. Narrows search and chat retrieval to the open workspace.
    pub async fn visible_note_ids_in(
        &self,
        user_id: &str,
        workspace_id: &str,
    ) -> RepoResult<HashSet<String>> {
        let ids: Vec<String> = sqlx::query_scalar(sqlx::AssertSqlSafe(format!(
            "SELECT id FROM notes WHERE workspace_id = ? AND {} AND workspace_id NOT IN (SELECT workspace_id FROM workspace_copies)",
            visible_notes("notes")
        )))
        .bind(workspace_id)
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(ids.into_iter().collect())
    }

    /// Every workspace holding a note `user_id` can see, direct shares
    /// included: the collections an unscoped search or chat reads.
    pub async fn visible_note_workspaces(&self, user_id: &str) -> RepoResult<Vec<String>> {
        Ok(sqlx::query_scalar(sqlx::AssertSqlSafe(format!(
            "SELECT DISTINCT workspace_id FROM notes WHERE {} AND workspace_id NOT IN (SELECT workspace_id FROM workspace_copies)",
            visible_notes("notes")
        )))
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn note_view(&self, note_id: &str, viewer_id: &str) -> RepoResult<Option<NoteView>> {
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

    pub async fn note_record_for_user(
        &self,
        note_id: &str,
        user_id: &str,
    ) -> RepoResult<Option<NoteRecord>> {
        let row = sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT * FROM notes WHERE id = ? AND {}",
            visible_notes("notes")
        )))
        .bind(note_id)
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| note_from_row(&r)))
    }

    pub async fn note_record(&self, note_id: &str) -> RepoResult<Option<NoteRecord>> {
        let row = sqlx::query("SELECT * FROM notes WHERE id = ?")
            .bind(note_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|r| note_from_row(&r)))
    }

    pub async fn insert_note(&self, note: &NoteRecord) -> RepoResult<()> {
        let result = sqlx::query(
            "INSERT OR IGNORE INTO notes
             (id, workspace_id, created_by, kind, title, content, items, color, pinned, archived,
              trashed, position, grid_span, reminder_at, reminder_repeat, reminder_fired_at, created_at, updated_at, trashed_at,
              stage_id, stage_position, collection_id, transcript_status, pattern)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                     CASE WHEN ? THEN ? ELSE NULL END, ?, ?, ?, ?, ?)",
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
        .bind(note.grid_span)
        .bind(&note.reminder_at)
        .bind(&note.reminder_repeat)
        .bind(&note.reminder_fired_at)
        .bind(&note.created_at)
        .bind(&note.updated_at)
        .bind(note.trashed as i64)
        .bind(now())
        .bind(&note.stage_id)
        .bind(note.stage_position)
        .bind(&note.collection_id)
        .bind(&note.transcript_status)
        .bind(&note.pattern)
        .execute(&self.pool)
        .await?;
        if result.rows_affected() == 0 {
            return Err(RepoError::Conflict("note id already exists".to_string()));
        }
        Ok(())
    }

    pub async fn update_note(
        &self,
        note: &NoteRecord,
        expected_updated_at: Option<&str>,
    ) -> RepoResult<()> {
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
        let result = sqlx::query(
            "UPDATE notes SET workspace_id = ?, kind = ?, title = ?, content = ?, items = ?,
             color = ?, pattern = ?, pinned = ?, archived = ?, position = ?, grid_span = ?, reminder_at = ?,
             reminder_repeat = ?, reminder_fired_at = ?, updated_at = ?, last_editor_id = ?,
             stage_id = ?, stage_position = ?, collection_id = ?,
             trashed_at = CASE
                 WHEN ? AND trashed = 0 THEN ?
                 WHEN NOT ? THEN NULL
                 ELSE trashed_at
             END,
             trashed = ?
             WHERE id = ? AND (? IS NULL OR updated_at = ?)",
        )
        .bind(&note.workspace_id)
        .bind(&note.kind)
        .bind(&note.title)
        .bind(&note.content)
        .bind(serde_json::to_string(&note.items)?)
        .bind(&note.color)
        .bind(&note.pattern)
        .bind(note.pinned as i64)
        .bind(note.archived as i64)
        .bind(note.position)
        .bind(note.grid_span)
        .bind(&note.reminder_at)
        .bind(&note.reminder_repeat)
        .bind(&note.reminder_fired_at)
        .bind(&note.updated_at)
        .bind(&note.last_editor_id)
        .bind(&note.stage_id)
        .bind(note.stage_position)
        .bind(&note.collection_id)
        .bind(note.trashed as i64)
        .bind(now())
        .bind(note.trashed as i64)
        .bind(note.trashed as i64)
        .bind(&note.id)
        .bind(expected_updated_at)
        .bind(expected_updated_at)
        .execute(&mut *tx)
        .await?;
        if result.rows_affected() == 0 {
            return Err(RepoError::Conflict("note changed elsewhere".to_string()));
        }
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

    pub async fn delete_note(&self, note_id: &str) -> RepoResult<bool> {
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

    pub async fn min_position_for_user(&self, user_id: &str) -> RepoResult<f64> {
        let row = sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT COALESCE(MIN(position), 0.0) AS m FROM notes WHERE {}",
            visible_notes("notes")
        )))
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(row.get("m"))
    }

    pub async fn reorder_for_user(&self, user_id: &str, ids: &[String]) -> RepoResult<()> {
        let statement = format!(
            "UPDATE notes SET position = ? WHERE id = ? AND {}",
            visible_notes("notes")
        );
        let mut tx = self.pool.begin().await?;
        for (i, id) in ids.iter().enumerate() {
            sqlx::query(sqlx::AssertSqlSafe(statement.as_str()))
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

    pub async fn purge_trash_before(&self, cutoff: &str) -> RepoResult<Vec<PurgedNote>> {
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

    pub async fn all_note_ids(&self) -> RepoResult<Vec<String>> {
        let rows = sqlx::query("SELECT id FROM notes")
            .fetch_all(&self.pool)
            .await?;
        Ok(rows.iter().map(|r| r.get("id")).collect())
    }

    // -- version history ----------------------------------------------------

    pub async fn insert_note_version(&self, version: &NoteVersion) -> RepoResult<()> {
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

    pub async fn note_versions(&self, note_id: &str) -> RepoResult<Vec<NoteVersion>> {
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

    pub async fn note_version(
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

    pub async fn set_transcript(
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
