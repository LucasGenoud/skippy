use sqlx::SqlitePool;
const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL CHECK (trim(name) <> ''),
    email TEXT NOT NULL UNIQUE COLLATE NOCASE,
    password_hash TEXT NOT NULL,
    created_at TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS sessions (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS workspaces (
    id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK (trim(name) <> ''),
    notes_enabled INTEGER NOT NULL DEFAULT 1 CHECK (notes_enabled IN (0, 1)),
    board_enabled INTEGER NOT NULL DEFAULT 1 CHECK (board_enabled IN (0, 1)),
    is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
    created_at TEXT NOT NULL,
    CHECK (notes_enabled = 1 OR board_enabled = 1)
) STRICT;

CREATE TABLE IF NOT EXISTS workspace_members (
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (workspace_id, user_id)
) WITHOUT ROWID, STRICT;

CREATE TABLE IF NOT EXISTS stages (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK (trim(name) <> ''),
    color TEXT,
    position REAL NOT NULL DEFAULT 0,
    UNIQUE (workspace_id, name COLLATE NOCASE),
    UNIQUE (id, workspace_id)
) STRICT;

CREATE TABLE IF NOT EXISTS labels (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK (trim(name) <> ''),
    color TEXT,
    icon TEXT,
    position REAL NOT NULL DEFAULT 0,
    UNIQUE (workspace_id, name COLLATE NOCASE),
    UNIQUE (id, workspace_id)
) STRICT;

CREATE TABLE IF NOT EXISTS notes (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    created_by TEXT REFERENCES users(id) ON DELETE SET NULL,
    kind TEXT NOT NULL DEFAULT 'text'
        CHECK (kind IN ('text', 'markdown', 'checklist', 'audio')),
    title TEXT NOT NULL DEFAULT '',
    content TEXT NOT NULL DEFAULT '',
    items TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(items)),
    color TEXT NOT NULL DEFAULT 'default',
    pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0, 1)),
    archived INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
    trashed INTEGER NOT NULL DEFAULT 0 CHECK (trashed IN (0, 1)),
    position REAL NOT NULL DEFAULT 0,
    reminder_at TEXT,
    reminder_repeat TEXT CHECK (
        reminder_repeat IS NULL OR
        reminder_repeat IN ('daily', 'weekly', 'monthly', 'yearly')
    ),
    reminder_fired_at TEXT,
    transcript_status TEXT NOT NULL DEFAULT 'none'
        CHECK (transcript_status IN ('none', 'pending', 'done', 'failed')),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    trashed_at TEXT,
    last_editor_id TEXT REFERENCES users(id) ON DELETE SET NULL,
    stage_id TEXT,
    stage_position REAL NOT NULL DEFAULT 0,
    UNIQUE (id, workspace_id),
    FOREIGN KEY (stage_id, workspace_id)
        REFERENCES stages(id, workspace_id),
    CHECK (reminder_repeat IS NULL OR reminder_at IS NOT NULL),
    CHECK (
        (trashed = 0 AND trashed_at IS NULL) OR
        (trashed = 1 AND trashed_at IS NOT NULL)
    )
) STRICT;

-- A reminder on one checklist item, kept out of the note's `items` blob on
-- purpose. `items` is opaque, client-written content: a reminder living in it
-- would count as a content edit, would put the server-owned `fired_at` within
-- reach of any client, would be wiped wholesale by an offline client patching
-- a stale items array, and could not be swept by an indexed query. The row
-- exists only while its item exists and is unchecked; `update_note` prunes it
-- in the same transaction that writes the items.
CREATE TABLE IF NOT EXISTS note_item_reminders (
    note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    item_id TEXT NOT NULL CHECK (trim(item_id) <> ''),
    reminder_at TEXT NOT NULL,
    reminder_repeat TEXT CHECK (
        reminder_repeat IS NULL OR
        reminder_repeat IN ('daily', 'weekly', 'monthly', 'yearly')
    ),
    fired_at TEXT,
    PRIMARY KEY (note_id, item_id)
) WITHOUT ROWID, STRICT;

CREATE TABLE IF NOT EXISTS note_versions (
    id TEXT PRIMARY KEY,
    note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('text', 'markdown', 'checklist', 'audio')),
    title TEXT NOT NULL DEFAULT '',
    content TEXT NOT NULL DEFAULT '',
    items TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(items)),
    edited_by TEXT REFERENCES users(id) ON DELETE SET NULL,
    created_at TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS note_shares (
    note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (note_id, user_id)
) WITHOUT ROWID, STRICT;

