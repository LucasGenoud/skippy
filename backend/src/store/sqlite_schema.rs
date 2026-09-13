use sqlx::{Row, Sqlite, SqlitePool, Transaction};
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

-- One-shot password reset grants. The row holds a SHA-256 digest of the
-- token, never the token itself, so a database copy cannot be used to reset
-- anyone's password. A row is deleted the moment it is redeemed, and a new
-- request for the same account replaces any outstanding one.
CREATE TABLE IF NOT EXISTS password_resets (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at TEXT NOT NULL,
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

CREATE TABLE IF NOT EXISTS smart_views (
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    data TEXT NOT NULL CHECK (json_valid(data)),
    PRIMARY KEY (workspace_id, id)
) STRICT;

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
    grid_span INTEGER NOT NULL DEFAULT 1 CHECK (grid_span BETWEEN 1 AND 3),
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
CREATE INDEX IF NOT EXISTS idx_password_resets_user ON password_resets(user_id);
"#;

pub(super) async fn initialize(pool: &SqlitePool) -> anyhow::Result<()> {
    sqlx::raw_sql(SCHEMA).execute(pool).await?;
    migrate_collections(pool).await?;
    migrate_grid_span(pool).await?;
    sqlx::query("CREATE TABLE IF NOT EXISTS workspace_copies (workspace_id TEXT PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE) STRICT").execute(pool).await?;
    import_personal_views(pool).await?;
    Ok(())
}

async fn migrate_grid_span(pool: &SqlitePool) -> anyhow::Result<()> {
    let mut tx = pool.begin().await?;
    if !table_has_column(&mut tx, "notes", "grid_span").await? {
        sqlx::query(
            "ALTER TABLE notes ADD COLUMN grid_span INTEGER NOT NULL DEFAULT 1 CHECK (grid_span BETWEEN 1 AND 3)",
        )
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    Ok(())
}

async fn table_exists(tx: &mut Transaction<'_, Sqlite>, table: &str) -> anyhow::Result<bool> {
    Ok(sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?)",
    )
    .bind(table)
    .fetch_one(&mut **tx)
    .await?)
}

async fn table_has_column(
    tx: &mut Transaction<'_, Sqlite>,
    table: &str,
    column: &str,
) -> anyhow::Result<bool> {
    Ok(
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pragma_table_info(?) WHERE name=?)")
            .bind(table)
            .bind(column)
            .fetch_one(&mut **tx)
            .await?,
    )
}

