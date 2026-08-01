use std::collections::HashMap;

use async_trait::async_trait;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{Row, SqlitePool};

use super::sqlite_rows::{note_from_row, now, user_from_row, version_from_row, workspace_from_row};
use super::sqlite_schema;
use super::{DeletedAccount, DeletedWorkspace, PurgedNote, RepoError, RepoResult, Repository};
use crate::models::*;

/// The workspaces a user belongs to: the ones they own plus the ones they were
/// invited to. Binds the user id twice.
const MY_WORKSPACES: &str = "SELECT id FROM workspaces WHERE owner_id = ?
     UNION SELECT workspace_id FROM workspace_members WHERE user_id = ?";

/// Predicate over the notes table (named by `alias`) for everything a user may
/// see: their own notes, notes shared with them directly, and every note held
/// by a workspace they belong to. Binds the user id four times.
fn visible_notes(alias: &str) -> String {
    format!(
        "({alias}.owner_id = ?
          OR {alias}.id IN (SELECT note_id FROM note_shares WHERE user_id = ?)
          OR {alias}.workspace_id IN ({MY_WORKSPACES}))"
    )
}

/// Drops every note/label pairing whose label no longer lives in the note's
/// workspace. Set-based and idempotent, so a bulk move cleans up in one go.
const PRUNE_MISMATCHED_LABELS: &str = "DELETE FROM note_labels
     WHERE NOT EXISTS (
         SELECT 1 FROM labels l
         JOIN notes n ON n.id = note_labels.note_id
         WHERE l.id = note_labels.label_id AND l.workspace_id = n.workspace_id
     )";

pub struct SqliteRepository {
    pool: SqlitePool,
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

    /// Decorate records into per-viewer views in bulk.
    async fn build_views(
        &self,
        records: Vec<NoteRecord>,
        viewer_id: &str,
    ) -> RepoResult<Vec<NoteView>> {
        if records.is_empty() {
            return Ok(vec![]);
        }
        // Labels per note. A label belongs to a workspace, so members all see
        // the same set; someone who reached the note through a direct share
        // instead is not in that workspace and sees none of them.
        let mut labels_by_note: HashMap<String, Vec<String>> = HashMap::new();
        for row in sqlx::query(&format!(
            "SELECT nl.note_id, nl.label_id FROM note_labels nl
             JOIN labels l ON l.id = nl.label_id
             WHERE l.workspace_id IN ({MY_WORKSPACES})"
        ))
        .bind(viewer_id)
        .bind(viewer_id)
        .fetch_all(&self.pool)
        .await?
        {
            labels_by_note
                .entry(row.get("note_id"))
                .or_default()
                .push(row.get("label_id"));
        }
        // Collaborators per note.
        let mut collabs_by_note: HashMap<String, Vec<UserPublic>> = HashMap::new();
        for row in sqlx::query(
            "SELECT ns.note_id, u.id, u.name FROM note_shares ns
             JOIN users u ON u.id = ns.user_id",
        )
        .fetch_all(&self.pool)
        .await?
        {
            collabs_by_note
                .entry(row.get("note_id"))
                .or_default()
                .push(UserPublic {
                    id: row.get("id"),
                    name: row.get("name"),
                });
        }
        // Attachments per note.
        let mut atts_by_note: HashMap<String, Vec<Attachment>> = HashMap::new();
        for row in sqlx::query(
            "SELECT id, note_id, mime, filename, size FROM attachments ORDER BY created_at",
        )
        .fetch_all(&self.pool)
        .await?
        {
            atts_by_note
                .entry(row.get("note_id"))
                .or_default()
                .push(Attachment {
                    id: row.get("id"),
                    mime: row.get("mime"),
                    filename: row.get("filename"),
                    size: row.get("size"),
                    url: None,
                });
        }
        let owners = self.user_directory().await?;

        Ok(records
            .into_iter()
            .map(|record| {
                let mut collaborators =
                    collabs_by_note.get(&record.id).cloned().unwrap_or_default();
                collaborators.sort_by(|a, b| a.name.cmp(&b.name));
                NoteView {
                    label_ids: labels_by_note.get(&record.id).cloned().unwrap_or_default(),
                    owner: owners.get(&record.owner_id).cloned().unwrap_or(UserPublic {
                        id: record.owner_id.clone(),
                        name: "?".to_string(),
                    }),
                    collaborators,
                    attachments: atts_by_note.get(&record.id).cloned().unwrap_or_default(),
                    note: record.fields(),
                }
            })
            .collect())
    }
}