-- workspace_id is repeated deliberately: the composite foreign keys make it
-- impossible for a note to carry a label from another workspace.
CREATE TABLE IF NOT EXISTS note_labels (
    workspace_id TEXT NOT NULL,
    note_id TEXT NOT NULL,
    label_id TEXT NOT NULL,
    PRIMARY KEY (note_id, label_id),
    FOREIGN KEY (note_id, workspace_id)
        REFERENCES notes(id, workspace_id) ON DELETE CASCADE,
    FOREIGN KEY (label_id, workspace_id)
        REFERENCES labels(id, workspace_id) ON DELETE CASCADE
) WITHOUT ROWID, STRICT;

CREATE TABLE IF NOT EXISTS checklist_history (
    note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    text TEXT NOT NULL COLLATE NOCASE CHECK (trim(text) <> ''),
    uses INTEGER NOT NULL DEFAULT 1 CHECK (uses > 0),
    last_used_at TEXT NOT NULL,
    PRIMARY KEY (note_id, text)
) WITHOUT ROWID, STRICT;

CREATE TABLE IF NOT EXISTS attachments (
    id TEXT PRIMARY KEY,
    note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    mime TEXT NOT NULL,
    filename TEXT NOT NULL DEFAULT '',
    size INTEGER NOT NULL DEFAULT 0 CHECK (size >= 0),
    created_at TEXT NOT NULL
) STRICT;

-- Text an OCR service read out of an image attachment. Derived, regenerable
-- data, so it is cached beside the attachment rather than stored on it: a row
-- exists only once recognition has succeeded (an empty `text` records a
-- picture with no words in it), and its absence is exactly the backlog the
-- startup pass works through. Keeping it out of `attachments` also means an
-- existing database picks the feature up on the next start, since a new table
-- is created where a new column would not be.
CREATE TABLE IF NOT EXISTS attachment_ocr (
    attachment_id TEXT PRIMARY KEY REFERENCES attachments(id) ON DELETE CASCADE,
    text TEXT NOT NULL,
    created_at TEXT NOT NULL
) WITHOUT ROWID, STRICT;

CREATE TABLE IF NOT EXISTS share_links (
    token TEXT PRIMARY KEY,
    created_by TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    target TEXT NOT NULL CHECK (target IN ('note', 'notes', 'board', 'label')),
    note_id TEXT REFERENCES notes(id) ON DELETE CASCADE,
    workspace_id TEXT REFERENCES workspaces(id) ON DELETE CASCADE,
    label_id TEXT REFERENCES labels(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    expires_at TEXT,
    CHECK (
        (target = 'note' AND note_id IS NOT NULL AND workspace_id IS NULL AND label_id IS NULL) OR
        (target IN ('notes', 'board') AND note_id IS NULL AND workspace_id IS NOT NULL AND label_id IS NULL) OR
        (target = 'label' AND note_id IS NULL AND workspace_id IS NULL AND label_id IS NOT NULL)
    )
) STRICT;

CREATE TABLE IF NOT EXISTS user_settings (
    user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    data TEXT NOT NULL CHECK (json_valid(data))
) STRICT;

-- Relational deletes enqueue their external side effects here in the same
-- transaction. A worker retries object-store and vector-index cleanup until
-- it succeeds, making process crashes and transient provider failures safe.
CREATE TABLE IF NOT EXISTS cleanup_jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL CHECK (
        kind IN ('attachment_blob', 'note_vector', 'workspace_vectors')
    ),
    target_id TEXT NOT NULL CHECK (trim(target_id) <> ''),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at TEXT NOT NULL,
    UNIQUE (kind, target_id)
) STRICT;

CREATE TABLE IF NOT EXISTS app_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID, STRICT;

CREATE INDEX IF NOT EXISTS idx_notes_workspace_position
    ON notes(workspace_id, position);
CREATE INDEX IF NOT EXISTS idx_notes_trash_purge
    ON notes(trashed_at) WHERE trashed = 1;
CREATE INDEX IF NOT EXISTS idx_notes_reminders
    ON notes(reminder_at) WHERE trashed = 0 AND reminder_fired_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_item_reminders_due
    ON note_item_reminders(reminder_at) WHERE fired_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_notes_stage
    ON notes(stage_id) WHERE stage_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_shares_user ON note_shares(user_id);
CREATE INDEX IF NOT EXISTS idx_note_labels_label ON note_labels(label_id);
CREATE INDEX IF NOT EXISTS idx_attachments_note ON attachments(note_id);
CREATE INDEX IF NOT EXISTS idx_share_links_creator ON share_links(created_by);
CREATE INDEX IF NOT EXISTS idx_share_links_note
    ON share_links(note_id) WHERE note_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_share_links_workspace
    ON share_links(workspace_id) WHERE workspace_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_share_links_label
    ON share_links(label_id) WHERE label_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_share_links_note_target
    ON share_links(created_by, note_id) WHERE target = 'note';
CREATE UNIQUE INDEX IF NOT EXISTS uq_share_links_workspace_target
    ON share_links(created_by, target, workspace_id)
    WHERE target IN ('notes', 'board');
