use std::collections::HashMap;

use async_trait::async_trait;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{Row, SqlitePool};

use super::{RepoError, RepoResult, Repository};
use crate::models::*;

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE COLLATE NOCASE,
    password_hash TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS notes (
    id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind TEXT NOT NULL DEFAULT 'text',
    title TEXT NOT NULL DEFAULT '',
    content TEXT NOT NULL DEFAULT '',
    items TEXT NOT NULL DEFAULT '[]',
    color TEXT NOT NULL DEFAULT 'default',
    pinned INTEGER NOT NULL DEFAULT 0,
    archived INTEGER NOT NULL DEFAULT 0,
    trashed INTEGER NOT NULL DEFAULT 0,
    position REAL NOT NULL DEFAULT 0,
    reminder_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    trashed_at TEXT
);
CREATE TABLE IF NOT EXISTS note_shares (
    note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (note_id, user_id)
);
CREATE TABLE IF NOT EXISTS labels (
    id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    UNIQUE (owner_id, name COLLATE NOCASE)
);
CREATE TABLE IF NOT EXISTS note_labels (
    note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    label_id TEXT NOT NULL REFERENCES labels(id) ON DELETE CASCADE,
    PRIMARY KEY (note_id, label_id)
);
CREATE TABLE IF NOT EXISTS checklist_history (
    note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    text TEXT NOT NULL COLLATE NOCASE,
    uses INTEGER NOT NULL DEFAULT 1,
    last_used_at TEXT NOT NULL,
    PRIMARY KEY (note_id, text)
);
CREATE TABLE IF NOT EXISTS attachments (
    id TEXT PRIMARY KEY,
    note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    mime TEXT NOT NULL,
    filename TEXT NOT NULL DEFAULT '',
    size INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS user_settings (
    user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    data TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notes_owner ON notes(owner_id);
CREATE INDEX IF NOT EXISTS idx_shares_user ON note_shares(user_id);
"#;

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
        sqlx::raw_sql(SCHEMA).execute(&pool).await?;
        // Best-effort column migrations for databases created before these
        // fields existed; the errors on already-migrated DBs are harmless.
        for ddl in [
            "ALTER TABLE attachments ADD COLUMN filename TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE attachments ADD COLUMN size INTEGER NOT NULL DEFAULT 0",
        ] {
            let _ = sqlx::query(ddl).execute(&pool).await;
        }
        // Checklist history moved from per-user to per-note (suggestions must
        // never leak across notes). The old rows can't be attributed to a
        // note, so rebuild the table and seed it from each note's currently
        // checked items.
        if sqlx::query("SELECT note_id FROM checklist_history LIMIT 1")
            .fetch_optional(&pool)
            .await
            .is_err()
        {
            sqlx::query("DROP TABLE checklist_history").execute(&pool).await?;
            sqlx::raw_sql(SCHEMA).execute(&pool).await?;
            sqlx::query(
                "INSERT OR IGNORE INTO checklist_history (note_id, text, uses, last_used_at)
                 SELECT n.id, json_extract(je.value, '$.text'), 1, n.updated_at
                 FROM notes n, json_each(n.items) je
                 WHERE json_extract(je.value, '$.done') = 1
                   AND trim(coalesce(json_extract(je.value, '$.text'), '')) != ''",
            )
            .execute(&pool)
            .await?;
        }
        Ok(Self { pool })
    }
}

