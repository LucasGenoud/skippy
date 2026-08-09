//! Semantic search: notes are embedded by an external OpenAI-compatible
//! embeddings API (Ollama, OpenAI, LM Studio, ...) and indexed in a vector
//! store. Nothing about the model runs in this process, the server holds no
//! weights, so its memory footprint stays flat regardless of model size.
//!
//! The SQLite backend keeps one sqlite-vec collection per workspace and one
//! vector per note. Workspace ownership is therefore the physical index
//! boundary as well as the relational boundary. Authorization is still
//! rechecked against the repository before any result is returned.

use std::collections::HashSet;
use std::sync::{Arc, Once};
use std::time::Duration;

use async_trait::async_trait;
use sha2::{Digest, Sha256};
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
    /// Read the config from `EMBED_*`. `None` (no URL set)
    /// disables semantic search entirely.
    pub fn from_env() -> Option<Self> {
        let base_url = non_empty_env("EMBED_URL")?;
        Some(Self {
            base_url,
            api_key: non_empty_env("EMBED_API_KEY").unwrap_or_default(),
            // Sensible default for a self-hosted Ollama; `ollama pull bge-m3`
            // matches the model the local embedder used to run.
            model: non_empty_env("EMBED_MODEL")
                .unwrap_or_else(|| "bge-m3".to_string()),
        })
    }
}

fn non_empty_env(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
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
        let mut embedder = Self {
            client,
            config,
            dims: 0,
        };
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
                .map(|v| {
                    v.iter()
                        .filter_map(|n| n.as_f64().map(|f| f as f32))
                        .collect::<Vec<_>>()
                })
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
        workspace_id: &str,
        vector: Vec<f32>,
    ) -> anyhow::Result<()>;
    async fn remove(&self, note_id: &str) -> anyhow::Result<()>;
    async fn remove_workspace(&self, workspace_id: &str) -> anyhow::Result<()>;
    /// Every note id that currently has at least one vector in the index.
    /// Lets the startup reindex skip notes already embedded.
    async fn indexed_note_ids(&self) -> anyhow::Result<HashSet<String>>;
    /// Top-`limit` note ids from the named workspace collections, best match
    /// first. Callers remain responsible for relational access checks.
    async fn search(
        &self,
        workspace_ids: &[String],
        vector: Vec<f32>,
        limit: usize,
    ) -> anyhow::Result<Vec<(String, f32)>>;
}

// -- SQLite (sqlite-vec) --------------------------------------------------------

/// Register sqlite-vec for every SQLite connection opened by this process.
/// Idempotent (guarded by `Once`); must run before the pool below is created.
pub fn register_sqlite_vec() {
    static REGISTER: Once = Once::new();
    REGISTER.call_once(|| unsafe {
        libsqlite3_sys::sqlite3_auto_extension(Some(std::mem::transmute::<
            *const (),
            unsafe extern "C" fn(
                *mut libsqlite3_sys::sqlite3,
                *mut *mut std::os::raw::c_char,
                *const libsqlite3_sys::sqlite3_api_routines,
            ) -> std::os::raw::c_int,
        >(
            sqlite_vec::sqlite3_vec_init as *const ()
        )));
    });
}

pub struct SqliteVectorIndex {
    pool: sqlx::SqlitePool,
    dims: usize,
    write_lock: tokio::sync::Mutex<()>,
}

