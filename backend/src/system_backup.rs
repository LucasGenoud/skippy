//! Whole-system backup and restore for operators.
//!
//! This is deliberately separate from the portable, user-facing backup in the
//! Flutter app. A system archive contains a consistent SQLite snapshot (users,
//! sessions, settings, workspaces, notes, history, metadata, and derived search
//! tables) plus every attachment blob referenced by that snapshot.

use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, ensure};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{Row, SqlitePool};
use uuid::Uuid;

use crate::files::FileStore;
use crate::search::register_sqlite_vec;

const MAGIC: &[u8; 8] = b"SKPSYS01";
const FORMAT: &str = "skippy-system-backup";
const VERSION: u32 = 2;
const MAX_HEADER_BYTES: u32 = 64 * 1024;
const MAX_RECORD_BYTES: u32 = 64 * 1024;
const MAX_ATTACHMENTS: u64 = 1_000_000;
const MAX_ATTACHMENT_BYTES: u64 = 1024 * 1024 * 1024;

#[derive(Debug, Serialize, Deserialize)]
struct ArchiveHeader {
    format: String,
    version: u32,
    created_at: String,
    server_version: String,
    attachment_count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct BlobRecord {
    id: String,
    size: u64,
    sha256: String,
}

#[derive(Debug, Clone)]
struct AttachmentRef {
    id: String,
    size: u64,
}

#[derive(Debug)]
pub struct BackupReport {
    pub path: PathBuf,
    pub attachments: usize,
    pub bytes: u64,
}

#[derive(Debug)]
pub struct RestoreReport {
    pub attachments: usize,
    pub safety_backup: Option<PathBuf>,
}

/// An advisory lock held by the running server and by an offline restore.
/// Backups intentionally do not take it: SQLite's `VACUUM INTO` supplies the
/// online-consistent database snapshot, and attachment blobs are immutable.
pub struct SystemLock {
    _file: File,
}

impl SystemLock {
    pub fn acquire(db_path: &Path) -> anyhow::Result<Self> {
        let path = lock_path(db_path);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("creating lock directory {}", parent.display()))?;
        }
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&path)
            .with_context(|| format!("opening system lock {}", path.display()))?;
        file.try_lock_exclusive().with_context(|| {
            format!(
                "Skippy is already using {}. Stop the server before restoring",
                db_path.display()
            )
        })?;
        Ok(Self { _file: file })
    }
}

fn lock_path(db_path: &Path) -> PathBuf {
    let name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("skippy");
    db_path.with_file_name(format!("{name}.lock"))
}

struct BackupActivityLock {
    _file: File,
}

impl BackupActivityLock {
    fn acquire(db_path: &Path) -> anyhow::Result<Self> {
        let path = backup_lock_path(db_path);
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&path)
            .with_context(|| format!("opening backup activity lock {}", path.display()))?;
        file.try_lock_exclusive()
            .context("another system backup or restore is already running")?;
        Ok(Self { _file: file })
    }
}

fn backup_lock_path(db_path: &Path) -> PathBuf {
    let name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("skippy");
    db_path.with_file_name(format!("{name}.backup.lock"))
}

/// Create an atomic, single-file backup. It is safe to run while the server is
/// online. If a referenced blob disappears during the snapshot window, the
/// command fails rather than emitting an incomplete archive.
pub async fn system_backup(
    db_path: &Path,
    files: Arc<dyn FileStore>,
    output: &Path,
) -> anyhow::Result<BackupReport> {
    ensure!(
        db_path != Path::new(":memory:"),
        "system backup needs a file-backed database"
    );
    ensure!(
        db_path.exists(),
        "database {} does not exist",
        db_path.display()
    );
    let _activity = BackupActivityLock::acquire(db_path)?;
    ensure!(
        !output.exists(),
        "backup target {} already exists",
        output.display()
    );
    let parent = output
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::create_dir_all(parent)
        .with_context(|| format!("creating backup directory {}", parent.display()))?;

    let tag = Uuid::new_v4();
    let snapshot = parent.join(format!(".skippy-snapshot-{tag}.db"));
    let partial = parent.join(format!(".skippy-backup-{tag}.partial"));
    let result = backup_inner(db_path, files, output, &snapshot, &partial).await;
    let _ = fs::remove_file(&snapshot);
    if result.is_err() {
        let _ = fs::remove_file(&partial);
    }
    result
}

