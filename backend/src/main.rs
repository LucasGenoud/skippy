use std::path::{Path, PathBuf};
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

/// Resolve the index.html to serve as the SPA fallback. When
/// STICKY_NOTES_PUBLIC_URL is set, inject it as `window.stickyNotesApiBase`
/// into a runtime copy so the web app targets that backend without a rebuild;
/// otherwise serve the original file untouched.
fn serve_index_path(web_dir: &str) -> PathBuf {
    let index = Path::new(web_dir).join("index.html");
    let url = match std::env::var("STICKY_NOTES_PUBLIC_URL") {
        Ok(u) if !u.trim().is_empty() => u.trim().trim_end_matches('/').to_string(),
        _ => return index,
    };
    let html = match std::fs::read_to_string(&index) {
        Ok(h) => h,
        Err(_) => return index,
    };
    let injected = inject_api_base(&html, &url);
    // Namespace the temp copy by a hash of the URL so two instances on one host
    // (different STICKY_NOTES_PUBLIC_URL) can't clobber each other's file.
    let tag = {
        use std::hash::{Hash, Hasher};
        let mut h = std::collections::hash_map::DefaultHasher::new();
        url.hash(&mut h);
        h.finish()
    };
    let out = std::env::temp_dir().join(format!("sticky-notes-index-{tag:x}.html"));
    match std::fs::write(&out, injected) {
        Ok(()) => {
            println!("web app default backend URL pinned to {url}");
            out
        }
        Err(_) => index,
    }
}

/// Insert `window.stickyNotesApiBase = "<url>"` into an index.html, just before
/// the first `</head>`. The URL is JSON-encoded so an operator-supplied value
/// can't break out of the `<script>`. If there's no `</head>` (unexpected), the
/// snippet is prepended so the global is still defined before the app boots.
fn inject_api_base(html: &str, url: &str) -> String {
    let literal = serde_json::to_string(url)
        .unwrap_or_else(|_| "\"\"".to_string())
        // Inside a <script>, the HTML parser still scans for `</script>` etc.
        // regardless of JS string context; escape the HTML-significant chars to
        // their \uXXXX forms (valid JS, invisible to the HTML tokenizer).
        .replace('<', "\\u003c")
        .replace('>', "\\u003e")
        .replace('&', "\\u0026");
    let snippet = format!("<script>window.stickyNotesApiBase={literal};</script>");
    if html.contains("</head>") {
        html.replacen("</head>", &format!("{snippet}\n</head>"), 1)
    } else {
        format!("{snippet}\n{html}")
    }
}

#[cfg(test)]
mod tests {
    use super::inject_api_base;

    #[test]
    fn injects_before_head_close() {
        let out = inject_api_base("<html><head><title>x</title></head><body></body></html>", "https://notes.example.com");
        assert!(out.contains(r#"window.stickyNotesApiBase="https://notes.example.com";"#));
        // Placed inside <head>, before the app's own scripts run.
        let script = out.find("stickyNotesApiBase").unwrap();
        assert!(script < out.find("</head>").unwrap());
    }

    #[test]
    fn escapes_url_so_it_cannot_break_out_of_the_script() {
        let out = inject_api_base("<head></head>", r#"https://x/"</script><script>alert(1)"#);
        // No literal </script> can appear in the injected value — it's \u-escaped.
        let value_end = out.find(";</script>").unwrap();
        assert!(!out[..value_end].contains("</script>"));
        assert!(out.contains("\\u003c"));
    }

    #[test]
    fn falls_back_when_no_head() {
        let out = inject_api_base("<body>app</body>", "http://localhost:8787");
        assert!(out.starts_with("<script>window.stickyNotesApiBase="));
        assert!(out.contains("<body>app</body>"));
    }
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
        // A self-hoster can pin the backend URL browsers should use via
        // STICKY_NOTES_PUBLIC_URL (e.g. behind a reverse proxy on :443). We
        // stamp it into a runtime copy of index.html as `window.stickyNotesApiBase`
        // so the app reads it without a rebuild; unset ⇒ serve the file as-is
        // and the app falls back to same-origin.
        let index = serve_index_path(&web_dir);
        // append_index_html_on_directories(false) so `/` misses ServeDir and
        // hits the fallback too, guaranteeing the injected copy is served.
        app = app.fallback_service(
            ServeDir::new(&web_dir)
                .append_index_html_on_directories(false)
                .fallback(ServeFile::new(index)),
        );
        println!("serving web app from {web_dir}");
    }

    let addr = std::env::var("STICKY_NOTES_ADDR").unwrap_or_else(|_| "0.0.0.0:8787".to_string());
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    println!("sticky-notes-server listening on http://{addr} (db: {db_path})");
    axum::serve(listener, app).await?;
    Ok(())
}
