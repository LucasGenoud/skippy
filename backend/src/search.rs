//! Semantic search: notes are embedded locally (no external AI services) and
//! indexed in a vector store.
//!
//! The only backend is [`SqliteVectorIndex`], a zero-infrastructure index
//! built on the sqlite-vec extension (vec0 virtual table): KNN happens inside
//! SQLite, one row per (note, participant) so visibility filtering is part of
//! the query. [`VectorIndex`] stays a trait so another store can be swapped
//! in later.

use std::collections::HashSet;
use std::sync::{Arc, Mutex, Once};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use sqlx::Row;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};

use crate::models::NoteRecord;

// ---------------------------------------------------------------------------
// Embeddings

/// Text -> vector. A trait so tests can inject a deterministic fake instead
/// of downloading the ONNX model.
pub trait TextEmbedder: Send + Sync {
    fn embed(&self, texts: Vec<String>) -> anyhow::Result<Vec<Vec<f32>>>;
    /// Human-readable model identifier, shown in the search-index diagnostics.
    fn model_name(&self) -> &str;
    /// Output vector dimensionality.
    fn dims(&self) -> usize;

    /// Release whatever the embedder is holding if it hasn't been used
    /// recently, reporting whether anything was actually freed. Called on a
    /// timer; embedders with nothing heavy resident need not implement it.
    fn unload_if_idle(&self) -> bool {
        false
    }
}

/// How long the model stays resident after its last use when
/// `STICKY_NOTES_EMBED_IDLE_SECS` doesn't say otherwise.
const DEFAULT_EMBED_IDLE: Duration = Duration::from_secs(15 * 60);

/// When something was last used, and whether it has now been unused long
/// enough to release. Split out from [`FastEmbedder`] so the policy can be
/// tested without a multi-gigabyte ONNX session behind it.
struct IdleTimer {
    last_used: Mutex<Instant>,
    /// `None` never expires.
    after: Option<Duration>,
}

impl IdleTimer {
    fn new(after: Option<Duration>) -> Self {
        Self { last_used: Mutex::new(Instant::now()), after }
    }

    fn touch(&self) {
        *self.last_used.lock().unwrap() = Instant::now();
    }

    fn expired(&self) -> bool {
        let Some(after) = self.after else {
            return false;
        };
        self.last_used.lock().unwrap().elapsed() >= after
    }
}

/// `STICKY_NOTES_EMBED_IDLE_SECS` as a duration: `0` means never unload, an
/// unparseable value falls back to the default rather than failing startup
/// over a tuning knob.
fn parse_idle_unload(raw: Option<&str>) -> Option<Duration> {
    match raw.map(str::trim) {
        None | Some("") => Some(DEFAULT_EMBED_IDLE),
        Some(value) => match value.parse::<u64>() {
            Ok(0) => None,
            Ok(secs) => Some(Duration::from_secs(secs)),
            Err(_) => {
                eprintln!(
                    "ignoring invalid STICKY_NOTES_EMBED_IDLE_SECS '{value}' \
                     (want whole seconds, or 0 to keep the model loaded)"
                );
                Some(DEFAULT_EMBED_IDLE)
            }
        },
    }
}

/// BAAI/bge-m3 (full precision) via fastembed, 1024-dim dense vectors. The
/// model is fetched to a local cache on first use and runs on CPU. fastembed's
/// default transformer CLS-pools and L2-normalizes each vector. We use full
/// precision rather than the INT8-quantized build because quantization noise
/// visibly scrambles the mid-tier ranking of short notes.
///
/// The loaded ONNX session is by far the server's largest allocation, and a
/// personal instance spends most of its life idle between searches, so the
/// model is dropped once it has gone [`idle_unload`] without use and rebuilt
/// from the on-disk cache on the next embed. That costs seconds on the first
/// search after a quiet spell; holding gigabytes through the quiet spell costs
/// more.
pub struct FastEmbedder {
    /// `None` once unloaded — the next [`TextEmbedder::embed`] rebuilds it.
    model: Mutex<Option<fastembed::TextEmbedding>>,
    idle: IdleTimer,
}

pub const EMBEDDING_DIM: usize = 1024;

