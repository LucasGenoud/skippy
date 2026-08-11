use std::path::{Path, PathBuf};
use std::sync::Arc;

use sticky_notes_server::config::ManagedSettings;
use sticky_notes_server::files::{DiskStore, FileStore, S3Config, S3Store};
use sticky_notes_server::ocr::{ImageOcr, TesseractService};
use sticky_notes_server::search::{
    ApiEmbedder, EmbedConfig, SearchService, SqliteVectorIndex, TextEmbedder,
};
use sticky_notes_server::store::Repository;
use sticky_notes_server::store::sqlite::SqliteRepository;
use sticky_notes_server::transcribe::{Transcriber, WhisperService};
use sticky_notes_server::{
    AppState, build_app_with_cors_origin, cors_origin_from_public_url, handlers,
};
use tower_http::services::{ServeDir, ServeFile};

/// How many unread images one start hands to the OCR service. The jobs run
/// two at a time behind `AppState::ocr_slots`, so this bounds how long a
/// backlog pass keeps the container busy, not how much memory it costs.
const OCR_BACKLOG_PER_START: u32 = 500;

/// Load the persistent HMAC key used to sign file-access URLs, creating and
/// storing one on first run. Persisting it means signed URLs stay valid across
/// restarts (a per-process key would invalidate every outstanding URL on
/// reboot).
async fn load_file_secret(repo: &dyn Repository) -> anyhow::Result<Vec<u8>> {
    if let Some(stored) = repo
        .meta_get("file_secret")
        .await
        .map_err(|e| anyhow::anyhow!("{e:?}"))?
        && let Ok(bytes) = hex::decode(stored.trim())
        && bytes.len() >= 32
    {
        return Ok(bytes);
    }
    let mut bytes = vec![0u8; 32];
    rand_core::RngCore::fill_bytes(&mut rand_core::OsRng, &mut bytes);
    repo.meta_set("file_secret", &hex::encode(&bytes))
        .await
        .map_err(|e| anyhow::anyhow!("{e:?}"))?;
    Ok(bytes)
}

