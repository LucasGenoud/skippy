use sqlx::SqlitePool;

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
    reminder_fired_at TEXT,
    transcript_status TEXT NOT NULL DEFAULT 'none',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    trashed_at TEXT,
    last_editor_id TEXT
);
CREATE TABLE IF NOT EXISTS note_versions (
    id TEXT PRIMARY KEY,
    note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    kind TEXT NOT NULL DEFAULT 'text',
    title TEXT NOT NULL DEFAULT '',
    content TEXT NOT NULL DEFAULT '',
    items TEXT NOT NULL DEFAULT '[]',
    edited_by TEXT,
    created_at TEXT NOT NULL
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
    color TEXT,
    icon TEXT,
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
CREATE TABLE IF NOT EXISTS app_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notes_owner ON notes(owner_id);
CREATE INDEX IF NOT EXISTS idx_shares_user ON note_shares(user_id);
CREATE INDEX IF NOT EXISTS idx_versions_note ON note_versions(note_id, created_at);
"#;

const ADDITIVE_MIGRATIONS: &[&str] = &[
    "ALTER TABLE attachments ADD COLUMN filename TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE attachments ADD COLUMN size INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE notes ADD COLUMN transcript_status TEXT NOT NULL DEFAULT 'none'",
    "ALTER TABLE notes ADD COLUMN last_editor_id TEXT",
    "ALTER TABLE notes ADD COLUMN reminder_fired_at TEXT",
    "ALTER TABLE labels ADD COLUMN color TEXT",
    "ALTER TABLE labels ADD COLUMN icon TEXT",
];

/// Creates the current schema and upgrades databases written by older builds.
pub(super) async fn initialize(pool: &SqlitePool) -> anyhow::Result<()> {
    sqlx::raw_sql(SCHEMA).execute(pool).await?;
    apply_additive_migrations(pool).await;
    migrate_checklist_history(pool).await?;
    Ok(())
}

/// These statements intentionally ignore duplicate-column errors: SQLite has
/// no portable `ADD COLUMN IF NOT EXISTS`, and every migration is additive.
async fn apply_additive_migrations(pool: &SqlitePool) {
    for ddl in ADDITIVE_MIGRATIONS {
        let _ = sqlx::query(ddl).execute(pool).await;
    }
}

/// Checklist suggestions were once keyed by user. Old rows cannot be safely
/// attributed to a note, so rebuild and seed from each note's checked items.
async fn migrate_checklist_history(pool: &SqlitePool) -> anyhow::Result<()> {
    let has_note_id = sqlx::query("SELECT note_id FROM checklist_history LIMIT 1")
        .fetch_optional(pool)
        .await
        .is_ok();
    if has_note_id {
        return Ok(());
    }

    sqlx::query("DROP TABLE checklist_history")
        .execute(pool)
        .await?;
    sqlx::raw_sql(SCHEMA).execute(pool).await?;
    sqlx::query(
        "INSERT OR IGNORE INTO checklist_history (note_id, text, uses, last_used_at)
         SELECT n.id, json_extract(je.value, '$.text'), 1, n.updated_at
         FROM notes n, json_each(n.items) je
         WHERE json_extract(je.value, '$.done') = 1
           AND trim(coalesce(json_extract(je.value, '$.text'), '')) != ''",
    )
    .execute(pool)
    .await?;
    Ok(())
}