impl FastEmbedder {
    pub fn init() -> anyhow::Result<Self> {
        // Load once up front: it downloads the model on a first run and proves
        // it's usable while startup can still disable search cleanly. From
        // here on the idle unloader may drop and reload it freely.
        let model = Self::load()?;
        let after =
            parse_idle_unload(std::env::var("STICKY_NOTES_EMBED_IDLE_SECS").ok().as_deref());
        Ok(Self { model: Mutex::new(Some(model)), idle: IdleTimer::new(after) })
    }

    fn load() -> anyhow::Result<fastembed::TextEmbedding> {
        let options = fastembed::InitOptions::new(fastembed::EmbeddingModel::BGEM3);
        fastembed::TextEmbedding::try_new(options)
    }

    /// How long the model may sit unused before [`TextEmbedder::unload_if_idle`]
    /// drops it; `None` when unloading is switched off.
    pub fn idle_unload(&self) -> Option<Duration> {
        self.idle.after
    }
}

impl TextEmbedder for FastEmbedder {
    fn embed(&self, texts: Vec<String>) -> anyhow::Result<Vec<Vec<f32>>> {
        let mut slot = self.model.lock().unwrap();
        let model = match slot.as_mut() {
            Some(model) => model,
            None => slot.insert(Self::load()?),
        };
        let vectors = model.embed(texts, None).map_err(|e| anyhow::anyhow!("embed failed: {e}"))?;
        // Stamped after the work, so a long batch counts as idle from when it
        // finished rather than from when it started.
        self.idle.touch();
        Ok(vectors)
    }

    fn model_name(&self) -> &str {
        "BAAI/bge-m3"
    }

    fn dims(&self) -> usize {
        EMBEDDING_DIM
    }

    fn unload_if_idle(&self) -> bool {
        if !self.idle.expired() {
            return false;
        }
        // try_lock, never lock: a model someone is mid-embed on is in use by
        // definition, and the unloader must not stall a search behind itself.
        let Ok(mut slot) = self.model.try_lock() else {
            return false;
        };
        slot.take().is_some()
    }
}

// ---------------------------------------------------------------------------
// Vector index

#[async_trait]
pub trait VectorIndex: Send + Sync {
    async fn upsert(
        &self,
        note_id: &str,
        participant_ids: &[String],
        vector: Vec<f32>,
    ) -> anyhow::Result<()>;
    async fn remove(&self, note_id: &str) -> anyhow::Result<()>;
    /// Every note id that currently has at least one vector in the index.
    /// Lets the startup reindex skip notes already embedded.
    async fn indexed_note_ids(&self) -> anyhow::Result<HashSet<String>>;
    /// How many distinct notes visible to `user_id` have a vector. Powers the
    /// per-user coverage stat in the settings diagnostics.
    async fn indexed_count(&self, user_id: &str) -> anyhow::Result<usize>;
    /// Top-`limit` note ids visible to `user_id`, best match first.
    async fn search(
        &self,
        user_id: &str,
        vector: Vec<f32>,
        limit: usize,
    ) -> anyhow::Result<Vec<(String, f32)>>;
}

// -- SQLite (sqlite-vec) --------------------------------------------------------

/// Register sqlite-vec for every SQLite connection opened by this process.
/// Idempotent (guarded by `Once`); must run before the pool below is created.
fn register_sqlite_vec() {
    static REGISTER: Once = Once::new();
    REGISTER.call_once(|| unsafe {
        libsqlite3_sys::sqlite3_auto_extension(Some(std::mem::transmute::<
            *const (),
            unsafe extern "C" fn(
                *mut libsqlite3_sys::sqlite3,
                *mut *mut std::os::raw::c_char,
                *const libsqlite3_sys::sqlite3_api_routines,
            ) -> std::os::raw::c_int,
        >(sqlite_vec::sqlite3_vec_init as *const ())));
    });
}

pub struct SqliteVectorIndex {
    pool: sqlx::SqlitePool,
}

