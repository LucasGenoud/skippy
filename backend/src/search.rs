//! Semantic search: notes are embedded locally (no external AI services) and
//! indexed in a vector store. Two interchangeable backends:
//!
//! * [`SqliteVectorIndex`] — zero-infrastructure default; brute-force cosine
//!   over the user's notes, which is instant at personal-notes scale.
//! * [`QdrantIndex`] — real vector database, enabled by setting
//!   `STICKY_NOTES_QDRANT_URL` (see docker-compose.yml).

use std::sync::{Arc, Mutex};

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

// -- SQLite brute force -------------------------------------------------------

pub struct SqliteVectorIndex {
    pool: sqlx::SqlitePool,
}

impl SqliteVectorIndex {
    pub async fn connect(path: &str) -> anyhow::Result<Self> {
        let options = SqliteConnectOptions::new().filename(path).create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(if path == ":memory:" { 1 } else { 3 })
            .connect_with(options)
            .await?;
        sqlx::raw_sql(
            "CREATE TABLE IF NOT EXISTS note_vectors (
                 note_id TEXT PRIMARY KEY,
                 participants TEXT NOT NULL,
                 vector BLOB NOT NULL
             )",
        )
        .execute(&pool)
        .await?;
        Ok(Self { pool })
    }
}

fn vector_to_blob(vector: &[f32]) -> Vec<u8> {
    vector.iter().flat_map(|v| v.to_le_bytes()).collect()
}

fn blob_to_vector(blob: &[u8]) -> Vec<f32> {
    blob.chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return -1.0;
    }
    let (mut dot, mut na, mut nb) = (0.0f32, 0.0f32, 0.0f32);
    for i in 0..a.len() {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    if na == 0.0 || nb == 0.0 {
        return -1.0;
    }
    dot / (na.sqrt() * nb.sqrt())
}

#[async_trait]
impl VectorIndex for SqliteVectorIndex {
    async fn upsert(
        &self,
        note_id: &str,
        participant_ids: &[String],
        vector: Vec<f32>,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "INSERT INTO note_vectors (note_id, participants, vector) VALUES (?, ?, ?)
             ON CONFLICT (note_id) DO UPDATE
             SET participants = excluded.participants, vector = excluded.vector",
        )
        .bind(note_id)
        .bind(serde_json::to_string(participant_ids)?)
        .bind(vector_to_blob(&vector))
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn remove(&self, note_id: &str) -> anyhow::Result<()> {
        sqlx::query("DELETE FROM note_vectors WHERE note_id = ?")
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
        let rows = sqlx::query("SELECT note_id, participants, vector FROM note_vectors")
            .fetch_all(&self.pool)
            .await?;
        let mut scored: Vec<(String, f32)> = rows
            .iter()
            .filter(|row| {
                let participants: Vec<String> =
                    serde_json::from_str(row.get("participants")).unwrap_or_default();
                participants.iter().any(|p| p == user_id)
            })
            .map(|row| {
                let stored = blob_to_vector(row.get("vector"));
                (row.get::<String, _>("note_id"), cosine(&vector, &stored))
            })
            .collect();
        scored.sort_by(|a, b| b.1.total_cmp(&a.1));
        scored.truncate(limit);
        Ok(scored)
    }
}

// -- Qdrant ---------------------------------------------------------------------

pub struct QdrantIndex {
    client: qdrant_client::Qdrant,
    collection: String,
}

impl QdrantIndex {
    /// Note ids are arbitrary strings; Qdrant point ids must be UUIDs, so we
    /// derive a stable UUIDv5 per note and keep the real id in the payload.
    fn point_id(note_id: &str) -> String {
        uuid::Uuid::new_v5(&uuid::Uuid::NAMESPACE_OID, note_id.as_bytes()).to_string()
    }

    pub async fn connect(url: &str) -> anyhow::Result<Self> {
        use qdrant_client::qdrant::{CreateCollectionBuilder, Distance, VectorParamsBuilder};
        let client = qdrant_client::Qdrant::from_url(url).build()?;
        let collection = "sticky_notes".to_string();
        if !client.collection_exists(&collection).await? {
            client
                .create_collection(
                    CreateCollectionBuilder::new(&collection).vectors_config(
                        VectorParamsBuilder::new(EMBEDDING_DIM as u64, Distance::Cosine),
                    ),
                )
                .await?;
        }
        Ok(Self { client, collection })
    }
}

#[async_trait]
impl VectorIndex for QdrantIndex {
    async fn upsert(
        &self,
        note_id: &str,
        participant_ids: &[String],
        vector: Vec<f32>,
    ) -> anyhow::Result<()> {
        use qdrant_client::Payload;
        use qdrant_client::qdrant::{PointStruct, UpsertPointsBuilder};
        let payload = Payload::try_from(serde_json::json!({
            "note_id": note_id,
            "participants": participant_ids,
        }))
        .map_err(|e| anyhow::anyhow!("payload: {e}"))?;
        let point = PointStruct::new(Self::point_id(note_id), vector, payload);
        self.client
            .upsert_points(UpsertPointsBuilder::new(&self.collection, vec![point]))
            .await?;
        Ok(())
    }

    async fn remove(&self, note_id: &str) -> anyhow::Result<()> {
        use qdrant_client::qdrant::{DeletePointsBuilder, PointsIdsList};
        self.client
            .delete_points(
                DeletePointsBuilder::new(&self.collection)
                    .points(PointsIdsList {
                        ids: vec![Self::point_id(note_id).into()],
                    })
                    .wait(true),
            )
            .await?;
        Ok(())
    }

    async fn search(
        &self,
        user_id: &str,
        vector: Vec<f32>,
        limit: usize,
    ) -> anyhow::Result<Vec<(String, f32)>> {
        use qdrant_client::qdrant::{Condition, Filter, SearchPointsBuilder};
        let response = self
            .client
            .search_points(
                SearchPointsBuilder::new(&self.collection, vector, limit as u64)
                    .filter(Filter::must([Condition::matches(
                        "participants",
                        user_id.to_string(),
                    )]))
                    .with_payload(true),
            )
            .await?;
        Ok(response
            .result
            .into_iter()
            .filter_map(|point| {
                let note_id = point.payload.get("note_id")?.as_str()?.to_string();
                Some((note_id, point.score))
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

    fn note_text(record: &NoteRecord) -> String {
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