CREATE UNIQUE INDEX IF NOT EXISTS uq_share_links_label_target
    ON share_links(created_by, label_id) WHERE target = 'label';
CREATE INDEX IF NOT EXISTS idx_versions_note ON note_versions(note_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_workspace_members_user ON workspace_members(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_workspaces_default
    ON workspaces(owner_id) WHERE is_default = 1;
CREATE INDEX IF NOT EXISTS idx_cleanup_jobs_due
    ON cleanup_jobs(next_attempt_at, id);
"#;

pub(super) async fn initialize(pool: &SqlitePool) -> anyhow::Result<()> {
    sqlx::raw_sql(SCHEMA).execute(pool).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
    use uuid::Uuid;

    use crate::models::User;
    use crate::store::AccountRepository;
    use crate::store::sqlite::SqliteRepository;

    #[tokio::test]
    async fn workspace_integrity_is_enforced_by_foreign_keys_and_checks() {
        let path = std::env::temp_dir().join(format!("skippy-schema-{}.db", Uuid::new_v4()));
        let path_text = path.to_str().unwrap();
        let repo = SqliteRepository::connect(path_text).await.unwrap();
        drop(repo);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(
                SqliteConnectOptions::new()
                    .filename(&path)
                    .foreign_keys(true),
            )
            .await
            .unwrap();

        sqlx::raw_sql(
            "INSERT INTO users (id, name, email, password_hash, created_at) VALUES
                 ('u1', 'One', 'one@example.test', 'hash', '2026-01-01T00:00:00Z'),
                 ('u2', 'Two', 'two@example.test', 'hash', '2026-01-01T00:00:00Z');
             INSERT INTO workspaces (id, owner_id, name, is_default, created_at) VALUES
                 ('w1', 'u1', 'One', 1, '2026-01-01T00:00:00Z'),
                 ('w2', 'u2', 'Two', 1, '2026-01-01T00:00:00Z');
             INSERT INTO stages (id, workspace_id, name) VALUES ('s2', 'w2', 'Other');
             INSERT INTO labels (id, workspace_id, name) VALUES ('l2', 'w2', 'Other');
             INSERT INTO notes
                 (id, workspace_id, created_by, created_at, updated_at)
             VALUES ('n1', 'w1', 'u1', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        )
        .execute(&pool)
        .await
        .unwrap();

        assert!(
            sqlx::query("UPDATE notes SET stage_id = 's2' WHERE id = 'n1'")
                .execute(&pool)
                .await
                .is_err()
        );
        assert!(
            sqlx::query(
                "INSERT INTO note_labels (workspace_id, note_id, label_id)
                 VALUES ('w1', 'n1', 'l2')",
            )
            .execute(&pool)
            .await
            .is_err()
        );
        assert!(
            sqlx::query("UPDATE notes SET pinned = 2 WHERE id = 'n1'")
                .execute(&pool)
                .await
                .is_err()
        );
        assert!(
            sqlx::query("UPDATE notes SET trashed = 1 WHERE id = 'n1'")
                .execute(&pool)
                .await
                .is_err()
        );
        sqlx::query(
            "UPDATE notes SET trashed = 1, trashed_at = '2026-01-02T00:00:00Z'
             WHERE id = 'n1'",
        )
        .execute(&pool)
        .await
        .unwrap();
        assert!(
            sqlx::query("UPDATE notes SET trashed = 0 WHERE id = 'n1'")
                .execute(&pool)
                .await
                .is_err()
        );
        sqlx::query("UPDATE notes SET trashed = 0, trashed_at = NULL WHERE id = 'n1'")
            .execute(&pool)
            .await
            .unwrap();

        pool.close().await;
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn session_bearer_tokens_are_hashed_at_rest() {
        let path = std::env::temp_dir().join(format!("skippy-session-{}.db", Uuid::new_v4()));
        let path_text = path.to_str().unwrap();
        let repo = SqliteRepository::connect(path_text).await.unwrap();
        repo.create_user(&User {
            id: "u1".to_string(),
            name: "One".to_string(),
            email: "one@example.test".to_string(),
            password_hash: "hash".to_string(),
        })
        .await
        .unwrap();
        repo.create_session("bearer-secret", "u1").await.unwrap();

        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(SqliteConnectOptions::new().filename(&path))
            .await
            .unwrap();
        let stored: String = sqlx::query_scalar("SELECT token FROM sessions")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_ne!(stored, "bearer-secret");
        assert_eq!(stored.len(), 64);
        assert_eq!(
            repo.user_id_for_token("bearer-secret").await.unwrap(),
            Some("u1".to_string())
        );
        pool.close().await;
        drop(repo);
        let _ = std::fs::remove_file(path);
    }
}