impl SqliteVectorIndex {
    /// `dims` must match the embedder's output ([`TextEmbedder::dims`], probed
    /// at startup); tests pass the fake embedder's smaller dimension.
    /// `model_signature` identifies the embedding model+dimension that produced
    /// the vectors (e.g. `"bge-m3:1024"`); when it changes, the stored vectors
    /// are stale and the index is rebuilt.
    pub async fn connect(path: &str, dims: usize, model_signature: &str) -> anyhow::Result<Self> {
        register_sqlite_vec();
        let options = SqliteConnectOptions::new()
            .filename(path)
            .create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(if path == ":memory:" { 1 } else { 3 })
            .connect_with(options)
            .await?;
        sqlx::raw_sql(
            "CREATE TABLE IF NOT EXISTS vec_meta (
                 id INTEGER PRIMARY KEY CHECK (id = 0),
                 signature TEXT NOT NULL
             ) STRICT;
             CREATE TABLE IF NOT EXISTS workspace_vec_collections (
                 workspace_id TEXT PRIMARY KEY,
                 table_name TEXT NOT NULL UNIQUE
             ) STRICT;
             CREATE TABLE IF NOT EXISTS note_vec_locations (
                 note_id TEXT PRIMARY KEY,
                 workspace_id TEXT NOT NULL
             ) STRICT",
        )
        .execute(&pool)
        .await?;
        let stored: Option<String> =
            sqlx::query_scalar("SELECT signature FROM vec_meta WHERE id = 0")
                .fetch_optional(&pool)
                .await?;
        if stored.as_deref() != Some(model_signature) {
            let collections =
                sqlx::query("SELECT workspace_id, table_name FROM workspace_vec_collections")
                    .fetch_all(&pool)
                    .await?;
            for row in collections {
                let workspace_id: String = row.get("workspace_id");
                let table_name: String = row.get("table_name");
                if table_name != Self::table_name(&workspace_id) {
                    anyhow::bail!("invalid vector collection metadata for workspace");
                }
                sqlx::raw_sql(&format!("DROP TABLE IF EXISTS {table_name}"))
                    .execute(&pool)
                    .await?;
            }
            sqlx::raw_sql(
                "DELETE FROM note_vec_locations;
                 DELETE FROM workspace_vec_collections",
            )
            .execute(&pool)
            .await?;
            sqlx::query(
                "INSERT INTO vec_meta (id, signature) VALUES (0, ?1)
                 ON CONFLICT(id) DO UPDATE SET signature = ?1",
            )
            .bind(model_signature)
            .execute(&pool)
            .await?;
        }
        Ok(Self {
            pool,
            dims,
            write_lock: tokio::sync::Mutex::new(()),
        })
    }

    fn table_name(workspace_id: &str) -> String {
        format!(
            "note_vec_{}",
            hex::encode(Sha256::digest(workspace_id.as_bytes()))
        )
    }

    async fn ensure_collection(&self, workspace_id: &str, dims: usize) -> anyhow::Result<String> {
        let table_name = Self::table_name(workspace_id);
        sqlx::raw_sql(&format!(
            "CREATE VIRTUAL TABLE IF NOT EXISTS {table_name} USING vec0(
                 note_id TEXT,
                 embedding FLOAT[{dims}] distance_metric=cosine
             )"
        ))
        .execute(&self.pool)
        .await?;
        sqlx::query(
            "INSERT OR IGNORE INTO workspace_vec_collections (workspace_id, table_name)
             VALUES (?, ?)",
        )
        .bind(workspace_id)
        .bind(&table_name)
        .execute(&self.pool)
        .await?;
        Ok(table_name)
    }

    async fn collection(&self, workspace_id: &str) -> anyhow::Result<Option<String>> {
        let stored: Option<String> = sqlx::query_scalar(
            "SELECT table_name FROM workspace_vec_collections WHERE workspace_id = ?",
        )
        .bind(workspace_id)
        .fetch_optional(&self.pool)
        .await?;
        match stored {
            Some(table_name) if table_name == Self::table_name(workspace_id) => {
                Ok(Some(table_name))
            }
            Some(_) => anyhow::bail!("invalid vector collection metadata for workspace"),
            None => Ok(None),
        }
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
        workspace_id: &str,
        vector: Vec<f32>,
    ) -> anyhow::Result<()> {
        let _write = self.write_lock.lock().await;
        let table_name = self.ensure_collection(workspace_id, self.dims).await?;
        let previous_workspace: Option<String> =
            sqlx::query_scalar("SELECT workspace_id FROM note_vec_locations WHERE note_id = ?")
                .bind(note_id)
                .fetch_optional(&self.pool)
                .await?;
        let previous_table = match previous_workspace.as_deref() {
            Some(previous) if previous != workspace_id => self.collection(previous).await?,
            _ => None,
        };
        let mut tx = self.pool.begin().await?;
        if let Some(previous_table) = previous_table {
            sqlx::query(&format!("DELETE FROM {previous_table} WHERE note_id = ?"))
                .bind(note_id)
                .execute(&mut *tx)
                .await?;
        }
        sqlx::query(&format!("DELETE FROM {table_name} WHERE note_id = ?"))
            .bind(note_id)
            .execute(&mut *tx)
            .await?;
        let blob = vector_to_blob(&vector);
        sqlx::query(&format!(
            "INSERT INTO {table_name} (note_id, embedding) VALUES (?, ?)"
        ))
        .bind(note_id)
        .bind(&blob)
        .execute(&mut *tx)
        .await?;
        sqlx::query(
            "INSERT INTO note_vec_locations (note_id, workspace_id) VALUES (?, ?)
             ON CONFLICT(note_id) DO UPDATE SET workspace_id = excluded.workspace_id",
        )
        .bind(note_id)
        .bind(workspace_id)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }

    async fn remove(&self, note_id: &str) -> anyhow::Result<()> {
        let _write = self.write_lock.lock().await;
        let workspace_id: Option<String> =
            sqlx::query_scalar("SELECT workspace_id FROM note_vec_locations WHERE note_id = ?")
                .bind(note_id)
                .fetch_optional(&self.pool)
                .await?;
        if let Some(workspace_id) = workspace_id
            && let Some(table_name) = self.collection(&workspace_id).await?
        {
            sqlx::query(&format!("DELETE FROM {table_name} WHERE note_id = ?"))
                .bind(note_id)
                .execute(&self.pool)
                .await?;
        }
        sqlx::query("DELETE FROM note_vec_locations WHERE note_id = ?")
            .bind(note_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn remove_workspace(&self, workspace_id: &str) -> anyhow::Result<()> {
        let _write = self.write_lock.lock().await;
        if let Some(table_name) = self.collection(workspace_id).await? {
            sqlx::raw_sql(&format!("DROP TABLE IF EXISTS {table_name}"))
                .execute(&self.pool)
                .await?;
        }
        sqlx::query("DELETE FROM note_vec_locations WHERE workspace_id = ?")
            .bind(workspace_id)
            .execute(&self.pool)
            .await?;
        sqlx::query("DELETE FROM workspace_vec_collections WHERE workspace_id = ?")
            .bind(workspace_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn indexed_note_ids(&self) -> anyhow::Result<HashSet<String>> {
        let rows = sqlx::query("SELECT note_id FROM note_vec_locations")
            .fetch_all(&self.pool)
            .await?;
        Ok(rows
            .iter()
            .map(|row| row.get::<String, _>("note_id"))
            .collect())
    }

    async fn search(
        &self,
        workspace_ids: &[String],
        vector: Vec<f32>,
        limit: usize,
    ) -> anyhow::Result<Vec<(String, f32)>> {
        let blob = vector_to_blob(&vector);
        let mut hits = Vec::new();
        for workspace_id in workspace_ids {
            let Some(table_name) = self.collection(workspace_id).await? else {
                continue;
            };
            let rows = sqlx::query(&format!(
                "SELECT note_id, distance FROM {table_name}
                 WHERE embedding MATCH ? AND k = ? ORDER BY distance"
            ))
            .bind(&blob)
            .bind(limit as i64)
            .fetch_all(&self.pool)
            .await?;
            hits.extend(rows.iter().map(|row| {
                (
                    row.get::<String, _>("note_id"),
                    1.0 - row.get::<f64, _>("distance") as f32,
                )
            }));
        }
        hits.sort_by(|a, b| b.1.total_cmp(&a.1));
        hits.truncate(limit);
        Ok(hits)
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

    /// [`note_text`](Self::note_text) plus whatever an OCR service read out of
    /// the note's images (see [`crate::ocr`]), so a photo of a receipt is
    /// findable by the words printed on it. A note holding nothing but such a
    /// picture is text as far as the embedder is concerned.
    pub fn note_text_with_ocr(record: &NoteRecord, ocr_texts: &[String]) -> String {
        let own = Self::note_text(record);
        let recognized = ocr_texts
            .iter()
            .map(String::as_str)
            .filter(|text| !text.trim().is_empty())
            .collect::<Vec<_>>()
            .join("\n");
        if recognized.is_empty() {
            return own;
        }
        format!("{own}\n{recognized}").trim().to_string()
    }

    async fn embed_one(&self, text: String) -> anyhow::Result<Vec<f32>> {
        let _slot = self.embed_slots.acquire().await?;
        let mut vectors = self.embedder.embed(vec![text]).await?;
        vectors
            .pop()
            .ok_or_else(|| anyhow::anyhow!("embedder returned nothing"))
    }

    /// Embed and index a note. `ocr_texts` carries the text recognized in its
    /// image attachments (empty when OCR is off or the note has no pictures).
    pub async fn index_note(
        &self,
        record: &NoteRecord,
        ocr_texts: &[String],
    ) -> anyhow::Result<()> {
        let text = Self::note_text_with_ocr(record, ocr_texts);
        if text.is_empty() {
            return self.index.remove(&record.id).await;
        }
        let vector = self.embed_one(text).await?;
        self.index
            .upsert(&record.id, &record.workspace_id, vector)
            .await
    }

    pub async fn remove_note(&self, note_id: &str) -> anyhow::Result<()> {
        self.index.remove(note_id).await
    }

    /// Note ids already present in the vector index (see
    /// [`VectorIndex::indexed_note_ids`]).
    pub async fn indexed_note_ids(&self) -> anyhow::Result<HashSet<String>> {
        self.index.indexed_note_ids().await
    }

    pub async fn remove_workspace(&self, workspace_id: &str) -> anyhow::Result<()> {
        self.index.remove_workspace(workspace_id).await
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
        workspace_ids: &[String],
        query: &str,
        limit: usize,
    ) -> anyhow::Result<Vec<(String, f32)>> {
        let vector = self.embed_one(query.to_string()).await?;
        self.index.search(workspace_ids, vector, limit).await
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
        let index = SqliteVectorIndex::connect(":memory:", 3, "probe:3")
            .await
            .unwrap();
        let service = Arc::new(SearchService::new(probe.clone(), Arc::new(index)));

        let mut tasks = Vec::new();
        for i in 0..20 {
            let service = service.clone();
            tasks.push(tokio::spawn(async move {
                service
                    .search(&["w1".to_string()], &format!("query {i}"), 5)
                    .await
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
        let index = SqliteVectorIndex::connect(":memory:", 3, "test:3")
            .await
            .unwrap();
        assert!(index.indexed_note_ids().await.unwrap().is_empty());

        index.upsert("a", "w1", vec![1.0, 0.0, 0.0]).await.unwrap();
        index.upsert("b", "w2", vec![0.0, 1.0, 0.0]).await.unwrap();
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
    async fn workspace_collections_are_isolated_and_drop_as_a_unit() {
        let index = SqliteVectorIndex::connect(":memory:", 3, "test:3")
            .await
            .unwrap();
        index.upsert("n1", "w1", vec![1.0, 0.0, 0.0]).await.unwrap();
        index.upsert("n2", "w2", vec![1.0, 0.0, 0.0]).await.unwrap();

        let w1 = index
            .search(&["w1".into()], vec![1.0, 0.0, 0.0], 10)
            .await
            .unwrap();
        assert_eq!(
            w1.iter().map(|hit| hit.0.as_str()).collect::<Vec<_>>(),
            vec!["n1"]
        );

        index.remove_workspace("w1").await.unwrap();
        assert_eq!(
            index.indexed_note_ids().await.unwrap(),
            HashSet::from(["n2".to_string()])
        );
        assert!(
            index
                .search(&["w1".into()], vec![1.0, 0.0, 0.0], 10)
                .await
                .unwrap()
                .is_empty()
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
            let index = SqliteVectorIndex::connect(path, 3, "model-a:3")
                .await
                .unwrap();
            index.upsert("n1", "w1", vec![1.0, 0.0, 0.0]).await.unwrap();
            assert_eq!(index.indexed_note_ids().await.unwrap().len(), 1);
        }
        // Reopening with the SAME signature keeps the vectors.
        {
            let index = SqliteVectorIndex::connect(path, 3, "model-a:3")
                .await
                .unwrap();
            assert_eq!(index.indexed_note_ids().await.unwrap().len(), 1);
        }
        // A different signature (e.g. quantized -> full precision at the same
        // dimension) drops the stale vectors; the reindex would repopulate.
        {
            let index = SqliteVectorIndex::connect(path, 3, "model-b:3")
                .await
                .unwrap();
            assert!(index.indexed_note_ids().await.unwrap().is_empty());
        }
        let _ = std::fs::remove_file(path);
    }
}
