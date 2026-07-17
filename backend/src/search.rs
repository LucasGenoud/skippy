//! Semantic search: notes are embedded locally (no external AI services) and
//! indexed in a vector store.
//!
//! The only backend is [`SqliteVectorIndex`], a zero-infrastructure index
//! built on the sqlite-vec extension (vec0 virtual table): KNN happens inside
//! SQLite, one row per (note, participant) so visibility filtering is part of
//! the query. [`VectorIndex`] stays a trait so another store can be swapped
//! in later.

use std::sync::{Arc, Mutex, Once};

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
}

/// all-MiniLM-L6-v2 via fastembed (384 dims). The model is fetched to a local
/// cache on first use and runs on CPU.
pub struct FastEmbedder {
    model: Mutex<fastembed::TextEmbedding>,
}

pub const EMBEDDING_DIM: usize = 384;

impl FastEmbedder {
    pub fn init() -> anyhow::Result<Self> {
        let options =
            fastembed::InitOptions::new(fastembed::EmbeddingModel::AllMiniLML6V2);
        let model = fastembed::TextEmbedding::try_new(options)?;
        Ok(Self { model: Mutex::new(model) })
    }
}

impl TextEmbedder for FastEmbedder {
    fn embed(&self, texts: Vec<String>) -> anyhow::Result<Vec<Vec<f32>>> {
        let mut model = self.model.lock().unwrap();
        model.embed(texts, None).map_err(|e| anyhow::anyhow!("embed failed: {e}"))
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
    /// pass the fake embedder's smaller dimension.
    pub async fn connect(path: &str, dims: usize) -> anyhow::Result<Self> {
        register_sqlite_vec();
        let options = SqliteConnectOptions::new().filename(path).create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(if path == ":memory:" { 1 } else { 3 })
            .connect_with(options)
            .await?;
        // Legacy table from the pre-sqlite-vec brute-force index; the startup
        // reindex repopulates the vec0 table, so this is safe to drop.
        sqlx::raw_sql("DROP TABLE IF EXISTS note_vectors").execute(&pool).await?;
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