async fn backup_inner(
    db_path: &Path,
    files: Arc<dyn FileStore>,
    output: &Path,
    snapshot: &Path,
    partial: &Path,
) -> anyhow::Result<BackupReport> {
    vacuum_snapshot(db_path, snapshot).await?;
    let attachments = attachment_refs(snapshot).await?;
    ensure!(
        attachments.len() as u64 <= MAX_ATTACHMENTS,
        "database contains too many attachments to archive"
    );

    let header = ArchiveHeader {
        format: FORMAT.to_string(),
        version: VERSION,
        created_at: chrono::Utc::now().to_rfc3339(),
        server_version: env!("CARGO_PKG_VERSION").to_string(),
        attachment_count: attachments.len() as u64,
    };
    let header_json = serde_json::to_vec(&header)?;
    ensure!(
        header_json.len() <= MAX_HEADER_BYTES as usize,
        "system backup header is too large"
    );

    let mut writer = BufWriter::new(
        create_private_file(partial).with_context(|| format!("creating {}", partial.display()))?,
    );
    writer.write_all(MAGIC)?;
    write_u32(&mut writer, header_json.len() as u32)?;
    writer.write_all(&header_json)?;

    let (database_hash, database_size) = hash_file(snapshot)?;
    write_u64(&mut writer, database_size)?;
    writer.write_all(&database_hash)?;
    copy_file(snapshot, &mut writer)?;

    let mut total_bytes = database_size;
    for attachment in &attachments {
        let bytes = files.read(&attachment.id).await.with_context(|| {
            format!(
                "attachment {} referenced by the database is missing",
                attachment.id
            )
        })?;
        ensure!(
            bytes.len() as u64 == attachment.size,
            "attachment {} has {} bytes but the database records {}",
            attachment.id,
            bytes.len(),
            attachment.size
        );
        let record = BlobRecord {
            id: attachment.id.clone(),
            size: bytes.len() as u64,
            sha256: hex::encode(Sha256::digest(&bytes)),
        };
        let metadata = serde_json::to_vec(&record)?;
        ensure!(
            metadata.len() <= MAX_RECORD_BYTES as usize,
            "attachment metadata is too large"
        );
        write_u32(&mut writer, metadata.len() as u32)?;
        writer.write_all(&metadata)?;
        writer.write_all(&bytes)?;
        total_bytes += bytes.len() as u64;
    }

    writer.flush()?;
    writer.get_ref().sync_all()?;
    drop(writer);
    fs::rename(partial, output)
        .with_context(|| format!("publishing backup {}", output.display()))?;
    Ok(BackupReport {
        path: output.to_path_buf(),
        attachments: attachments.len(),
        bytes: total_bytes,
    })
}

/// Restore a validated archive. The running server holds the same lock, so
/// this refuses to proceed until the server has been stopped. By default a
/// complete safety archive of the current system is created first.
pub async fn system_restore(
    db_path: &Path,
    files: Arc<dyn FileStore>,
    archive: &Path,
    skip_safety_backup: bool,
) -> anyhow::Result<RestoreReport> {
    ensure!(
        archive.exists(),
        "backup archive {} does not exist",
        archive.display()
    );
    let _lock = SystemLock::acquire(db_path)?;
    let parent = db_path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::create_dir_all(parent)
        .with_context(|| format!("creating database directory {}", parent.display()))?;
    let stage = parent.join(format!(".skippy-restore-{}", Uuid::new_v4()));
    fs::create_dir(&stage)
        .with_context(|| format!("creating restore staging {}", stage.display()))?;
    let result = restore_inner(db_path, files, archive, skip_safety_backup, &stage).await;
    let _ = fs::remove_dir_all(&stage);
    result
}

