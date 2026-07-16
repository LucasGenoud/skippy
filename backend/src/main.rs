use std::path::Path;
use std::sync::Arc;

use sticky_notes_server::files::FileStore;
use sticky_notes_server::search::{
    FastEmbedder, QdrantIndex, SearchService, SqliteVectorIndex, VectorIndex,
};
use sticky_notes_server::store::Repository;
use sticky_notes_server::store::sqlite::SqliteRepository;
use sticky_notes_server::transcribe::{Transcriber, WhisperService};
use sticky_notes_server::{AppState, build_app, handlers};
use tower_http::services::{ServeDir, ServeFile};

/// Load the persistent HMAC key used to sign file-access URLs, creating and
/// storing one on first run. Persisting it means signed URLs stay valid across
/// restarts (a per-process key would invalidate every outstanding URL on
/// reboot).
async fn load_file_secret(repo: &dyn Repository) -> anyhow::Result<Vec<u8>> {
    if let Some(stored) = repo.meta_get("file_secret").await.map_err(|e| anyhow::anyhow!("{e:?}"))? {
        if let Ok(bytes) = hex::decode(stored.trim()) {
            if bytes.len() >= 32 {
                return Ok(bytes);
            }
        }
    }
    let mut bytes = vec![0u8; 32];
    rand_core::RngCore::fill_bytes(&mut rand_core::OsRng, &mut bytes);
    repo.meta_set("file_secret", &hex::encode(&bytes))
        .await
        .map_err(|e| anyhow::anyhow!("{e:?}"))?;
    Ok(bytes)
}

/// Semantic search wiring: local ONNX embeddings + either Qdrant (when
/// STICKY_NOTES_QDRANT_URL is set) or the built-in SQLite vector index.
/// Failures disable search gracefully — the rest of the app is unaffected.
async fn init_search(db_path: &str) -> Option<Arc<SearchService>> {
    if std::env::var("STICKY_NOTES_SEMANTIC").is_ok_and(|v| v == "off") {
        return None;
    }
    let embedder = match tokio::task::spawn_blocking(FastEmbedder::init).await {
        Ok(Ok(e)) => Arc::new(e),
        Ok(Err(e)) => {
            eprintln!("semantic search disabled (embedding model unavailable): {e:#}");
            return None;
        }
        Err(e) => {
            eprintln!("semantic search disabled: {e:#}");
            return None;
        }
    };
    let index: Arc<dyn VectorIndex> = match std::env::var("STICKY_NOTES_QDRANT_URL") {
        Ok(url) => match QdrantIndex::connect(&url).await {
            Ok(qdrant) => {
                println!("semantic search: qdrant at {url}");
                Arc::new(qdrant)
            }
            Err(e) => {
                eprintln!("qdrant unreachable ({e:#}); falling back to built-in index");
                Arc::new(SqliteVectorIndex::connect(db_path).await.ok()?)
            }
        },
        Err(_) => {
            println!("semantic search: built-in index (set STICKY_NOTES_QDRANT_URL for qdrant)");
            Arc::new(SqliteVectorIndex::connect(db_path).await.ok()?)
        }
    };
    Some(Arc::new(SearchService::new(embedder, index)))
}

/// Audio transcription wiring: a self-hosted Whisper service, enabled by
/// STICKY_NOTES_WHISPER_URL. Unset or unreachable -> feature stays off.
async fn init_transcription() -> Option<Arc<dyn Transcriber>> {
    let url = std::env::var("STICKY_NOTES_WHISPER_URL").ok()?;
    match WhisperService::connect(&url).await {
        Ok(service) => {
            println!("audio transcription: whisper at {url}");
            Some(Arc::new(service))
        }
        Err(e) => {
            eprintln!("audio transcription disabled ({e:#})");
            None
        }
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let db_path = std::env::var("STICKY_NOTES_DB").unwrap_or_else(|_| "sticky_notes.db".to_string());
    let uploads = std::env::var("STICKY_NOTES_UPLOADS").unwrap_or_else(|_| "uploads".to_string());

    // Swap point: implement `Repository` for another database and change
    // this constructor.
    let repo = Arc::new(SqliteRepository::connect(&db_path).await?);
    let file_secret = load_file_secret(repo.as_ref()).await?;
    let mut state = AppState::new(repo, FileStore::new(&uploads)).with_file_secret(file_secret);
    if let Some(service) = init_transcription().await {
        state = state.with_transcription(service);
    }
    if let Some(service) = init_search(&db_path).await {
        state = state.with_search(service);
        // Bring the index up to date with existing notes in the background.
        let state_for_reindex = state.clone();
        tokio::spawn(async move {
            if let Ok(ids) = state_for_reindex.repo.all_note_ids().await {
                for id in ids {
                    state_for_reindex.index_note_later(&id);
                }
            }
        });
    }
    handlers::purge_old_trash(&state).await.ok();

    let mut app = build_app(state);

    // If the Flutter web build exists, serve it so the whole app runs off one binary.
    let web_dir = std::env::var("STICKY_NOTES_WEB").unwrap_or_else(|_| "../app/build/web".to_string());
    if Path::new(&web_dir).join("index.html").exists() {
        let index = Path::new(&web_dir).join("index.html");
        app = app.fallback_service(ServeDir::new(&web_dir).fallback(ServeFile::new(index)));
        println!("serving web app from {web_dir}");
    }

    let addr = std::env::var("STICKY_NOTES_ADDR").unwrap_or_else(|_| "0.0.0.0:8787".to_string());
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    println!("sticky-notes-server listening on http://{addr} (db: {db_path})");
    axum::serve(listener, app).await?;
    Ok(())
}