// Run once, atomically, on both fresh and existing workspace schemas.
async fn migrate_collections(pool: &SqlitePool) -> anyhow::Result<()> {
    const CREATE_COLLECTIONS: &str = r#"
        CREATE TABLE collections (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            name TEXT NOT NULL CHECK (trim(name) <> ''),
            icon TEXT, color TEXT,
            layout TEXT NOT NULL DEFAULT 'masonry' CHECK (layout IN ('masonry','list','board')),
            sort TEXT NOT NULL DEFAULT 'custom' CHECK (sort IN ('custom','edited','newest','oldest')),
            position REAL NOT NULL DEFAULT 0,
            deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0,1)),
            UNIQUE(id, workspace_id)
        ) STRICT;
    "#;
    const FINISH_COLLECTIONS: &str = r#"
        CREATE INDEX IF NOT EXISTS idx_notes_workspace_position ON notes(workspace_id, position);
        CREATE INDEX IF NOT EXISTS idx_notes_trash_purge ON notes(trashed_at) WHERE trashed = 1;
        CREATE INDEX IF NOT EXISTS idx_notes_reminders ON notes(reminder_at) WHERE trashed = 0 AND reminder_fired_at IS NULL;
        CREATE INDEX IF NOT EXISTS idx_notes_stage ON notes(stage_id) WHERE stage_id IS NOT NULL;
        CREATE INDEX idx_notes_collection ON notes(collection_id,position);
        CREATE TRIGGER workspace_general AFTER INSERT ON workspaces BEGIN
            INSERT INTO collections(id,workspace_id,name) VALUES(NEW.id || '-general',NEW.id,'General');
        END;
        CREATE TRIGGER note_collection_insert AFTER INSERT ON notes WHEN NEW.collection_id IS NULL BEGIN
            UPDATE notes SET collection_id = (SELECT id FROM collections WHERE workspace_id=NEW.workspace_id AND deleted=0 ORDER BY position,id LIMIT 1) WHERE id=NEW.id;
        END;
        CREATE TRIGGER stage_collection_insert AFTER INSERT ON stages WHEN NEW.collection_id IS NULL BEGIN
            UPDATE stages SET collection_id = (SELECT id FROM collections WHERE workspace_id=NEW.workspace_id AND deleted=0 ORDER BY position,id LIMIT 1) WHERE id=NEW.id;
        END;
        CREATE TRIGGER note_collection_check BEFORE UPDATE OF collection_id,workspace_id,trashed ON notes BEGIN
            SELECT RAISE(ABORT,'invalid collection') WHERE NEW.collection_id IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM collections WHERE id=NEW.collection_id AND workspace_id=NEW.workspace_id AND (deleted=0 OR NEW.trashed=1));
        END;
        CREATE TRIGGER note_collection_create BEFORE INSERT ON notes WHEN NEW.collection_id IS NOT NULL BEGIN
            SELECT RAISE(ABORT,'invalid collection') WHERE NOT EXISTS (
                SELECT 1 FROM collections WHERE id=NEW.collection_id AND workspace_id=NEW.workspace_id AND (deleted=0 OR NEW.trashed=1));
        END;
        CREATE TRIGGER stage_collection_check BEFORE INSERT ON stages WHEN NEW.collection_id IS NOT NULL BEGIN
            SELECT RAISE(ABORT,'invalid collection') WHERE NOT EXISTS (
                SELECT 1 FROM collections WHERE id=NEW.collection_id AND workspace_id=NEW.workspace_id AND deleted=0);
        END;
        ALTER TABLE share_links ADD COLUMN collection_id TEXT REFERENCES collections(id);
        DROP INDEX uq_share_links_workspace_target;
        DROP INDEX uq_share_links_label_target;
        CREATE UNIQUE INDEX uq_share_links_workspace_target ON share_links(created_by,target,workspace_id,COALESCE(collection_id,'')) WHERE target IN ('notes','board');
        CREATE UNIQUE INDEX uq_share_links_label_target ON share_links(created_by,label_id,COALESCE(collection_id,'')) WHERE target='label';
        INSERT INTO app_meta VALUES('collections_v1','1');
    "#;
    let mut conn = pool.acquire().await?;
    sqlx::query("PRAGMA foreign_keys = OFF")
        .execute(&mut *conn)
        .await?;
    let result = async {
        use sqlx::Acquire;
        let mut tx = conn.begin().await?;
        let done: i64 = sqlx::query_scalar("SELECT count(*) FROM app_meta WHERE key = 'collections_v1'")
            .fetch_one(&mut *tx).await?;
        if done == 0 {
            let old_collections = table_exists(&mut tx, "collections").await?;
            let notes_have_collection =
                table_has_column(&mut tx, "notes", "collection_id").await?;
            let stages_have_collection =
                table_has_column(&mut tx, "stages", "collection_id").await?;

            if !old_collections {
                sqlx::raw_sql(CREATE_COLLECTIONS).execute(&mut *tx).await?;
                sqlx::raw_sql(r#"
                INSERT INTO collections (id,workspace_id,name,layout)
                    SELECT id || '-general',id,'General',CASE WHEN notes_enabled = 0 THEN 'board' ELSE 'masonry' END FROM workspaces;
                ALTER TABLE notes ADD COLUMN collection_id TEXT REFERENCES collections(id);
                UPDATE notes SET collection_id = workspace_id || '-general';
                CREATE TABLE stages_new (
                    id TEXT PRIMARY KEY,
                    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                    collection_id TEXT REFERENCES collections(id),
                    name TEXT NOT NULL CHECK (trim(name) <> ''),
                    color TEXT, position REAL NOT NULL DEFAULT 0,
                    UNIQUE(collection_id,name COLLATE NOCASE), UNIQUE(id,workspace_id)
                ) STRICT;
                INSERT INTO stages_new SELECT id,workspace_id,workspace_id || '-general',name,color,position FROM stages;
                DROP TABLE stages;
                ALTER TABLE stages_new RENAME TO stages;
                "#).execute(&mut *tx).await?;
            } else {
                anyhow::ensure!(
                    !table_has_column(&mut tx, "collections", "deleted").await?,
                    "collections migration marker is missing"
                );
                anyhow::ensure!(
                    notes_have_collection == stages_have_collection,
                    "cancelled collections migration has inconsistent note and stage tables"
                );

                sqlx::raw_sql(
                    "DROP TRIGGER IF EXISTS workspace_inbox;
                     ALTER TABLE collections RENAME TO collections_legacy;",
                )
                .execute(&mut *tx)
                .await?;
                sqlx::raw_sql(CREATE_COLLECTIONS).execute(&mut *tx).await?;
                sqlx::raw_sql(r#"
                    INSERT INTO collections(id,workspace_id,name,layout,position)
                        SELECT workspace_id || '-' || id,workspace_id,
                            CASE WHEN id='inbox' AND name='Inbox' THEN 'General' ELSE name END,
                            layout,position FROM collections_legacy;
                    INSERT INTO collections(id,workspace_id,name,layout)
                        SELECT w.id || '-general',w.id,'General',
                            CASE WHEN w.notes_enabled=0 THEN 'board' ELSE 'masonry' END
                        FROM workspaces w WHERE NOT EXISTS (
                            SELECT 1 FROM collections c WHERE c.workspace_id=w.id);
                "#).execute(&mut *tx).await?;

                if !notes_have_collection {
                    sqlx::raw_sql(r#"
                        ALTER TABLE notes ADD COLUMN collection_id TEXT REFERENCES collections(id);
                        UPDATE notes SET collection_id=(SELECT id FROM collections
                            WHERE workspace_id=notes.workspace_id ORDER BY position,id LIMIT 1);
                        CREATE TABLE stages_new (
                            id TEXT PRIMARY KEY,
                            workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                            collection_id TEXT REFERENCES collections(id),
                            name TEXT NOT NULL CHECK (trim(name) <> ''),
                            color TEXT, position REAL NOT NULL DEFAULT 0,
                            UNIQUE(collection_id,name COLLATE NOCASE), UNIQUE(id,workspace_id)
                        ) STRICT;
                        INSERT INTO stages_new SELECT id,workspace_id,
                            (SELECT id FROM collections WHERE workspace_id=stages.workspace_id ORDER BY position,id LIMIT 1),
                            name,color,position FROM stages;
                        DROP TABLE stages;
                        ALTER TABLE stages_new RENAME TO stages;
                    "#).execute(&mut *tx).await?;
                } else {
                    sqlx::raw_sql(r#"
                        CREATE TABLE stages_new (
                            id TEXT PRIMARY KEY,
                            workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                            collection_id TEXT REFERENCES collections(id),
                            name TEXT NOT NULL CHECK (trim(name) <> ''),
                            color TEXT, position REAL NOT NULL DEFAULT 0,
                            UNIQUE(collection_id,name COLLATE NOCASE), UNIQUE(id,workspace_id)
                        ) STRICT;
                        INSERT INTO stages_new SELECT id,workspace_id,
                            CASE WHEN EXISTS(SELECT 1 FROM collections WHERE id=stages.workspace_id || '-' || stages.collection_id)
                                THEN stages.workspace_id || '-' || stages.collection_id
                                ELSE (SELECT id FROM collections WHERE workspace_id=stages.workspace_id ORDER BY position,id LIMIT 1) END,
                            name,color,position FROM stages;
                        DROP TABLE stages;
                        ALTER TABLE stages_new RENAME TO stages;

                        CREATE TABLE notes_new (
                            id TEXT PRIMARY KEY,
                            workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                            collection_id TEXT REFERENCES collections(id),
                            created_by TEXT REFERENCES users(id) ON DELETE SET NULL,
                            kind TEXT NOT NULL DEFAULT 'text' CHECK (kind IN ('text','markdown','checklist','audio')),
                            title TEXT NOT NULL DEFAULT '', content TEXT NOT NULL DEFAULT '',
                            items TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(items)),
                            color TEXT NOT NULL DEFAULT 'default',
                            pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0,1)),
                            archived INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0,1)),
                            trashed INTEGER NOT NULL DEFAULT 0 CHECK (trashed IN (0,1)),
                            position REAL NOT NULL DEFAULT 0,
                            reminder_at TEXT,
                            reminder_repeat TEXT CHECK (reminder_repeat IS NULL OR reminder_repeat IN ('daily','weekly','monthly','yearly')),
                            reminder_fired_at TEXT,
                            transcript_status TEXT NOT NULL DEFAULT 'none' CHECK (transcript_status IN ('none','pending','done','failed')),
                            created_at TEXT NOT NULL, updated_at TEXT NOT NULL, trashed_at TEXT,
                            last_editor_id TEXT REFERENCES users(id) ON DELETE SET NULL,
                            stage_id TEXT, stage_position REAL NOT NULL DEFAULT 0,
                            UNIQUE(id,workspace_id),
                            FOREIGN KEY(stage_id,workspace_id) REFERENCES stages(id,workspace_id),
                            CHECK(reminder_repeat IS NULL OR reminder_at IS NOT NULL),
                            CHECK((trashed=0 AND trashed_at IS NULL) OR (trashed=1 AND trashed_at IS NOT NULL))
                        ) STRICT;
                        INSERT INTO notes_new(id,workspace_id,collection_id,created_by,kind,title,content,items,color,
                            pinned,archived,trashed,position,reminder_at,reminder_repeat,reminder_fired_at,
                            transcript_status,created_at,updated_at,trashed_at,last_editor_id,stage_id,stage_position)
                        SELECT id,workspace_id,
                            CASE WHEN EXISTS(SELECT 1 FROM collections WHERE id=notes.workspace_id || '-' || notes.collection_id)
                                THEN notes.workspace_id || '-' || notes.collection_id
                                ELSE (SELECT id FROM collections WHERE workspace_id=notes.workspace_id ORDER BY position,id LIMIT 1) END,
                            created_by,kind,title,content,items,color,pinned,archived,trashed,position,reminder_at,
                            reminder_repeat,reminder_fired_at,transcript_status,created_at,updated_at,trashed_at,
                            last_editor_id,stage_id,stage_position FROM notes;
                        DROP TABLE notes;
                        ALTER TABLE notes_new RENAME TO notes;
                    "#).execute(&mut *tx).await?;
                }
                sqlx::query("DROP TABLE collections_legacy")
                    .execute(&mut *tx)
                    .await?;
            }
            sqlx::raw_sql(FINISH_COLLECTIONS).execute(&mut *tx).await?;
        }
        tx.commit().await?;
        Ok::<_, anyhow::Error>(())
    }.await;
    sqlx::query("PRAGMA foreign_keys = ON")
        .execute(&mut *conn)
        .await?;
    result
}