impl SqliteVectorIndex {
    /// `dims` must match the embedder's output (see [`EMBEDDING_DIM`]); tests
    /// pass the fake embedder's smaller dimension. `model_signature` identifies
    /// the embedding model+dimension that produced the vectors (e.g.
    /// `"BAAI/bge-m3:1024"`); when it changes, the stored vectors are stale and
    /// the index is rebuilt.
    pub async fn connect(
        path: &str,
        dims: usize,
        model_signature: &str,
    ) -> anyhow::Result<Self> {
        register_sqlite_vec();
        let options = SqliteConnectOptions::new().filename(path).create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(if path == ":memory:" { 1 } else { 3 })
            .connect_with(options)
            .await?;
        // Legacy table from the pre-sqlite-vec brute-force index; the startup
        // reindex repopulates the vec0 table, so this is safe to drop.
        sqlx::raw_sql("DROP TABLE IF EXISTS note_vectors").execute(&pool).await?;
        // Remember which embedding model built note_vec. A different model or
        // dimension makes the existing vectors meaningless — and a same-
        // dimension model swap (e.g. quantized -> full precision) is invisible
        // to a dimension check — so drop the table whenever the signature
        // changes. The startup reindex then repopulates it with the new
        // model's embeddings.
        sqlx::raw_sql(
            "CREATE TABLE IF NOT EXISTS vec_meta (
                 id INTEGER PRIMARY KEY CHECK (id = 0),
                 signature TEXT NOT NULL
             )",
        )
        .execute(&pool)
        .await?;
        let stored: Option<String> =
            sqlx::query_scalar("SELECT signature FROM vec_meta WHERE id = 0")
                .fetch_optional(&pool)
                .await?;
        if stored.as_deref() != Some(model_signature) {
            sqlx::raw_sql("DROP TABLE IF EXISTS note_vec").execute(&pool).await?;
            sqlx::query(
                "INSERT INTO vec_meta (id, signature) VALUES (0, ?1)
                 ON CONFLICT(id) DO UPDATE SET signature = ?1",
            )
            .bind(model_signature)
            .execute(&pool)
            .await?;
        }
        // One row per (note, participant): the partition key makes per-user
        // KNN search prune to that user's rows, and a note appears at most
        // once per partition so results need no dedup.
        sqlx::raw_sql(&format!(
            "CREATE VIRTUAL TABLE IF NOT EXISTS note_vec USING vec0(
                 user_id TEXT PARTITION KEY,
                 note_id TEXT,
                 embedding FLOAT[{dims}] distance_metric=cosine
             )"
        ))
        .execute(&pool)
        .await?;
        Ok(Self { pool })
    }
}

/// sqlite-vec's compact vector format: little-endian f32s.
fn vector_to_blob(vector: &[f32]) -> Vec<u8> {
    vector.iter().flat_map(|v| v.to_le_bytes()).collect()
}