/// Resolve the index.html to serve as the SPA fallback. When
/// PUBLIC_URL is set, inject it as `window.stickyNotesApiBase`
/// into a runtime copy so the web app targets that backend without a rebuild;
/// otherwise serve the original file untouched.
fn serve_index_path(web_dir: &str) -> PathBuf {
    let index = Path::new(web_dir).join("index.html");
    let url = match std::env::var("PUBLIC_URL") {
        Ok(u) if !u.trim().is_empty() => u.trim().trim_end_matches('/').to_string(),
        _ => return index,
    };
    let html = match std::fs::read_to_string(&index) {
        Ok(h) => h,
        Err(_) => return index,
    };
    let injected = inject_api_base(&html, &url);
    // Namespace the temp copy by a hash of the URL so two instances on one host
    // (different PUBLIC_URL) can't clobber each other's file.
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

/// Semantic search wiring: an external OpenAI-compatible embeddings API plus
/// the built-in sqlite-vec index. Enabled by EMBED_URL; unset or
/// unreachable disables search gracefully, leaving the rest of the app
/// unaffected.
async fn init_search(db_path: &str) -> Option<Arc<SearchService>> {
    let Some(config) = EmbedConfig::from_env() else {
        println!("semantic search disabled (set EMBED_URL to enable)");
        return None;
    };
    let url = config.base_url.clone();
    // Probes the endpoint, which is also how the model's vector width is
    // discovered, see ApiEmbedder::connect.
    let embedder = match ApiEmbedder::connect(config).await {
        Ok(embedder) => Arc::new(embedder),
        Err(e) => {
            eprintln!("semantic search disabled (embeddings API at {url} unavailable): {e:#}");
            return None;
        }
    };
    // Identifies the model+dimension behind the stored vectors; a change here
    // triggers a rebuild of the index (see SqliteVectorIndex::connect).
    let signature = format!("{}:{}", embedder.model_name(), embedder.dims());
    let index = match SqliteVectorIndex::connect(db_path, embedder.dims(), &signature).await {
        Ok(index) => index,
        Err(e) => {
            eprintln!("semantic search disabled (vector index unavailable): {e:#}");
            return None;
        }
    };
    println!(
        "semantic search: {} ({} dims) at {url}, sqlite-vec index in {db_path}",
        embedder.model_name(),
        embedder.dims()
    );
    Some(Arc::new(SearchService::new(embedder, Arc::new(index))))
}

/// Attachment blob storage wiring, from STORAGE:
/// - "disk" (default): flat files under UPLOADS.
/// - "s3": one installation-wide bucket in any S3-compatible store (the bundled
///   docker-compose runs Garage). Unlike the optional services this is a hard
///   requirement once selected, so missing config fails startup instead of
///   degrading.
fn init_file_store(uploads: &str) -> anyhow::Result<Arc<dyn FileStore>> {
    let storage = std::env::var("STORAGE").unwrap_or_default();
    match storage.as_str() {
        "" | "disk" => {
            println!("file storage: local disk at {uploads}");
            Ok(Arc::new(DiskStore::new(uploads)))
        }
        "s3" => {
            let require = |key: &str| {
                std::env::var(key).map_err(|_| {
                    anyhow::anyhow!("STORAGE=s3 requires {key} to be set")
                })
            };
            let cfg = S3Config {
                url: require("S3_URL")?,
                region: std::env::var("S3_REGION")
                    .unwrap_or_else(|_| "garage".to_string()),
                access_key: require("S3_ACCESS_KEY")?,
                secret_key: require("S3_SECRET_KEY")?,
                bucket_prefix: std::env::var("S3_BUCKET_PREFIX")
                    .unwrap_or_else(|_| "sticky-notes-".to_string()),
            };
            println!(
                "file storage: s3 at {} (attachment bucket prefix {})",
                cfg.url, cfg.bucket_prefix
            );
            Ok(Arc::new(S3Store::new(cfg)?))
        }
        other => anyhow::bail!("unknown STORAGE '{other}' (expected 'disk' or 's3')"),
    }
}

/// Audio transcription wiring: a self-hosted Whisper service, enabled by
/// WHISPER_URL. Unset or unreachable -> feature stays off.
async fn init_transcription() -> Option<Arc<dyn Transcriber>> {
    let url = std::env::var("WHISPER_URL").ok()?;
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

/// Image text recognition wiring: a self-hosted Tesseract service, enabled by
/// OCR_URL. Unset or unreachable -> feature stays off. OCR_LANGUAGES picks the
/// language packs (e.g. `fra+eng`); which ones exist is a property of that
/// container, not of a user's settings.
async fn init_ocr() -> Option<Arc<dyn ImageOcr>> {
    let url = std::env::var("OCR_URL").ok()?;
    let languages = std::env::var("OCR_LANGUAGES")
        .ok()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .unwrap_or_else(|| "eng".to_string());
    match TesseractService::connect(&url, &languages).await {
        Ok(service) => {
            println!("image text recognition: tesseract at {url} ({languages})");
            Some(Arc::new(service))
        }
        Err(e) => {
            eprintln!("image text recognition disabled ({e:#})");
            None
        }
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    if let Some(argument) = std::env::args().nth(1) {
        anyhow::bail!("sticky-notes-server does not accept command-line arguments (got '{argument}')");
    }
    let db_path =
        std::env::var("DB").unwrap_or_else(|_| "sticky_notes.db".to_string());
    let uploads = std::env::var("UPLOADS").unwrap_or_else(|_| "uploads".to_string());
    // Swap point: implement `Repository` for another database and change
    // this constructor.
    let repo = Arc::new(SqliteRepository::connect(&db_path).await?);
    let file_secret = load_file_secret(repo.as_ref()).await?;
    let files = init_file_store(&uploads)?;
    let mut state = AppState::new(repo, files)
        .with_file_secret(file_secret)
        .with_managed(ManagedSettings::from_env());
    if let Some(service) = init_transcription().await {
        state = state.with_transcription(service);
    }
    if let Some(service) = init_ocr().await {
        state = state.with_ocr(service);
        // Read whatever is still unread: pictures uploaded while OCR was off
        // or unreachable, and any recognition a restart interrupted. Bounded
        // per start so a large library catches up over several of them
        // instead of flooding the container in one go.
        let state_for_ocr = state.clone();
        tokio::spawn(async move {
            let queued = state_for_ocr.ocr_backlog(OCR_BACKLOG_PER_START).await;
            if queued > 0 {
                sticky_notes_server::telemetry::event(
                    "info",
                    "ocr_backlog_queued",
                    serde_json::json!({ "queued": queued }),
                );
            }
        });
    }
    if let Some(service) = init_search(&db_path).await {
        state = state.with_search(service);
        // Bring the index up to date with existing notes in the background.
        // Only embed notes missing from the index: a normal restart finds them
        // all present (near-zero work), while a fresh/rebuilt index (new DB or
        // an embedding-model switch that dropped the table) embeds everything,
        // and notes skipped while the embedder was down get caught up.
        let state_for_reindex = state.clone();
        tokio::spawn(async move {
            let Some(search) = state_for_reindex.search.clone() else {
                return;
            };
            let already = match search.indexed_note_ids().await {
                Ok(already) => already,
                Err(error) => {
                    state_for_reindex.report_background_failure("startup_index_inventory", &error);
                    Default::default()
                }
            };
            let ids = match state_for_reindex.repo.all_note_ids().await {
                Ok(ids) => ids,
                Err(error) => {
                    state_for_reindex
                        .report_background_failure("startup_note_inventory", &format!("{error:?}"));
                    return;
                }
            };
            let mut queued = 0usize;
            for id in ids {
                if !already.contains(&id) {
                    state_for_reindex.index_note_later(&id);
                    queued += 1;
                }
            }
            sticky_notes_server::telemetry::event(
                "info",
                "semantic_reindex_queued",
                serde_json::json!({ "queued": queued, "already_indexed": already.len() }),
            );
        });
    }
    if let Err(error) = handlers::purge_old_trash(&state).await {
        state.report_background_failure("startup_trash_purge", &format!("status: {error:?}"));
    }
    sticky_notes_server::cleanup::spawn_cleanup_worker(state.clone());
    // Due reminders push to each user's configured channels (ntfy, Telegram).
    sticky_notes_server::notify::spawn_reminder_scheduler(state.clone());

    let cors_origin = std::env::var("PUBLIC_URL")
        .ok()
        .filter(|url| !url.trim().is_empty())
        .map(|url| cors_origin_from_public_url(&url))
        .transpose()?;
    let mut app = build_app_with_cors_origin(state, cors_origin);

    // If the Flutter web build exists, serve it so the whole app runs off one binary.
    let web_dir =
        std::env::var("WEB").unwrap_or_else(|_| "../app/build/web".to_string());
    if Path::new(&web_dir).join("index.html").exists() {
        // A self-hoster can pin the backend URL browsers should use via
        // PUBLIC_URL (e.g. behind a reverse proxy on :443). We
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

    let addr = std::env::var("ADDR").unwrap_or_else(|_| "0.0.0.0:8787".to_string());
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    println!("sticky-notes-server listening on http://{addr} (db: {db_path})");
    axum::serve(listener, app).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::inject_api_base;

    #[test]
    fn injects_before_head_close() {
        let out = inject_api_base(
            "<html><head><title>x</title></head><body></body></html>",
            "https://notes.example.com",
        );
        assert!(out.contains(r#"window.stickyNotesApiBase="https://notes.example.com";"#));
        // Placed inside <head>, before the app's own scripts run.
        let script = out.find("stickyNotesApiBase").unwrap();
        assert!(script < out.find("</head>").unwrap());
    }

    #[test]
    fn escapes_url_so_it_cannot_break_out_of_the_script() {
        let out = inject_api_base("<head></head>", r#"https://x/"</script><script>alert(1)"#);
        // No literal </script> can appear in the injected value, it's \u-escaped.
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