/// Claim old personal definitions only once, in their owner's default
/// workspace. Clearing the old key atomically prevents deleted views from
/// reappearing after a restart; unrelated preferences stay intact.
async fn import_personal_views(pool: &SqlitePool) -> anyhow::Result<()> {
    let mut tx = pool.begin().await?;
    let rows = sqlx::query(
        "SELECT s.user_id, s.data, w.id AS workspace_id FROM user_settings s
         JOIN workspaces w ON w.owner_id = s.user_id AND w.is_default = 1
         WHERE json_type(s.data, '$.saved_views') IS NOT NULL",
    )
    .fetch_all(&mut *tx)
    .await?;
    for row in rows {
        let mut settings: serde_json::Value = serde_json::from_str(row.get("data"))?;
        if let Some(entries) = settings["saved_views"].as_array() {
            for (index, entry) in entries.iter().enumerate() {
                let Ok(mut view) =
                    serde_json::from_value::<crate::models::SavedView>(entry.clone())
                else {
                    continue;
                };
                if view.id.trim().is_empty()
                    || view.name.trim().is_empty()
                    || view.query.trim().is_empty()
                {
                    continue;
                }
                view.position = (index + 1) as f64 * 1024.0;
                sqlx::query(
                    "INSERT OR IGNORE INTO smart_views (workspace_id, id, data) VALUES (?, ?, ?)",
                )
                .bind(row.get::<&str, _>("workspace_id"))
                .bind(&view.id)
                .bind(serde_json::to_string(&view)?)
                .execute(&mut *tx)
                .await?;
            }
        }
        if let Some(object) = settings.as_object_mut() {
            object.remove("saved_views");
        }
        sqlx::query("UPDATE user_settings SET data = ? WHERE user_id = ?")
            .bind(serde_json::to_string(&settings)?)
            .bind(row.get::<&str, _>("user_id"))
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
    use uuid::Uuid;

    use crate::models::User;
    use crate::store::sqlite::SqliteRepository;

    #[tokio::test]
    async fn incomplete_copies_are_reclaimed() {
        use crate::models::Workspace;
        let path = std::env::temp_dir().join(format!("skippy-copy-{}.db", Uuid::new_v4()));
        let repo = SqliteRepository::connect(path.to_str().unwrap())
            .await
            .unwrap();
        repo.create_user(&User {
            id: "u".into(),
            name: "User".into(),
            email: "u@test".into(),
            password_hash: "hash".into(),
        })
        .await
        .unwrap();
        let original = Workspace {
            id: "original".into(),
            owner_id: "u".into(),
            name: "Original".into(),
            notes_enabled: true,
            board_enabled: true,
            is_default: true,
            created_at: "now".into(),
        };
        repo.insert_workspace(&original).await.unwrap();
        let copy = Workspace {
            id: "copy".into(),
            is_default: false,
            ..original
        };
        repo.insert_workspace_copy(&copy).await.unwrap();
        sqlx::raw_sql("INSERT INTO notes(id,workspace_id,created_at,updated_at) VALUES('n','copy','now','now');
            INSERT INTO attachments(id,note_id,mime,created_at) VALUES('blob','n','image/png','now');")
            .execute(&repo.pool).await.unwrap();
        assert_eq!(repo.workspaces_for_user("u").await.unwrap().len(), 1);
        repo.pool.close().await;
        let repo = SqliteRepository::connect(path.to_str().unwrap())
            .await
            .unwrap();
        assert!(repo.workspace("copy").await.unwrap().is_none());
        assert!(repo.workspace("original").await.unwrap().is_some());
        assert!(repo.cleanup_stats().await.unwrap().pending > 0);
        repo.pool.close().await;
        std::fs::remove_file(path).unwrap();
    }

    #[tokio::test]
    async fn collections_migrate_without_loss() {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::raw_sql(super::SCHEMA).execute(&pool).await.unwrap();
        sqlx::raw_sql("INSERT INTO users VALUES ('u','User','u@test','hash','now');
            INSERT INTO workspaces(id,owner_id,name,notes_enabled,board_enabled,created_at) VALUES('w','u','Work',0,1,'now');
            INSERT INTO stages(id,workspace_id,name) VALUES('s','w','Doing');
            INSERT INTO notes(id,workspace_id,title,stage_id,created_at,updated_at) VALUES('n','w','Keep me','s','now','now');")
            .execute(&pool).await.unwrap();
        super::initialize(&pool).await.unwrap();
        super::initialize(&pool).await.unwrap();
        let name: String = sqlx::query_scalar(
            "SELECT title FROM notes WHERE id='n' AND stage_id='s' AND collection_id='w-general'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(name, "Keep me");
        let layout: String =
            sqlx::query_scalar("SELECT layout FROM collections WHERE id='w-general'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(layout, "board");
        let count: i64 = sqlx::query_scalar("SELECT count(*) FROM collections")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(count, 1);
        assert!(
            sqlx::query("PRAGMA foreign_key_check")
                .fetch_all(&pool)
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn cancelled_collection_schema_is_upgraded_without_deleting_notes() {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::raw_sql(super::SCHEMA).execute(&pool).await.unwrap();
        sqlx::raw_sql(
            "CREATE TABLE collections (
                workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                id TEXT NOT NULL, name TEXT NOT NULL,
                layout TEXT NOT NULL DEFAULT 'masonry', position REAL NOT NULL DEFAULT 0,
                PRIMARY KEY(workspace_id,id)
             ) STRICT;
             CREATE TRIGGER workspace_inbox AFTER INSERT ON workspaces BEGIN
                INSERT INTO collections(workspace_id,id,name) VALUES(NEW.id,'inbox','Inbox');
             END;
             INSERT INTO users VALUES('u','User','u@test','hash','now');
             INSERT INTO workspaces(id,owner_id,name,created_at) VALUES('w','u','Work','now');
             INSERT INTO stages(id,workspace_id,name) VALUES('s','w','Doing');
             INSERT INTO notes(id,workspace_id,title,stage_id,created_at,updated_at)
                VALUES('n','w','Keep me','s','now','now');",
        )
        .execute(&pool)
        .await
        .unwrap();

        super::initialize(&pool).await.unwrap();

        let collection: String = sqlx::query_scalar("SELECT collection_id FROM notes WHERE id='n'")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(collection, "w-inbox");
        let name: String = sqlx::query_scalar("SELECT name FROM collections WHERE id='w-inbox'")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(name, "General");
        assert!(
            sqlx::query("PRAGMA foreign_key_check")
                .fetch_all(&pool)
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn previous_collection_assignments_survive_the_new_schema() {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::raw_sql(super::SCHEMA).execute(&pool).await.unwrap();
        sqlx::raw_sql(
            "CREATE TABLE collections (
                workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                id TEXT NOT NULL, name TEXT NOT NULL,
                layout TEXT NOT NULL DEFAULT 'masonry', position REAL NOT NULL DEFAULT 0,
                PRIMARY KEY(workspace_id,id)
             ) STRICT;
             ALTER TABLE notes ADD COLUMN collection_id TEXT NOT NULL DEFAULT 'inbox';
             ALTER TABLE stages ADD COLUMN collection_id TEXT NOT NULL DEFAULT 'inbox';
             INSERT INTO users VALUES('u','User','u@test','hash','now');
             INSERT INTO workspaces(id,owner_id,name,created_at) VALUES('w','u','Work','now');
             INSERT INTO collections VALUES('w','inbox','Inbox','masonry',0);
             INSERT INTO collections VALUES('w','projects','Projects','board',1);
             INSERT INTO stages(id,workspace_id,name,collection_id) VALUES('s','w','Doing','projects');
             INSERT INTO notes(id,workspace_id,title,stage_id,created_at,updated_at,collection_id)
                VALUES('n','w','Keep me','s','now','now','projects');",
        )
        .execute(&pool)
        .await
        .unwrap();

        super::initialize(&pool).await.unwrap();

        let assignment: (String, String) = sqlx::query_as(
            "SELECT n.collection_id,s.collection_id FROM notes n JOIN stages s ON s.id=n.stage_id WHERE n.id='n'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(assignment, ("w-projects".into(), "w-projects".into()));
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT count(*) FROM collections")
                .fetch_one(&pool)
                .await
                .unwrap(),
            2
        );
        assert!(
            sqlx::query("PRAGMA foreign_key_check")
                .fetch_all(&pool)
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn legacy_views_move_once() {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        super::initialize(&pool).await.unwrap();
        sqlx::raw_sql(r#"
            INSERT INTO users VALUES ('u', 'User', 'u@example.test', 'hash', 'now');
            INSERT INTO workspaces (id, owner_id, name, is_default, created_at) VALUES ('w', 'u', 'My notes', 1, 'now');
            INSERT INTO user_settings VALUES ('u', '{"theme":"dark","saved_views":[{"id":"v","name":"Pinned","query":"is:pinned"}]}');
        "#).execute(&pool).await.unwrap();
        super::initialize(&pool).await.unwrap();
        let count: i64 =
            sqlx::query_scalar("SELECT count(*) FROM smart_views WHERE workspace_id = 'w'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(count, 1);
        sqlx::query("DELETE FROM smart_views")
            .execute(&pool)
            .await
            .unwrap();
        super::initialize(&pool).await.unwrap();
        let count: i64 = sqlx::query_scalar("SELECT count(*) FROM smart_views")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(count, 0);
        let data: String = sqlx::query_scalar("SELECT data FROM user_settings")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&data).unwrap(),
            serde_json::json!({"theme":"dark"})
        );
    }

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