#[async_trait]
impl VectorIndex for SqliteVectorIndex {
    async fn upsert(
        &self,
        note_id: &str,
        participant_ids: &[String],
        vector: Vec<f32>,
    ) -> anyhow::Result<()> {
        // vec0 has no upsert and participants may have changed; replace the
        // note's rows wholesale.
        let mut tx = self.pool.begin().await?;
        sqlx::query("DELETE FROM note_vec WHERE note_id = ?")
            .bind(note_id)
            .execute(&mut *tx)
            .await?;
        let blob = vector_to_blob(&vector);
        for user_id in participant_ids {
            sqlx::query("INSERT INTO note_vec (user_id, note_id, embedding) VALUES (?, ?, ?)")
                .bind(user_id)
                .bind(note_id)
                .bind(&blob)
                .execute(&mut *tx)
                .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    async fn remove(&self, note_id: &str) -> anyhow::Result<()> {
        sqlx::query("DELETE FROM note_vec WHERE note_id = ?")
            .bind(note_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn indexed_note_ids(&self) -> anyhow::Result<HashSet<String>> {
        // A vec0 full scan of the metadata column; one row per (note,
        // participant), so DISTINCT collapses a note's rows to one id.
        let rows = sqlx::query("SELECT DISTINCT note_id FROM note_vec")
            .fetch_all(&self.pool)
            .await?;
        Ok(rows.iter().map(|row| row.get::<String, _>("note_id")).collect())
    }

    async fn indexed_count(&self, user_id: &str) -> anyhow::Result<usize> {
        let row = sqlx::query(
            "SELECT COUNT(DISTINCT note_id) AS n FROM note_vec WHERE user_id = ?",
        )
        .bind(user_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(row.get::<i64, _>("n") as usize)
    }

    async fn search(
        &self,
        user_id: &str,
        vector: Vec<f32>,
        limit: usize,
    ) -> anyhow::Result<Vec<(String, f32)>> {
        let rows = sqlx::query(
            "SELECT note_id, distance FROM note_vec
             WHERE user_id = ? AND embedding MATCH ? AND k = ?
             ORDER BY distance",
        )
        .bind(user_id)
        .bind(vector_to_blob(&vector))
        .bind(limit as i64)
        .fetch_all(&self.pool)
        .await?;
        // Cosine *distance* (0 = identical) -> similarity score, matching the
        // trait's best-match-first, higher-is-better contract.
        Ok(rows
            .iter()
            .map(|row| {
                (row.get::<String, _>("note_id"), 1.0 - row.get::<f64, _>("distance") as f32)
            })
            .collect())
    }
}

// ---------------------------------------------------------------------------
// Service

pub struct SearchService {
    embedder: Arc<dyn TextEmbedder>,
    index: Arc<dyn VectorIndex>,
}

impl SearchService {
    pub fn new(embedder: Arc<dyn TextEmbedder>, index: Arc<dyn VectorIndex>) -> Self {
        Self { embedder, index }
    }

    /// The searchable/embeddable plain text of a note: title, content, and
    /// checklist item texts. Also reused as the note text shown to the LLM
    /// for auto-labeling and chat context.
    pub fn note_text(record: &NoteRecord) -> String {
        let items = record
            .items
            .iter()
            .map(|i| i.text.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        format!("{}\n{}\n{}", record.title, record.content, items)
            .trim()
            .to_string()
    }

    async fn embed_one(&self, text: String) -> anyhow::Result<Vec<f32>> {
        let embedder = self.embedder.clone();
        // fastembed is CPU-bound and synchronous; keep it off the async runtime.
        let mut vectors =
            tokio::task::spawn_blocking(move || embedder.embed(vec![text])).await??;
        vectors.pop().ok_or_else(|| anyhow::anyhow!("embedder returned nothing"))
    }

    pub async fn index_note(
        &self,
        record: &NoteRecord,
        participant_ids: Vec<String>,
    ) -> anyhow::Result<()> {
        let text = Self::note_text(record);
        if text.is_empty() {
            return self.index.remove(&record.id).await;
        }
        let vector = self.embed_one(text).await?;
        self.index.upsert(&record.id, &participant_ids, vector).await
    }

    pub async fn remove_note(&self, note_id: &str) -> anyhow::Result<()> {
        self.index.remove(note_id).await
    }

    /// Note ids already present in the vector index (see
    /// [`VectorIndex::indexed_note_ids`]).
    pub async fn indexed_note_ids(&self) -> anyhow::Result<HashSet<String>> {
        self.index.indexed_note_ids().await
    }

    /// How many of `user_id`'s notes are embedded (see
    /// [`VectorIndex::indexed_count`]).
    pub async fn indexed_count(&self, user_id: &str) -> anyhow::Result<usize> {
        self.index.indexed_count(user_id).await
    }

    /// The embedding model's identifier, for diagnostics.
    pub fn model_name(&self) -> &str {
        self.embedder.model_name()
    }

    /// The embedding model's output dimensionality.
    pub fn dims(&self) -> usize {
        self.embedder.dims()
    }

    /// Hand back the embedding model's memory if nothing has needed it for a
    /// while (see [`TextEmbedder::unload_if_idle`]); reports whether it did.
    /// Blocking — call it from a blocking task, not the async runtime.
    pub fn unload_idle_model(&self) -> bool {
        self.embedder.unload_if_idle()
    }

    pub async fn search(
        &self,
        user_id: &str,
        query: &str,
        limit: usize,
    ) -> anyhow::Result<Vec<(String, f32)>> {
        let vector = self.embed_one(query.to_string()).await?;
        self.index.search(user_id, vector, limit).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_seconds_parse_with_zero_meaning_never_unload() {
        assert_eq!(parse_idle_unload(Some("60")), Some(Duration::from_secs(60)));
        assert_eq!(parse_idle_unload(Some(" 60 ")), Some(Duration::from_secs(60)));
        // 0 pins the model in memory; unset and unparseable both take the default.
        assert_eq!(parse_idle_unload(Some("0")), None);
        assert_eq!(parse_idle_unload(None), Some(DEFAULT_EMBED_IDLE));
        assert_eq!(parse_idle_unload(Some("")), Some(DEFAULT_EMBED_IDLE));
        assert_eq!(parse_idle_unload(Some("ten minutes")), Some(DEFAULT_EMBED_IDLE));
    }

    #[test]
    fn the_idle_timer_expires_only_after_a_quiet_window() {
        let idle = IdleTimer::new(Some(Duration::ZERO));
        assert!(idle.expired(), "a zero window is always past");

        let idle = IdleTimer::new(Some(Duration::from_secs(600)));
        assert!(!idle.expired(), "just used");

        // Unloading off: no amount of quiet expires it.
        let never = IdleTimer::new(None);
        assert!(!never.expired());
    }

    /// An embedder that reports what the idle unloader asked of it.
    struct CountingEmbedder {
        unload_calls: Mutex<usize>,
        idle: bool,
    }

    impl TextEmbedder for CountingEmbedder {
        fn embed(&self, texts: Vec<String>) -> anyhow::Result<Vec<Vec<f32>>> {
            Ok(texts.iter().map(|_| vec![0.0; 3]).collect())
        }
        fn model_name(&self) -> &str {
            "counting"
        }
        fn dims(&self) -> usize {
            3
        }
        fn unload_if_idle(&self) -> bool {
            *self.unload_calls.lock().unwrap() += 1;
            self.idle
        }
    }

    #[tokio::test]
    async fn the_service_forwards_idle_unloads_to_the_embedder() {
        let index = SqliteVectorIndex::connect(":memory:", 3, "test:3").await.unwrap();
        let embedder = Arc::new(CountingEmbedder { unload_calls: Mutex::new(0), idle: true });
        let service = SearchService::new(embedder.clone(), Arc::new(index));

        assert!(service.unload_idle_model(), "the embedder freed its model");
        assert_eq!(*embedder.unload_calls.lock().unwrap(), 1);

        // A busy embedder reports nothing freed, so the caller stays quiet.
        let index = SqliteVectorIndex::connect(":memory:", 3, "test:3").await.unwrap();
        let busy = Arc::new(CountingEmbedder { unload_calls: Mutex::new(0), idle: false });
        let service = SearchService::new(busy, Arc::new(index));
        assert!(!service.unload_idle_model());
    }

    #[tokio::test]
    async fn indexed_note_ids_lists_notes_once_and_tracks_removal() {
        let index = SqliteVectorIndex::connect(":memory:", 3, "test:3").await.unwrap();
        assert!(index.indexed_note_ids().await.unwrap().is_empty());

        // "a" is shared by two participants -> two rows, but one distinct id.
        index.upsert("a", &["u1".into(), "u2".into()], vec![1.0, 0.0, 0.0]).await.unwrap();
        index.upsert("b", &["u1".into()], vec![0.0, 1.0, 0.0]).await.unwrap();
        assert_eq!(
            index.indexed_note_ids().await.unwrap(),
            HashSet::from(["a".to_string(), "b".to_string()])
        );

        // Removing a note drops it from the reported set.
        index.remove("a").await.unwrap();
        assert_eq!(
            index.indexed_note_ids().await.unwrap(),
            HashSet::from(["b".to_string()])
        );
    }

    #[tokio::test]
    async fn changing_model_signature_rebuilds_the_index() {
        // A file-backed DB so state survives reconnecting (each :memory:
        // connect is a fresh database).
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("vecsig-{nanos}.db"));
        let path = path.to_str().unwrap();

        // First model builds the index and stores a vector.
        {
            let index = SqliteVectorIndex::connect(path, 3, "model-a:3").await.unwrap();
            index.upsert("n1", &["u1".into()], vec![1.0, 0.0, 0.0]).await.unwrap();
            assert_eq!(index.indexed_count("u1").await.unwrap(), 1);
        }
        // Reopening with the SAME signature keeps the vectors.
        {
            let index = SqliteVectorIndex::connect(path, 3, "model-a:3").await.unwrap();
            assert_eq!(index.indexed_count("u1").await.unwrap(), 1);
        }
        // A different signature (e.g. quantized -> full precision at the same
        // dimension) drops the stale vectors; the reindex would repopulate.
        {
            let index = SqliteVectorIndex::connect(path, 3, "model-b:3").await.unwrap();
            assert_eq!(index.indexed_count("u1").await.unwrap(), 0);
        }
        let _ = std::fs::remove_file(path);
    }
}