#[async_trait]
impl Repository for SqliteRepository {
    // -- users & sessions ---------------------------------------------------

    async fn create_user(&self, user: &User) -> RepoResult<()> {
        let result = sqlx::query(
            "INSERT OR IGNORE INTO users
             (id, username, name, email, password_hash, created_at)
             VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(&user.id)
        // Kept for compatibility with databases created before email login.
        .bind(&user.email)
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
             SET username = ?, name = ?, email = ?, password_hash = ?
             WHERE id = ?",
        )
        .bind(email)
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
            "WITH shared_notes(note_id) AS (
                 SELECT id FROM notes WHERE owner_id = ?
                 UNION
                 SELECT note_id FROM note_shares WHERE user_id = ?
             ), my_workspaces(workspace_id) AS (
                 SELECT id FROM workspaces WHERE owner_id = ?
                 UNION
                 SELECT workspace_id FROM workspace_members WHERE user_id = ?
             ), participants(user_id) AS (
                 SELECT ?
                 UNION
                 SELECT n.owner_id FROM notes n
                 JOIN shared_notes sn ON sn.note_id = n.id
                 UNION
                 SELECT ns.user_id FROM note_shares ns
                 JOIN shared_notes sn ON sn.note_id = ns.note_id
                 UNION
                 SELECT w.owner_id FROM workspaces w
                 JOIN my_workspaces mw ON mw.workspace_id = w.id
                 UNION
                 SELECT m.user_id FROM workspace_members m
                 JOIN my_workspaces mw ON mw.workspace_id = m.workspace_id
             )
             SELECT user_id FROM participants",
        )
        .bind(user_id)
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

        // Snapshot every note whose index visibility changes. This includes
        // owned notes, direct shares, and notes visible through any workspace
        // the account owns or has joined.
        let affected_rows = sqlx::query(&format!(
            "SELECT id FROM notes WHERE {}",
            visible_notes("notes")
        ))
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&mut *tx)
        .await?;
        let affected_note_ids: Vec<String> =
            affected_rows.iter().map(|row| row.get("id")).collect();

        // Notify every participant of affected notes, plus every roster member
        // of a workspace that will lose this owner/member. Capture the roster
        // before the user deletion cascades memberships away.
        let audience_rows = sqlx::query(&format!(
            "WITH affected_notes AS (
                 SELECT n.id, n.workspace_id FROM notes n WHERE {}
             ), affected_workspaces AS (
                 SELECT id FROM workspaces WHERE owner_id = ?
                 UNION SELECT workspace_id FROM workspace_members WHERE user_id = ?
             ), audience(user_id) AS (
                 SELECT n.owner_id FROM notes n
                 JOIN affected_notes a ON a.id = n.id
                 UNION SELECT ns.user_id FROM note_shares ns
                 JOIN affected_notes a ON a.id = ns.note_id
                 UNION SELECT w.owner_id FROM workspaces w
                 JOIN affected_notes a ON a.workspace_id = w.id
                 UNION SELECT wm.user_id FROM workspace_members wm
                 JOIN affected_notes a ON a.workspace_id = wm.workspace_id
                 UNION SELECT w.owner_id FROM workspaces w
                 JOIN affected_workspaces a ON a.id = w.id
                 UNION SELECT wm.user_id FROM workspace_members wm
                 JOIN affected_workspaces a ON a.id = wm.workspace_id
             )
             SELECT user_id FROM audience",
            visible_notes("n")
        ))
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&mut *tx)
        .await?;
        let audience = audience_rows.iter().map(|row| row.get("user_id")).collect();

        // Account deletion owns the whole workspace lifecycle: every note in
        // one of this account's workspaces is deleted even when another user
        // authored it. Snapshot each note's actual owner because object-store
        // blobs are partitioned by note owner.
        let owned_rows = sqlx::query(
            "SELECT id, owner_id FROM notes
             WHERE owner_id = ?
                OR workspace_id IN (SELECT id FROM workspaces WHERE owner_id = ?)",
        )
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&mut *tx)
        .await?;
        let mut purged_notes: Vec<PurgedNote> = owned_rows
            .iter()
            .map(|row| PurgedNote {
                note_id: row.get("id"),
                owner_id: row.get("owner_id"),
                attachment_ids: Vec::new(),
            })
            .collect();
        for note in &mut purged_notes {
            let rows = sqlx::query("SELECT id FROM attachments WHERE note_id = ?")
                .bind(&note.note_id)
                .fetch_all(&mut *tx)
                .await?;
            note.attachment_ids = rows.iter().map(|row| row.get("id")).collect();
        }
        let purged_ids: std::collections::HashSet<&str> = purged_notes
            .iter()
            .map(|note| note.note_id.as_str())
            .collect();
        let remaining_note_ids = affected_note_ids
            .into_iter()
            .filter(|id| !purged_ids.contains(id.as_str()))
            .collect();

        sqlx::query(
            "DELETE FROM notes
             WHERE owner_id = ?
                OR workspace_id IN (SELECT id FROM workspaces WHERE owner_id = ?)",
        )
        .bind(user_id)
        .bind(user_id)
        .execute(&mut *tx)
        .await?;

        // Surviving collaboration history must not retain the deleted
        // account's identifier after its user row is gone.
        sqlx::query("UPDATE notes SET last_editor_id = NULL WHERE last_editor_id = ?")
            .bind(user_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE note_versions SET edited_by = NULL WHERE edited_by = ?")
            .bind(user_id)
            .execute(&mut *tx)
            .await?;

        sqlx::query("DELETE FROM users WHERE id = ?")
            .bind(user_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;

        Ok(Some(DeletedAccount {
            purged_notes,
            remaining_note_ids,
            audience,
        }))
    }

    async fn create_session(&self, token: &str, user_id: &str) -> RepoResult<()> {
        sqlx::query("INSERT INTO sessions (token, user_id, created_at) VALUES (?, ?, ?)")
            .bind(token)
            .bind(user_id)
            .bind(now())
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn user_id_for_token(&self, token: &str) -> RepoResult<Option<String>> {
        let row = sqlx::query("SELECT user_id FROM sessions WHERE token = ?")
            .bind(token)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|r| r.get("user_id")))
    }

    async fn delete_session(&self, token: &str) -> RepoResult<()> {
        sqlx::query("DELETE FROM sessions WHERE token = ?")
            .bind(token)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // -- workspaces -----------------------------------------------------------

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
        // without an explicit workspace and for a member's notes when they
        // leave another workspace. It has no delete button, but the server
        // does not trust that.
        if workspace.is_default {
            return Ok(None);
        }
        let mut tx = self.pool.begin().await?;
        let rows = sqlx::query("SELECT id, owner_id FROM notes WHERE workspace_id = ?")
            .bind(workspace_id)
            .fetch_all(&mut *tx)
            .await?;
        let mut purged_notes: Vec<PurgedNote> = rows
            .iter()
            .map(|row| PurgedNote {
                note_id: row.get("id"),
                owner_id: row.get("owner_id"),
                attachment_ids: Vec::new(),
            })
            .collect();
        for note in &mut purged_notes {
            let attachments = sqlx::query("SELECT id FROM attachments WHERE note_id = ?")
                .bind(&note.note_id)
                .fetch_all(&mut *tx)
                .await?;
            note.attachment_ids = attachments.iter().map(|row| row.get("id")).collect();
        }

        // Capture everyone whose visible state changes before note shares and
        // workspace membership cascade away.
        let audience_rows = sqlx::query(
            "SELECT owner_id AS user_id FROM workspaces WHERE id = ?
             UNION SELECT user_id FROM workspace_members WHERE workspace_id = ?
             UNION SELECT n.owner_id AS user_id FROM notes n WHERE n.workspace_id = ?
             UNION SELECT ns.user_id FROM note_shares ns
                   JOIN notes n ON n.id = ns.note_id
                  WHERE n.workspace_id = ?",
        )
        .bind(workspace_id)
        .bind(workspace_id)
        .bind(workspace_id)
        .bind(workspace_id)
        .fetch_all(&mut *tx)
        .await?;
        let audience = audience_rows.iter().map(|row| row.get("user_id")).collect();

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
        Ok(Some(DeletedWorkspace {
            purged_notes,
            audience,
        }))
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
        Ok(self
            .workspace_member_ids(workspace_id)
            .await?
            .contains(&user_id.to_string()))
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

    async fn remove_workspace_member(
        &self,
        workspace_id: &str,
        user_id: &str,
    ) -> RepoResult<Option<Vec<String>>> {
        let mut tx = self.pool.begin().await?;
        // The membership delete acquires SQLite's write lock and doubles as
        // the existence check. No note can be created into this workspace
        // between the snapshot, move, and membership removal.
        let removed =
            sqlx::query("DELETE FROM workspace_members WHERE workspace_id = ? AND user_id = ?")
                .bind(workspace_id)
                .bind(user_id)
                .execute(&mut *tx)
                .await?;
        if removed.rows_affected() == 0 {
            tx.rollback().await?;
            return Ok(None);
        }

        let rows = sqlx::query("SELECT id FROM notes WHERE workspace_id = ? AND owner_id = ?")
            .bind(workspace_id)
            .bind(user_id)
            .fetch_all(&mut *tx)
            .await?;
        let moved_ids = rows.iter().map(|row| row.get("id")).collect();
        sqlx::query(
            "UPDATE notes SET workspace_id = (
                 SELECT w.id FROM workspaces w
                 WHERE w.owner_id = notes.owner_id AND w.is_default = 1
             ),
                 stage_id = NULL
             WHERE workspace_id = ? AND owner_id = ?",
        )
        .bind(workspace_id)
        .bind(user_id)
        .execute(&mut *tx)
        .await?;
        sqlx::query(PRUNE_MISMATCHED_LABELS)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(Some(moved_ids))
    }

    // -- notes ---------------------------------------------------------------

    async fn notes_for_user(&self, user_id: &str) -> RepoResult<Vec<NoteView>> {
        let rows = sqlx::query(&format!(
            "SELECT * FROM notes WHERE {} ORDER BY position ASC",
            visible_notes("notes")
        ))
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;
        let records = rows.iter().map(note_from_row).collect();
        self.build_views(records, user_id).await
    }

    async fn note_view(&self, note_id: &str, viewer_id: &str) -> RepoResult<Option<NoteView>> {
        let Some(record) = self.note_record(note_id).await? else {
            return Ok(None);
        };
        Ok(self
            .build_views(vec![record], viewer_id)
            .await?
            .into_iter()
            .next())
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
             (id, owner_id, workspace_id, kind, title, content, items, color, pinned, archived,
              trashed, position, reminder_at, reminder_repeat, reminder_fired_at, created_at, updated_at, trashed_at,
              stage_id, stage_position)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                     CASE WHEN ? THEN ? ELSE NULL END, ?, ?)",
        )
        .bind(&note.id)
        .bind(&note.owner_id)
        .bind(&note.workspace_id)
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
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn delete_note(&self, note_id: &str) -> RepoResult<bool> {
        let result = sqlx::query("DELETE FROM notes WHERE id = ?")
            .bind(note_id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() > 0)
    }

    async fn min_position_for_user(&self, user_id: &str) -> RepoResult<f64> {
        let row = sqlx::query(&format!(
            "SELECT COALESCE(MIN(position), 0.0) AS m FROM notes WHERE {}",
            visible_notes("notes")
        ))
        .bind(user_id)
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
            "SELECT id, owner_id FROM notes
             WHERE trashed = 1 AND trashed_at IS NOT NULL AND trashed_at < ?",
        )
        .bind(cutoff)
        .fetch_all(&mut *tx)
        .await?;
        let mut purged: Vec<PurgedNote> = rows
            .iter()
            .map(|r| PurgedNote {
                note_id: r.get("id"),
                owner_id: r.get("owner_id"),
                attachment_ids: Vec::new(),
            })
            .collect();
        for note in &mut purged {
            let attachments = sqlx::query("SELECT id FROM attachments WHERE note_id = ?")
                .bind(&note.note_id)
                .fetch_all(&mut *tx)
                .await?;
            note.attachment_ids = attachments.iter().map(|r| r.get("id")).collect();
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

    // -- sharing ---------------------------------------------------------------

    async fn participant_ids(&self, note_id: &str) -> RepoResult<Vec<String>> {
        let rows = sqlx::query(
            "SELECT owner_id AS uid FROM notes WHERE id = ?
             UNION SELECT user_id AS uid FROM note_shares WHERE note_id = ?
             UNION SELECT w.owner_id AS uid FROM workspaces w
                 JOIN notes n ON n.workspace_id = w.id WHERE n.id = ?
             UNION SELECT m.user_id AS uid FROM workspace_members m
                 JOIN notes n ON n.workspace_id = m.workspace_id WHERE n.id = ?",
        )
        .bind(note_id)
        .bind(note_id)
        .bind(note_id)
        .bind(note_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(|r| r.get("uid")).collect())
    }

    async fn is_participant(&self, note_id: &str, user_id: &str) -> RepoResult<bool> {
        Ok(self
            .participant_ids(note_id)
            .await?
            .contains(&user_id.to_string()))
    }

    async fn add_collaborator(&self, note_id: &str, user_id: &str) -> RepoResult<()> {
        sqlx::query("INSERT OR IGNORE INTO note_shares (note_id, user_id) VALUES (?, ?)")
            .bind(note_id)
            .bind(user_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn remove_collaborator(&self, note_id: &str, user_id: &str) -> RepoResult<bool> {
        let result = sqlx::query("DELETE FROM note_shares WHERE note_id = ? AND user_id = ?")
            .bind(note_id)
            .bind(user_id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() > 0)
    }

    // -- labels ---------------------------------------------------------------

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
                "INSERT OR IGNORE INTO note_labels (note_id, label_id)
                 SELECT n.id, l.id FROM notes n
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
        sqlx::query(
            "DELETE FROM note_labels WHERE note_id = ? AND label_id NOT IN (
                 SELECT l.id FROM labels l
                 JOIN notes n ON n.workspace_id = l.workspace_id
                 WHERE n.id = ?
             )",
        )
        .bind(note_id)
        .bind(note_id)
        .execute(&self.pool)
        .await?;
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
        // Delete the membership-scoped stage first: its affected-row count is
        // the authorization decision. Clearing notes before this check would
        // let a non-member mutate another workspace merely by knowing a stage
        // id. Both operations remain invisible until this transaction commits.
        let result = sqlx::query(&format!(
            "DELETE FROM stages WHERE id = ? AND workspace_id IN ({MY_WORKSPACES})"
        ))
        .bind(stage_id)
        .bind(user_id)
        .bind(user_id)
        .execute(&mut *tx)
        .await?;
        if result.rows_affected() == 0 {
            tx.rollback().await?;
            return Ok(false);
        }
        // Notes outlive their column. There is no foreign key to do this for
        // us (see the schema), so the clear is explicit and shares the
        // transaction with the authorized delete.
        sqlx::query("UPDATE notes SET stage_id = NULL WHERE stage_id = ?")
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

    // -- checklist history -------------------------------------------------------

    async fn record_checked_items(&self, note_id: &str, texts: &[String]) -> RepoResult<()> {
        let mut tx = self.pool.begin().await?;
        for text in texts {
            let text = text.trim();
            if text.is_empty() || text.len() > 200 {
                continue;
            }
            sqlx::query(
                "INSERT INTO checklist_history (note_id, text, uses, last_used_at)
                 VALUES (?, ?, 1, ?)
                 ON CONFLICT (note_id, text)
                 DO UPDATE SET uses = uses + 1, last_used_at = excluded.last_used_at",
            )
            .bind(note_id)
            .bind(text)
            .bind(now())
            .execute(&mut *tx)
            .await?;
        }
        // Keep each note's dictionary bounded.
        sqlx::query(
            "DELETE FROM checklist_history WHERE note_id = ? AND text NOT IN (
                 SELECT text FROM checklist_history WHERE note_id = ?
                 ORDER BY last_used_at DESC LIMIT 500)",
        )
        .bind(note_id)
        .bind(note_id)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }

    /// History for every note the user can see (own or shared with them):
    /// suggestions are scoped per note, and collaborators on e.g. a shared
    /// grocery list share its history.
    async fn checklist_history(&self, user_id: &str) -> RepoResult<Vec<HistoryEntry>> {
        let rows = sqlx::query(&format!(
            "SELECT h.note_id, h.text, h.uses FROM checklist_history h
             JOIN notes n ON n.id = h.note_id
             WHERE {}
             ORDER BY h.uses DESC, h.last_used_at DESC",
            visible_notes("n")
        ))
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .iter()
            .map(|r| HistoryEntry {
                note_id: r.get("note_id"),
                text: r.get("text"),
                uses: r.get("uses"),
            })
            .collect())
    }

    // -- attachments ------------------------------------------------------------

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
        Ok(row.map(|r| {
            (
                r.get("note_id"),
                Attachment {
                    id: attachment_id.to_string(),
                    mime: r.get("mime"),
                    filename: r.get("filename"),
                    size: r.get("size"),
                    url: None,
                },
            )
        }))
    }

    async fn delete_attachment(&self, attachment_id: &str) -> RepoResult<bool> {
        let result = sqlx::query("DELETE FROM attachments WHERE id = ?")
            .bind(attachment_id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() > 0)
    }

    // -- per-user settings --------------------------------------------------------

    async fn settings_for_user(&self, user_id: &str) -> RepoResult<Option<String>> {
        let row = sqlx::query("SELECT data FROM user_settings WHERE user_id = ?")
            .bind(user_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|r| r.get("data")))
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

    // -- server metadata ----------------------------------------------------------

    async fn meta_get(&self, key: &str) -> RepoResult<Option<String>> {
        let row = sqlx::query("SELECT value FROM app_meta WHERE key = ?")
            .bind(key)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|r| r.get("value")))
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
}
