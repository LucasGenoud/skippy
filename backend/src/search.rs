//! Semantic search: notes are embedded by an external OpenAI-compatible
//! embeddings API (Ollama, OpenAI, LM Studio, ...) and indexed in a vector
//! store. Nothing about the model runs in this process — the server holds no
//! weights, so its memory footprint stays flat regardless of model size.
//!
//! The only index backend is [`SqliteVectorIndex`], a zero-infrastructure
//! index built on the sqlite-vec extension (vec0 virtual table): KNN happens
//! inside SQLite, one row per (note, participant) so visibility filtering is
//! part of the query. [`VectorIndex`] stays a trait so another store can be
//! swapped in later.

use std::collections::HashSet;
use std::sync::{Arc, Once};
use std::time::Duration;

use async_trait::async_trait;
use sqlx::Row;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};

use crate::models::NoteRecord;

// ---------------------------------------------------------------------------
// Embeddings

/// Text -> vector. A trait so tests can inject a deterministic fake instead of
/// standing up an embeddings server.
#[async_trait]
pub trait TextEmbedder: Send + Sync {
    async fn embed(&self, texts: Vec<String>) -> anyhow::Result<Vec<Vec<f32>>>;
    /// Human-readable model identifier, shown in the search-index diagnostics.
    fn model_name(&self) -> &str;
    /// Output vector dimensionality.
    fn dims(&self) -> usize;
}

/// How long a single embeddings request may take. Generous: a cold Ollama
/// loads the model on the first call, which can take a while.
const EMBED_TIMEOUT: Duration = Duration::from_secs(60);

/// Where to reach the embeddings API, from the environment.
#[derive(Debug, Clone, PartialEq)]
pub struct EmbedConfig {
    /// Base URL including the version prefix, e.g. `http://ollama:11434/v1`.
    pub base_url: String,
    /// May be empty (Ollama); the Authorization header is omitted then.
    pub api_key: String,
    pub model: String,
}

impl EmbedConfig {
    /// Read the config from `STICKY_NOTES_EMBED_*`. `None` (no URL set)
    /// disables semantic search entirely.
    pub fn from_env() -> Option<Self> {
        let base_url = non_empty_env("STICKY_NOTES_EMBED_URL")?;
        Some(Self {
            base_url,
            api_key: non_empty_env("STICKY_NOTES_EMBED_API_KEY").unwrap_or_default(),
            // Sensible default for a self-hosted Ollama; `ollama pull bge-m3`
            // matches the model the local embedder used to run.
            model: non_empty_env("STICKY_NOTES_EMBED_MODEL")
                .unwrap_or_else(|| "bge-m3".to_string()),
        })
    }
}

fn non_empty_env(key: &str) -> Option<String> {
    std::env::var(key).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

/// Embeddings over `POST {base}/embeddings`, the OpenAI-compatible shape that
/// Ollama, OpenAI, LM Studio and vLLM all speak.
///
/// The vector width is discovered once at startup by embedding a probe string
/// rather than hardcoded, because it is a property of whichever model the
/// deployment points at. That probe doubles as the reachability check that
/// lets [`connect`](Self::connect) fail cleanly and leave search switched off.
pub struct ApiEmbedder {
    client: reqwest::Client,
    config: EmbedConfig,
    dims: usize,
}

impl ApiEmbedder {
    /// Probe the endpoint and capture the model's vector width. Any failure
    /// here (unreachable, bad key, unknown model) disables semantic search.
    pub async fn connect(config: EmbedConfig) -> anyhow::Result<Self> {
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .build()
            .expect("reqwest client");
        // dims is unknown until the probe answers; it is only read after.
        let mut embedder = Self { client, config, dims: 0 };
        let probe = embedder.embed(vec!["probe".to_string()]).await?;
        embedder.dims = probe
            .first()
            .map(Vec::len)
            .filter(|d| *d > 0)
            .ok_or_else(|| anyhow::anyhow!("embeddings endpoint returned no vector"))?;
        Ok(embedder)
    }
}

#[async_trait]
impl TextEmbedder for ApiEmbedder {
    async fn embed(&self, texts: Vec<String>) -> anyhow::Result<Vec<Vec<f32>>> {
        let url = format!("{}/embeddings", self.config.base_url.trim_end_matches('/'));
        let mut req = self
            .client
            .post(&url)
            .timeout(EMBED_TIMEOUT)
            .json(&serde_json::json!({ "model": self.config.model, "input": texts }));
        if !self.config.api_key.is_empty() {
            req = req.bearer_auth(&self.config.api_key);
        }
        let response = req.send().await?;
        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            // Truncated, and never echoes the API key back into logs.
            let body = body.chars().take(300).collect::<String>();
            anyhow::bail!("embeddings endpoint returned {status}: {body}");
        }
        parse_embeddings(&response.json().await?)
    }

    fn model_name(&self) -> &str {
        &self.config.model
    }

    fn dims(&self) -> usize {
        self.dims
    }
}