async fn restore_inner(
    db_path: &Path,
    files: Arc<dyn FileStore>,
    archive: &Path,
    skip_safety_backup: bool,
    stage: &Path,
) -> anyhow::Result<RestoreReport> {
    let staged_db = stage.join("database.db");
    let staged_blobs = stage.join("attachments");
    fs::create_dir(&staged_blobs)?;
    let records = extract_and_validate_archive(archive, &staged_db, &staged_blobs)?;
    validate_database(&staged_db, &records).await?;

    let old_attachments = if db_path.exists() {
        match attachment_refs(db_path).await {
            Ok(records) => records,
            Err(error) if skip_safety_backup => {
                eprintln!("warning: existing attachment list is unreadable: {error:#}");
                Vec::new()
            }
            Err(error) => return Err(error.context("reading current database before restore")),
        }
    } else {
        Vec::new()
    };

    let safety_backup = if db_path.exists() && !skip_safety_backup {
        let backups = db_path
            .parent()
            .unwrap_or(Path::new("."))
            .join("system-backups");
        fs::create_dir_all(&backups)?;
        let stamp = chrono::Utc::now().format("%Y%m%d-%H%M%S");
        let path = backups.join(format!(
            "pre-restore-{stamp}-{}.skb",
            &Uuid::new_v4().to_string()[..8]
        ));
        system_backup(db_path, files.clone(), &path).await?;
        Some(path)
    } else {
        None
    };

    // Serialize the mutating phase against online backups. The safety backup
    // above acquired and released this same activity lock.
    let _activity = BackupActivityLock::acquire(db_path)?;

    // Put every restored blob in place before switching the database. The old
    // database remains usable if an object-store write fails.
    for (index, record) in records.iter().enumerate() {
        let bytes = fs::read(staged_blobs.join(index.to_string()))?;
        files
            .save(&record.id, &bytes)
            .await
            .with_context(|| format!("restoring attachment {}", record.id))?;
    }

    replace_database(db_path, &staged_db)?;

    // Old blobs not referenced by the restored database are now unreachable.
    // FileStore deletion is deliberately best-effort, matching ordinary note
    // deletion; any storage orphan is harmless and can be pruned separately.
    let restored: HashSet<String> = records.iter().map(|r| r.id.clone()).collect();
    for old in old_attachments {
        if !restored.contains(&old.id) {
            let _ = files.delete(&old.id).await;
        }
    }

    Ok(RestoreReport {
        attachments: records.len(),
        safety_backup,
    })
}

async fn vacuum_snapshot(source: &Path, target: &Path) -> anyhow::Result<()> {
    ensure!(
        !target.exists(),
        "snapshot target {} already exists",
        target.display()
    );
    register_sqlite_vec();
    let options = SqliteConnectOptions::new()
        .filename(source)
        .create_if_missing(false)
        .foreign_keys(true);
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await?;
    let target_sql = target.to_string_lossy().replace('\'', "''");
    sqlx::query(&format!("VACUUM INTO '{target_sql}'"))
        .execute(&pool)
        .await
        .context("creating consistent SQLite snapshot")?;
    pool.close().await;
    Ok(())
}

async fn open_readonly(path: &Path) -> anyhow::Result<SqlitePool> {
    register_sqlite_vec();
    let options = SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(false)
        .read_only(true)
        .foreign_keys(true);
    Ok(SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await?)
}

async fn attachment_refs(path: &Path) -> anyhow::Result<Vec<AttachmentRef>> {
    let pool = open_readonly(path).await?;
    let rows = sqlx::query("SELECT id, size FROM attachments ORDER BY id")
        .fetch_all(&pool)
        .await
        .context("reading attachment inventory")?;
    pool.close().await;
    rows.into_iter()
        .map(|row| {
            let size: i64 = row.get("size");
            ensure!(size >= 0, "attachment has a negative size");
            Ok(AttachmentRef {
                id: row.get("id"),
                size: size as u64,
            })
        })
        .collect()
}