fn record_from_row(row: &sqlx::sqlite::SqliteRow) -> NoteRecord {
    let items_json: String = row.get("items");
    NoteRecord {
        id: row.get("id"),
        owner_id: row.get("owner_id"),
        kind: row.get("kind"),
        title: row.get("title"),
        content: row.get("content"),
        items: serde_json::from_str(&items_json).unwrap_or_default(),
        color: row.get("color"),
        pinned: row.get::<i64, _>("pinned") != 0,
        archived: row.get::<i64, _>("archived") != 0,
        trashed: row.get::<i64, _>("trashed") != 0,
        position: row.get("position"),
        reminder_at: row.get("reminder_at"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    }
}

fn user_from_row(row: &sqlx::sqlite::SqliteRow) -> User {
    User {
        id: row.get("id"),
        username: row.get("username"),
        password_hash: row.get("password_hash"),
    }
}

fn now() -> String {
    chrono::Utc::now().to_rfc3339()
}

impl SqliteRepository {
    /// Decorate records into per-viewer views in bulk.
    async fn build_views(
        &self,
        records: Vec<NoteRecord>,
        viewer_id: &str,
    ) -> RepoResult<Vec<NoteView>> {
        if records.is_empty() {
            return Ok(vec![]);
        }
        // The viewer's labels per note.
        let mut labels_by_note: HashMap<String, Vec<String>> = HashMap::new();
        for row in sqlx::query(
            "SELECT nl.note_id, nl.label_id FROM note_labels nl
             JOIN labels l ON l.id = nl.label_id WHERE l.owner_id = ?",
        )
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
            "SELECT ns.note_id, u.id, u.username FROM note_shares ns
             JOIN users u ON u.id = ns.user_id",
        )
        .fetch_all(&self.pool)
        .await?
        {
            collabs_by_note.entry(row.get("note_id")).or_default().push(UserPublic {
                id: row.get("id"),
                username: row.get("username"),
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
            atts_by_note.entry(row.get("note_id")).or_default().push(Attachment {
                id: row.get("id"),
                mime: row.get("mime"),
                filename: row.get("filename"),
                size: row.get("size"),
            });
        }
        // Owner usernames.
        let mut owners: HashMap<String, UserPublic> = HashMap::new();
        for row in sqlx::query("SELECT id, username FROM users")
            .fetch_all(&self.pool)
            .await?
        {
            let user = UserPublic { id: row.get("id"), username: row.get("username") };
            owners.insert(user.id.clone(), user);
        }

        Ok(records
            .into_iter()
            .map(|record| {
                let mut collaborators =
                    collabs_by_note.get(&record.id).cloned().unwrap_or_default();
                collaborators.sort_by(|a, b| a.username.cmp(&b.username));
                NoteView {
                    label_ids: labels_by_note.get(&record.id).cloned().unwrap_or_default(),
                    owner: owners.get(&record.owner_id).cloned().unwrap_or(UserPublic {
                        id: record.owner_id.clone(),
                        username: "?".to_string(),
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
            "INSERT OR IGNORE INTO users (id, username, password_hash, created_at) VALUES (?, ?, ?, ?)",
        )
        .bind(&user.id)
        .bind(&user.username)
        .bind(&user.password_hash)
        .bind(now())
        .execute(&self.pool)
        .await?;
        if result.rows_affected() == 0 {
            return Err(RepoError::Conflict("username is taken".to_string()));
        }
        Ok(())
    }

    async fn user_by_username(&self, username: &str) -> RepoResult<Option<User>> {
        let row = sqlx::query("SELECT * FROM users WHERE username = ? COLLATE NOCASE")
            .bind(username)
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

    // -- notes ---------------------------------------------------------------

    async fn notes_for_user(&self, user_id: &str) -> RepoResult<Vec<NoteView>> {
        let rows = sqlx::query(
            "SELECT * FROM notes WHERE owner_id = ?
             OR id IN (SELECT note_id FROM note_shares WHERE user_id = ?)
             ORDER BY position ASC",
        )
        .bind(user_id)
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;
        let records = rows.iter().map(record_from_row).collect();
        self.build_views(records, user_id).await
    }

    async fn note_view(&self, note_id: &str, viewer_id: &str) -> RepoResult<Option<NoteView>> {
        let Some(record) = self.note_record(note_id).await? else {
            return Ok(None);
        };
        Ok(self.build_views(vec![record], viewer_id).await?.into_iter().next())
    }

    async fn note_record(&self, note_id: &str) -> RepoResult<Option<NoteRecord>> {
        let row = sqlx::query("SELECT * FROM notes WHERE id = ?")
            .bind(note_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|r| record_from_row(&r)))
    }

    async fn insert_note(&self, note: &NoteRecord) -> RepoResult<()> {
        let result = sqlx::query(
            "INSERT OR IGNORE INTO notes
             (id, owner_id, kind, title, content, items, color, pinned, archived, trashed,
              position, reminder_at, created_at, updated_at, trashed_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)",
        )
        .bind(&note.id)
        .bind(&note.owner_id)
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
        .bind(&note.created_at)
        .bind(&note.updated_at)
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
            "UPDATE notes SET kind = ?, title = ?, content = ?, items = ?, color = ?,
             pinned = ?, archived = ?, position = ?, reminder_at = ?, updated_at = ?,
             trashed_at = CASE
                 WHEN ? AND trashed = 0 THEN ?
                 WHEN NOT ? THEN NULL
                 ELSE trashed_at
             END,
             trashed = ?
             WHERE id = ?",
        )
        .bind(&note.kind)
        .bind(&note.title)
        .bind(&note.content)
        .bind(serde_json::to_string(&note.items)?)
        .bind(&note.color)
        .bind(note.pinned as i64)
        .bind(note.archived as i64)
        .bind(note.position)
        .bind(&note.reminder_at)
        .bind(&note.updated_at)
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
        let row = sqlx::query(
            "SELECT COALESCE(MIN(position), 0.0) AS m FROM notes WHERE owner_id = ?
             OR id IN (SELECT note_id FROM note_shares WHERE user_id = ?)",
        )
        .bind(user_id)
        .bind(user_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(row.get("m"))
    }

    async fn reorder_for_user(&self, user_id: &str, ids: &[String]) -> RepoResult<()> {
        let mut tx = self.pool.begin().await?;
        for (i, id) in ids.iter().enumerate() {
            sqlx::query(
                "UPDATE notes SET position = ? WHERE id = ? AND (owner_id = ?
                 OR id IN (SELECT note_id FROM note_shares WHERE user_id = ?))",
            )
            .bind(((i + 1) as f64) * 1024.0)
            .bind(id)
            .bind(user_id)
            .bind(user_id)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    async fn purge_trash_before(&self, cutoff: &str) -> RepoResult<Vec<String>> {
        let rows = sqlx::query(
            "DELETE FROM notes WHERE trashed = 1 AND trashed_at IS NOT NULL AND trashed_at < ?
             RETURNING id",
        )
        .bind(cutoff)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(|r| r.get("id")).collect())
    }

    async fn all_note_ids(&self) -> RepoResult<Vec<String>> {
        let rows = sqlx::query("SELECT id FROM notes").fetch_all(&self.pool).await?;
        Ok(rows.iter().map(|r| r.get("id")).collect())
    }

    // -- sharing ---------------------------------------------------------------

    async fn participant_ids(&self, note_id: &str) -> RepoResult<Vec<String>> {
        let rows = sqlx::query(
            "SELECT owner_id AS uid FROM notes WHERE id = ?
             UNION SELECT user_id AS uid FROM note_shares WHERE note_id = ?",
        )
        .bind(note_id)
        .bind(note_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(|r| r.get("uid")).collect())
    }

    async fn is_participant(&self, note_id: &str, user_id: &str) -> RepoResult<bool> {
        Ok(self.participant_ids(note_id).await?.contains(&user_id.to_string()))
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
        let rows = sqlx::query(
            "SELECT id, name FROM labels WHERE owner_id = ? ORDER BY name COLLATE NOCASE",
        )
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(|r| Label { id: r.get("id"), name: r.get("name") }).collect())
    }

    async fn insert_label(&self, user_id: &str, label: &Label) -> RepoResult<()> {
        let result = sqlx::query("INSERT OR IGNORE INTO labels (id, owner_id, name) VALUES (?, ?, ?)")
            .bind(&label.id)
            .bind(user_id)
            .bind(&label.name)
            .execute(&self.pool)
            .await?;
        if result.rows_affected() == 0 {
            return Err(RepoError::Conflict("label already exists".to_string()));
        }
        Ok(())
    }

    async fn rename_label(&self, user_id: &str, label_id: &str, name: &str) -> RepoResult<bool> {
        let result = sqlx::query("UPDATE labels SET name = ? WHERE id = ? AND owner_id = ?")
            .bind(name)
            .bind(label_id)
            .bind(user_id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() > 0)
    }

    async fn delete_label(&self, user_id: &str, label_id: &str) -> RepoResult<bool> {
        let result = sqlx::query("DELETE FROM labels WHERE id = ? AND owner_id = ?")
            .bind(label_id)
            .bind(user_id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() > 0)
    }

    async fn set_note_labels(
        &self,
        note_id: &str,
        user_id: &str,
        label_ids: &[String],
    ) -> RepoResult<()> {
        let mut tx = self.pool.begin().await?;
        sqlx::query(
            "DELETE FROM note_labels WHERE note_id = ?
             AND label_id IN (SELECT id FROM labels WHERE owner_id = ?)",
        )
        .bind(note_id)
        .bind(user_id)
        .execute(&mut *tx)
        .await?;
        for label_id in label_ids {
            // The ownership subquery keeps users from attaching labels that
            // are not theirs.
            sqlx::query(
                "INSERT OR IGNORE INTO note_labels (note_id, label_id)
                 SELECT ?, id FROM labels WHERE id = ? AND owner_id = ?",
            )
            .bind(note_id)
            .bind(label_id)
            .bind(user_id)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
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
        let rows = sqlx::query(
            "SELECT h.note_id, h.text, h.uses FROM checklist_history h
             JOIN notes n ON n.id = h.note_id
             LEFT JOIN note_shares s ON s.note_id = n.id AND s.user_id = ?
             WHERE n.owner_id = ? OR s.user_id IS NOT NULL
             ORDER BY h.uses DESC, h.last_used_at DESC",
        )
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
}
