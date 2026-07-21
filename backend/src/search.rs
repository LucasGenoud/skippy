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
}

/// BAAI/bge-m3 (full precision) via fastembed, 1024-dim dense vectors. The
/// model is fetched to a local cache on first use and runs on CPU. fastembed's
/// default transformer CLS-pools and L2-normalizes each vector. We use full
/// precision rather than the INT8-quantized build because quantization noise
/// visibly scrambles the mid-tier ranking of short notes.
pub struct FastEmbedder {
    model: Mutex<fastembed::TextEmbedding>,
}

pub const EMBEDDING_DIM: usize = 1024;

impl FastEmbedder {
    pub fn init() -> anyhow::Result<Self> {
        let options = fastembed::InitOptions::new(fastembed::EmbeddingModel::BGEM3);
        let model = fastembed::TextEmbedding::try_new(options)?;
        Ok(Self { model: Mutex::new(model) })
    }
}

impl TextEmbedder for FastEmbedder {
    fn embed(&self, texts: Vec<String>) -> anyhow::Result<Vec<Vec<f32>>> {
        let mut model = self.model.lock().unwrap();
        model.embed(texts, None).map_err(|e| anyhow::anyhow!("embed failed: {e}"))
    }

    fn model_name(&self) -> &str {
        "BAAI/bge-m3"
    }

    fn dims(&self) -> usize {
        EMBEDDING_DIM
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