fn extract_and_validate_archive(
    archive: &Path,
    staged_db: &Path,
    staged_blobs: &Path,
) -> anyhow::Result<Vec<BlobRecord>> {
    let mut reader = BufReader::new(
        File::open(archive).with_context(|| format!("opening backup {}", archive.display()))?,
    );
    let mut magic = [0u8; 8];
    reader.read_exact(&mut magic)?;
    ensure!(&magic == MAGIC, "not a Skippy system backup");
    let header_len = read_u32(&mut reader)?;
    ensure!(header_len <= MAX_HEADER_BYTES, "backup header is too large");
    let header: ArchiveHeader =
        serde_json::from_slice(&read_exact_vec(&mut reader, header_len as u64)?)
            .context("invalid backup header")?;
    ensure!(
        header.format == FORMAT && header.version == VERSION,
        "unsupported Skippy system backup version"
    );
    ensure!(
        header.attachment_count <= MAX_ATTACHMENTS,
        "backup contains too many attachments"
    );

    let database_size = read_u64(&mut reader)?;
    let mut expected_database_hash = [0u8; 32];
    reader.read_exact(&mut expected_database_hash)?;
    let actual_database_hash =
        copy_exact_hashed(&mut reader, &mut File::create(staged_db)?, database_size)?;
    ensure!(
        actual_database_hash == expected_database_hash,
        "database snapshot checksum does not match"
    );

    let mut records = Vec::with_capacity(header.attachment_count as usize);
    let mut seen = HashSet::new();
    for index in 0..header.attachment_count {
        let metadata_len = read_u32(&mut reader)?;
        ensure!(
            metadata_len <= MAX_RECORD_BYTES,
            "attachment metadata is too large"
        );
        let record: BlobRecord =
            serde_json::from_slice(&read_exact_vec(&mut reader, metadata_len as u64)?)
                .context("invalid attachment metadata")?;
        ensure!(
            !record.id.is_empty(),
            "backup contains an invalid attachment identity"
        );
        ensure!(
            record.size <= MAX_ATTACHMENT_BYTES,
            "attachment {} exceeds the 1 GiB restore limit",
            record.id
        );
        ensure!(
            seen.insert(record.id.clone()),
            "backup contains a duplicate attachment"
        );
        let path = staged_blobs.join(index.to_string());
        let actual = copy_exact_hashed(&mut reader, &mut File::create(path)?, record.size)?;
        ensure!(
            hex::encode(actual) == record.sha256,
            "attachment {} checksum does not match",
            record.id
        );
        records.push(record);
    }
    let mut trailing = [0u8; 1];
    ensure!(
        reader.read(&mut trailing)? == 0,
        "backup contains trailing data"
    );
    Ok(records)
}

async fn validate_database(path: &Path, records: &[BlobRecord]) -> anyhow::Result<()> {
    let pool = open_readonly(path).await?;
    let integrity: String = sqlx::query("PRAGMA integrity_check")
        .fetch_one(&pool)
        .await?
        .get(0);
    ensure!(
        integrity == "ok",
        "restored database failed integrity check: {integrity}"
    );
    let foreign_key_errors = sqlx::query("PRAGMA foreign_key_check")
        .fetch_all(&pool)
        .await?;
    ensure!(
        foreign_key_errors.is_empty(),
        "restored database failed foreign-key validation"
    );
    let required_tables: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN
         ('users', 'sessions', 'workspaces', 'workspace_members', 'stages',
          'labels', 'notes', 'note_versions', 'note_shares', 'note_labels',
          'checklist_history', 'attachments', 'share_links', 'user_settings',
          'app_meta')",
    )
    .fetch_one(&pool)
    .await?;
    ensure!(
        required_tables == 15,
        "backup database is missing required schema tables"
    );
    let rows = sqlx::query("SELECT id, size FROM attachments")
        .fetch_all(&pool)
        .await?;
    pool.close().await;
    let database: HashMap<String, u64> = rows
        .into_iter()
        .map(|row| {
            let size: i64 = row.get("size");
            (row.get("id"), size.max(0) as u64)
        })
        .collect();
    let archived: HashMap<String, u64> = records
        .iter()
        .map(|record| (record.id.clone(), record.size))
        .collect();
    ensure!(
        database == archived,
        "backup attachment inventory does not match its database snapshot"
    );
    Ok(())
}

fn replace_database(target: &Path, staged: &Path) -> anyhow::Result<()> {
    let parent = target.parent().unwrap_or(Path::new("."));
    let incoming = parent.join(format!(".skippy-incoming-{}.db", Uuid::new_v4()));
    fs::copy(staged, &incoming)?;
    File::open(&incoming)?.sync_all()?;

    let previous = parent.join(format!(".skippy-previous-{}.db", Uuid::new_v4()));
    let previous_wal = sidecar_path(&previous, "-wal");
    let previous_shm = sidecar_path(&previous, "-shm");
    let target_wal = sidecar_path(target, "-wal");
    let target_shm = sidecar_path(target, "-shm");
    if target.exists() {
        fs::rename(target, &previous)?;
    }
    if target_wal.exists()
        && let Err(error) = fs::rename(&target_wal, &previous_wal)
    {
        if previous.exists() {
            let _ = fs::rename(&previous, target);
        }
        return Err(error).context("preserving the previous SQLite WAL");
    }
    if target_shm.exists()
        && let Err(error) = fs::rename(&target_shm, &previous_shm)
    {
        if previous.exists() {
            let _ = fs::rename(&previous, target);
        }
        if previous_wal.exists() {
            let _ = fs::rename(&previous_wal, &target_wal);
        }
        return Err(error).context("preserving the previous SQLite shared-memory file");
    }
    if let Err(error) = fs::rename(&incoming, target) {
        if previous.exists() {
            let _ = fs::rename(&previous, target);
        }
        if previous_wal.exists() {
            let _ = fs::rename(&previous_wal, &target_wal);
        }
        if previous_shm.exists() {
            let _ = fs::rename(&previous_shm, &target_shm);
        }
        return Err(error).context("installing restored database");
    }
    for path in [&previous, &previous_wal, &previous_shm] {
        if path.exists() {
            fs::remove_file(path)?;
        }
    }
    Ok(())
}

