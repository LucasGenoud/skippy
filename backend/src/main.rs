use std::path::Path;
use std::sync::Arc;

use sticky_notes_server::files::{DiskStore, FileStore, S3Config, S3Store};
use sticky_notes_server::search::{EMBEDDING_DIM, FastEmbedder, SearchService, SqliteVectorIndex};
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

/// Semantic search wiring: local ONNX embeddings + the built-in sqlite-vec
/// index. Failures disable search gracefully — the rest of the app is
/// unaffected.
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
    let index = match SqliteVectorIndex::connect(db_path, EMBEDDING_DIM).await {
        Ok(index) => {
            println!("semantic search: sqlite-vec index in {db_path}");
            index
        }
        Err(e) => {
            eprintln!("semantic search disabled (vector index unavailable): {e:#}");
            return None;
        }
    };
    Some(Arc::new(SearchService::new(embedder, Arc::new(index))))
}

/// Attachment blob storage wiring, from STICKY_NOTES_STORAGE:
/// - "disk" (default): flat files under STICKY_NOTES_UPLOADS.
/// - "s3": one bucket per note owner in any S3-compatible store (the bundled
///   docker-compose runs Garage). Unlike the optional services this is a hard
///   requirement once selected, so missing config fails startup instead of
///   degrading.
fn init_file_store(uploads: &str) -> anyhow::Result<Arc<dyn FileStore>> {
    let storage = std::env::var("STICKY_NOTES_STORAGE").unwrap_or_default();
    match storage.as_str() {
        "" | "disk" => {
            println!("file storage: local disk at {uploads}");
            Ok(Arc::new(DiskStore::new(uploads)))
        }
        "s3" => {
            let require = |key: &str| {
                std::env::var(key)
                    .map_err(|_| anyhow::anyhow!("STICKY_NOTES_STORAGE=s3 requires {key} to be set"))
            };
            let cfg = S3Config {
                url: require("STICKY_NOTES_S3_URL")?,
                region: std::env::var("STICKY_NOTES_S3_REGION").unwrap_or_else(|_| "garage".to_string()),
                access_key: require("STICKY_NOTES_S3_ACCESS_KEY")?,
                secret_key: require("STICKY_NOTES_S3_SECRET_KEY")?,
                bucket_prefix: std::env::var("STICKY_NOTES_S3_BUCKET_PREFIX")
                    .unwrap_or_else(|_| "sticky-notes-".to_string()),
            };
            println!(
                "file storage: s3 at {} (one bucket per user, prefix {})",
                cfg.url, cfg.bucket_prefix
            );
            Ok(Arc::new(S3Store::new(cfg)?))
        }
        other => anyhow::bail!("unknown STICKY_NOTES_STORAGE '{other}' (expected 'disk' or 's3')"),
    }
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
    let files = init_file_store(&uploads)?;
    let mut state = AppState::new(repo, files)
        .with_file_secret(file_secret)
        .with_managed(sticky_notes_server::config::ManagedSettings::from_env());
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
    // Due reminders push to each user's configured channels (ntfy, Telegram).
    sticky_notes_server::notify::spawn_reminder_scheduler(state.clone());

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