/// Pull the vectors out of an OpenAI-shaped embeddings response:
/// `{"data": [{"embedding": [...]}, ...]}`, ordered as the inputs were.
fn parse_embeddings(body: &serde_json::Value) -> anyhow::Result<Vec<Vec<f32>>> {
    let data = body["data"]
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("embeddings response has no 'data' array"))?;
    data.iter()
        .map(|entry| {
            entry["embedding"]
                .as_array()
                .map(|v| v.iter().filter_map(|n| n.as_f64().map(|f| f as f32)).collect::<Vec<_>>())
                .filter(|v: &Vec<f32>| !v.is_empty())
                .ok_or_else(|| anyhow::anyhow!("embeddings response entry has no 'embedding'"))
        })
        .collect()
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
    /// `dims` must match the embedder's output ([`TextEmbedder::dims`], probed
    /// at startup); tests pass the fake embedder's smaller dimension.
    /// `model_signature` identifies the embedding model+dimension that produced
    /// the vectors (e.g. `"bge-m3:1024"`); when it changes, the stored vectors
    /// are stale and the index is rebuilt.
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

/// Ceiling on embeds in flight at once. Indexing is fire-and-forget, one task
/// per edited note, so a bulk reindex would otherwise open a request per note
/// simultaneously and bury a small self-hosted endpoint.
const MAX_CONCURRENT_EMBEDS: usize = 4;

pub struct SearchService {
    embedder: Arc<dyn TextEmbedder>,
    index: Arc<dyn VectorIndex>,
    embed_slots: tokio::sync::Semaphore,
}

impl SearchService {
    pub fn new(embedder: Arc<dyn TextEmbedder>, index: Arc<dyn VectorIndex>) -> Self {
        Self {
            embedder,
            index,
            embed_slots: tokio::sync::Semaphore::new(MAX_CONCURRENT_EMBEDS),
        }
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
        let _slot = self.embed_slots.acquire().await?;
        let mut vectors = self.embedder.embed(vec![text]).await?;
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

    #[test]
    fn embeddings_are_read_back_in_input_order() {
        let body = serde_json::json!({
            "data": [
                {"embedding": [1.0, 2.0, 3.0]},
                {"embedding": [4.0, 5.0, 6.0]},
            ]
        });
        assert_eq!(
            parse_embeddings(&body).unwrap(),
            vec![vec![1.0, 2.0, 3.0], vec![4.0, 5.0, 6.0]]
        );
    }

    #[test]
    fn a_malformed_embeddings_response_is_an_error_not_an_empty_vector() {
        // Silently accepting these would index zero/short vectors and quietly
        // poison ranking, so each shape must fail loudly instead.
        assert!(parse_embeddings(&serde_json::json!({"error": "no such model"})).is_err());
        assert!(parse_embeddings(&serde_json::json!({"data": [{"embedding": []}]})).is_err());
        assert!(parse_embeddings(&serde_json::json!({"data": [{"object": "embedding"}]})).is_err());
    }

    /// Records the high-water mark of concurrent `embed` calls.
    struct ConcurrencyProbe {
        in_flight: std::sync::Mutex<usize>,
        peak: std::sync::Mutex<usize>,
    }

    #[async_trait]
    impl TextEmbedder for ConcurrencyProbe {
        async fn embed(&self, texts: Vec<String>) -> anyhow::Result<Vec<Vec<f32>>> {
            {
                let mut n = self.in_flight.lock().unwrap();
                *n += 1;
                let mut peak = self.peak.lock().unwrap();
                *peak = (*peak).max(*n);
            }
            // Long enough that every permitted caller overlaps here.
            tokio::time::sleep(Duration::from_millis(50)).await;
            *self.in_flight.lock().unwrap() -= 1;
            Ok(texts.iter().map(|_| vec![1.0, 0.0, 0.0]).collect())
        }
        fn model_name(&self) -> &str {
            "probe"
        }
        fn dims(&self) -> usize {
            3
        }
    }

    #[tokio::test]
    async fn a_burst_of_indexing_does_not_flood_the_embeddings_endpoint() {
        // Indexing is one spawned task per note, so without the semaphore a
        // bulk reindex would hit the endpoint with every note at once.
        let probe = Arc::new(ConcurrencyProbe {
            in_flight: std::sync::Mutex::new(0),
            peak: std::sync::Mutex::new(0),
        });
        let index = SqliteVectorIndex::connect(":memory:", 3, "probe:3").await.unwrap();
        let service = Arc::new(SearchService::new(probe.clone(), Arc::new(index)));

        let mut tasks = Vec::new();
        for i in 0..20 {
            let service = service.clone();
            tasks.push(tokio::spawn(async move {
                service.search("u1", &format!("query {i}"), 5).await
            }));
        }
        for task in tasks {
            task.await.unwrap().unwrap();
        }

        let peak = *probe.peak.lock().unwrap();
        assert!(
            peak <= MAX_CONCURRENT_EMBEDS,
            "{peak} concurrent embeds exceeded the {MAX_CONCURRENT_EMBEDS} limit"
        );
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