fn sidecar_path(database: &Path, suffix: &str) -> PathBuf {
    let mut path = database.as_os_str().to_os_string();
    path.push(suffix);
    PathBuf::from(path)
}

fn hash_file(path: &Path) -> anyhow::Result<([u8; 32], u64)> {
    let mut reader = BufReader::new(File::open(path)?);
    let mut hasher = Sha256::new();
    let mut size = 0u64;
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        size += read as u64;
    }
    Ok((hasher.finalize().into(), size))
}

fn create_private_file(path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

fn copy_file(path: &Path, writer: &mut impl Write) -> anyhow::Result<()> {
    let mut reader = BufReader::new(File::open(path)?);
    std::io::copy(&mut reader, writer)?;
    Ok(())
}

fn copy_exact_hashed(
    reader: &mut impl Read,
    writer: &mut impl Write,
    size: u64,
) -> anyhow::Result<[u8; 32]> {
    let mut limited = reader.take(size);
    let mut hasher = Sha256::new();
    let mut copied = 0u64;
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = limited.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        writer.write_all(&buffer[..read])?;
        hasher.update(&buffer[..read]);
        copied += read as u64;
    }
    ensure!(
        copied == size,
        "backup ended before a data section was complete"
    );
    writer.flush()?;
    Ok(hasher.finalize().into())
}

fn read_exact_vec(reader: &mut impl Read, size: u64) -> anyhow::Result<Vec<u8>> {
    ensure!(
        size <= MAX_RECORD_BYTES as u64,
        "backup metadata is too large"
    );
    let mut bytes = vec![0u8; size as usize];
    reader.read_exact(&mut bytes)?;
    Ok(bytes)
}

fn write_u32(writer: &mut impl Write, value: u32) -> std::io::Result<()> {
    writer.write_all(&value.to_be_bytes())
}

fn write_u64(writer: &mut impl Write, value: u64) -> std::io::Result<()> {
    writer.write_all(&value.to_be_bytes())
}

fn read_u32(reader: &mut impl Read) -> std::io::Result<u32> {
    let mut bytes = [0u8; 4];
    reader.read_exact(&mut bytes)?;
    Ok(u32::from_be_bytes(bytes))
}

