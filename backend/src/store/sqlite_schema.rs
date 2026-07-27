use sqlx::SqlitePool;

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE COLLATE NOCASE,
    name TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE COLLATE NOCASE,
    password_hash TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS workspaces (
    id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    is_default INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS workspace_members (
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (workspace_id, user_id)
);
CREATE TABLE IF NOT EXISTS notes (
    id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- Deliberately no ON DELETE action: deleting a workspace files its notes
    -- in their own owner's default workspace first, so the reference is always
    -- cleared before the row goes. A cascade here would destroy notes instead.
    workspace_id TEXT NOT NULL REFERENCES workspaces(id),
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
    last_editor_id TEXT,
    -- Deliberately no foreign key: the column reaches existing databases
    -- through ALTER TABLE, which SQLite cannot use to add a constraint, so a
    -- fresh schema must not have one either or the two would drift.
    -- `delete_stage` clears it explicitly instead.
    stage_id TEXT,
    stage_position REAL
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
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    color TEXT,
    icon TEXT,
    UNIQUE (workspace_id, name COLLATE NOCASE)
);
CREATE TABLE IF NOT EXISTS stages (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    color TEXT,
    position REAL NOT NULL DEFAULT 0,
    UNIQUE (workspace_id, name COLLATE NOCASE)
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
CREATE INDEX IF NOT EXISTS idx_notes_workspace ON notes(workspace_id);
CREATE INDEX IF NOT EXISTS idx_shares_user ON note_shares(user_id);
CREATE INDEX IF NOT EXISTS idx_versions_note ON note_versions(note_id, created_at);
CREATE INDEX IF NOT EXISTS idx_workspace_members_user ON workspace_members(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users(email COLLATE NOCASE);
-- One default workspace per account, enforced rather than assumed: it is the
-- fallback every note is filed in and rehomed to.
CREATE UNIQUE INDEX IF NOT EXISTS idx_workspaces_default
    ON workspaces(owner_id) WHERE is_default = 1;
"#;

const ADDITIVE_MIGRATIONS: &[&str] = &[
    "ALTER TABLE attachments ADD COLUMN filename TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE attachments ADD COLUMN size INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE notes ADD COLUMN transcript_status TEXT NOT NULL DEFAULT 'none'",
    "ALTER TABLE notes ADD COLUMN last_editor_id TEXT",
    "ALTER TABLE notes ADD COLUMN reminder_fired_at TEXT",
    "ALTER TABLE labels ADD COLUMN color TEXT",
    "ALTER TABLE labels ADD COLUMN icon TEXT",
    "ALTER TABLE notes ADD COLUMN stage_id TEXT",
    "ALTER TABLE notes ADD COLUMN stage_position REAL",
];

/// Creates the current schema and upgrades databases written by older builds.
pub(super) async fn initialize(pool: &SqlitePool) -> anyhow::Result<()> {
    sqlx::raw_sql(SCHEMA).execute(pool).await?;
    apply_additive_migrations(pool).await;
    migrate_user_accounts(pool).await?;
    migrate_checklist_history(pool).await?;
    migrate_stage_positions(pool).await?;
    Ok(())
}

/// Seed board ordering from the grid's custom order, so an existing database's
/// first board opens in the arrangement its owner already made rather than an
/// arbitrary one.
///
/// This is a data backfill, not DDL, so it cannot live in
/// [`ADDITIVE_MIGRATIONS`] — those re-run on every startup. The `IS NULL`
/// guard is what makes re-running it harmless, the same way
/// [`migrate_user_accounts`] guards its own updates. Every row written after
/// this point carries a stage position from the start.
async fn migrate_stage_positions(pool: &SqlitePool) -> anyhow::Result<()> {
    sqlx::query("UPDATE notes SET stage_position = position WHERE stage_position IS NULL")
        .execute(pool)
        .await?;
    Ok(())
}

/// Older rows need values for the new account columns. The placeholder keeps
/// the migration additive, but it is not a legacy login alias: authentication
/// always queries the email column only.
async fn migrate_user_accounts(pool: &SqlitePool) -> anyhow::Result<()> {
    sqlx::query(
        "UPDATE users SET name = username
         WHERE name IS NULL OR trim(name) = ''",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "UPDATE users SET email = lower(username) || '@local.invalid'
         WHERE email IS NULL OR trim(email) = ''",
    )
    .execute(pool)
    .await?;
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