fn read_u64(reader: &mut impl Read) -> std::io::Result<u64> {
    let mut bytes = [0u8; 8];
    reader.read_exact(&mut bytes)?;
    Ok(u64::from_be_bytes(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::{DiskStore, FileStore};
    use crate::store::sqlite::SqliteRepository;

    fn temp_root() -> PathBuf {
        std::env::temp_dir().join(format!("skippy-system-backup-test-{}", Uuid::new_v4()))
    }

    async fn seed_database(path: &Path) -> anyhow::Result<()> {
        let repo = SqliteRepository::connect(path.to_str().unwrap()).await?;
        drop(repo);
        let options = SqliteConnectOptions::new()
            .filename(path)
            .foreign_keys(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await?;
        sqlx::query(
            "INSERT INTO users (id, name, email, password_hash, created_at)
             VALUES ('u1', 'User', 'before@example.test', 'hash', '2026-01-01T00:00:00Z')",
        )
        .execute(&pool)
        .await?;
        sqlx::query(
            "INSERT INTO workspaces (id, owner_id, name, is_default, created_at)
             VALUES ('w1', 'u1', 'Home', 1, '2026-01-01T00:00:00Z')",
        )
        .execute(&pool)
        .await?;
        sqlx::query(
            "INSERT INTO notes
             (id, workspace_id, created_by, kind, title, content, items, color, pinned,
              archived, trashed, position, transcript_status, created_at, updated_at,
              stage_position)
             VALUES ('n1', 'w1', 'u1', 'text', 'Backup note', 'body', '[]', 'default',
                     0, 0, 0, 0, 'none', '2026-01-01T00:00:00Z',
                     '2026-01-01T00:00:00Z', 0)",
        )
        .execute(&pool)
        .await?;
        sqlx::query(
            "INSERT INTO attachments (id, note_id, mime, filename, size, created_at)
             VALUES ('a1', 'n1', 'text/plain', 'file.txt', 3, '2026-01-01T00:00:00Z')",
        )
        .execute(&pool)
        .await?;
        pool.close().await;
        Ok(())
    }

    #[tokio::test]
    async fn online_backup_and_offline_restore_round_trip_everything() -> anyhow::Result<()> {
        let root = temp_root();
        fs::create_dir(&root)?;
        let db = root.join("skippy.db");
        let uploads = root.join("uploads");
        let archive = root.join("system.skb");
        seed_database(&db).await?;
        let disk: Arc<dyn FileStore> = Arc::new(DiskStore::new(&uploads));
        disk.save("a1", b"old").await?;

        // A running server lock does not block an online backup.
        let server_lock = SystemLock::acquire(&db)?;
        let report = system_backup(&db, disk.clone(), &archive).await?;
        assert_eq!(report.attachments, 1);
        assert!(report.bytes > 3);
        drop(server_lock);

        let options = SqliteConnectOptions::new().filename(&db).foreign_keys(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await?;
        sqlx::query("UPDATE users SET email = 'after@example.test' WHERE id = 'u1'")
            .execute(&pool)
            .await?;
        pool.close().await;
        disk.save("a1", b"new").await?;

        let restored = system_restore(&db, disk.clone(), &archive, false).await?;
        assert_eq!(restored.attachments, 1);
        assert!(
            restored
                .safety_backup
                .as_ref()
                .is_some_and(|path| path.exists())
        );
        assert_eq!(disk.read("a1").await.as_deref(), Some(b"old".as_slice()));

        let pool = open_readonly(&db).await?;
        let email: String = sqlx::query("SELECT email FROM users WHERE id = 'u1'")
            .fetch_one(&pool)
            .await?
            .get(0);
        pool.close().await;
        assert_eq!(email, "before@example.test");
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[tokio::test]
    async fn restore_refuses_to_run_while_server_lock_is_held() -> anyhow::Result<()> {
        let root = temp_root();
        fs::create_dir(&root)?;
        let db = root.join("skippy.db");
        let uploads = root.join("uploads");
        let archive = root.join("system.skb");
        seed_database(&db).await?;
        let disk: Arc<dyn FileStore> = Arc::new(DiskStore::new(&uploads));
        disk.save("a1", b"old").await?;
        system_backup(&db, disk.clone(), &archive).await?;

        let _server_lock = SystemLock::acquire(&db)?;
        let error = system_restore(&db, disk, &archive, true).await.unwrap_err();
        assert!(error.to_string().contains("Stop the server"));
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[tokio::test]
    async fn corrupt_archive_is_rejected_before_current_data_changes() -> anyhow::Result<()> {
        let root = temp_root();
        fs::create_dir(&root)?;
        let db = root.join("skippy.db");
        let uploads = root.join("uploads");
        let archive = root.join("system.skb");
        seed_database(&db).await?;
        let disk: Arc<dyn FileStore> = Arc::new(DiskStore::new(&uploads));
        disk.save("a1", b"old").await?;
        system_backup(&db, disk.clone(), &archive).await?;
        let mut bytes = fs::read(&archive)?;
        *bytes.last_mut().unwrap() ^= 0xff;
        fs::write(&archive, bytes)?;

        assert!(
            system_restore(&db, disk.clone(), &archive, true)
                .await
                .is_err()
        );
        assert_eq!(disk.read("a1").await.as_deref(), Some(b"old".as_slice()));
        let pool = open_readonly(&db).await?;
        let count: i64 = sqlx::query("SELECT COUNT(*) FROM users")
            .fetch_one(&pool)
            .await?
            .get(0);
        pool.close().await;
        assert_eq!(count, 1);
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[tokio::test]
    async fn partial_schema_is_rejected() -> anyhow::Result<()> {
        let root = temp_root();
        fs::create_dir(&root)?;
        let db = root.join("partial.db");
        let options = SqliteConnectOptions::new()
            .filename(&db)
            .create_if_missing(true)
            .foreign_keys(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await?;
        sqlx::query("CREATE TABLE users (id TEXT PRIMARY KEY) STRICT")
            .execute(&pool)
            .await?;
        pool.close().await;

        let error = validate_database(&db, &[]).await.unwrap_err();
        assert!(
            error.to_string().contains("missing required schema tables"),
            "{error:#}"
        );
        fs::remove_dir_all(root)?;
        Ok(())
    }
}
