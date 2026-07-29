pub mod assist;
pub mod auth;
pub mod config;
pub mod error;
pub mod files;
pub mod handlers;
pub mod llm;
pub mod models;
pub mod notify;
mod outbound;
pub mod search;
pub mod store;
pub mod system_backup;
pub mod transcribe;
pub mod unfurl;
pub mod ws;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::http::HeaderValue;
use axum::routing::{get, post};
use tower_http::cors::{Any, CorsLayer};

use crate::files::FileStore;
use crate::store::Repository;
use crate::ws::Hub;

/// Progress of a per-user "re-run embeddings" job. `done` counts notes
/// embedded so far out of `total`; the job is finished once they are equal.
#[derive(Clone, Copy, Default)]
pub struct ReindexProgress {
    pub done: usize,
    pub total: usize,
}

#[derive(Clone)]
pub struct AppState {
    pub repo: Arc<dyn Repository>,
    pub hub: Hub,
    /// Attachment blob storage — local disk or S3, chosen in `main` from
    /// `STICKY_NOTES_STORAGE`.
    pub files: Arc<dyn FileStore>,
    /// Present when semantic search is enabled.
    pub search: Option<Arc<search::SearchService>>,
    /// Present when audio transcription (Whisper) is enabled.
    pub transcribe: Option<Arc<dyn transcribe::Transcriber>>,
    /// Always present — LLM availability is per-user configuration (endpoint,
    /// key, model in the user's settings document), not server wiring.
    pub llm: Arc<dyn llm::Llm>,
    /// Notification connectors (ntfy, Telegram, …). Always present, like
    /// `llm`: reminder channels are per-user configuration in the settings
    /// document, and each connector reads its own keys there. Tests swap in
    /// recording fakes via [`AppState::with_notifiers`].
    pub notifiers: Arc<Vec<Arc<dyn notify::Connector>>>,
    /// note_id -> generation counter, coalescing auto-labeling triggers so a
    /// burst of debounced autosaves costs one LLM call.
    pub label_generations: Arc<Mutex<HashMap<String, u64>>>,
    /// user_id -> progress of a running "re-run embeddings" job, so the
    /// settings UI can show a progress bar. `done == total` means finished;
    /// the entry lingers (at most one per user) until the next reindex.
    pub reindex_progress: Arc<Mutex<HashMap<String, ReindexProgress>>>,
    /// How long a labeling task waits for further edits before it fires.
    /// Tests shrink this.
    pub label_delay: Duration,
    /// HMAC key for signing time-limited file-access URLs. Random per process
    /// by default; `main` loads a persisted secret from the store via
    /// [`AppState::with_file_secret`] so URLs survive restarts.
    pub file_secret: Arc<Vec<u8>>,
    /// Settings the self-hoster pinned via env vars — these override the
    /// per-user copy in the settings document and lock the field in the app.
    /// Empty by default (nothing managed); `main` fills it from the env.
    pub managed: Arc<config::ManagedSettings>,
    /// In-memory cache of link-preview unfurls, keyed by URL. Time-limited so
    /// stale metadata eventually refreshes; not persisted (re-fetched after a
    /// restart). See [`handlers::unfurl`].
    pub unfurl_cache: Arc<Mutex<HashMap<String, (unfurl::LinkPreview, std::time::Instant)>>>,
}

impl AppState {
    pub fn new(repo: Arc<dyn Repository>, files: Arc<dyn FileStore>) -> Self {
        // Random per-process fallback so file URLs are signed even before a
        // persisted secret is loaded (and in tests, which never persist one).
        let mut secret = vec![0u8; 32];
        rand_core::RngCore::fill_bytes(&mut rand_core::OsRng, &mut secret);
        Self {
            repo,
            hub: Hub::default(),
            files,
            search: None,
            transcribe: None,
            llm: Arc::new(llm::OpenAiCompatLlm),
            notifiers: Arc::new(notify::default_connectors()),
            label_generations: Arc::default(),
            reindex_progress: Arc::default(),
            label_delay: Duration::from_secs(20),
            file_secret: Arc::new(secret),
            managed: Arc::new(config::ManagedSettings::default()),
            unfurl_cache: Arc::default(),
        }
    }

    /// Use a persistent signing key so file URLs stay valid across restarts.
    pub fn with_file_secret(mut self, secret: Vec<u8>) -> Self {
        self.file_secret = Arc::new(secret);
        self
    }

    pub fn with_search(mut self, service: Arc<search::SearchService>) -> Self {
        self.search = Some(service);
        self
    }

    pub fn with_transcription(mut self, service: Arc<dyn transcribe::Transcriber>) -> Self {
        self.transcribe = Some(service);
        self
    }

    pub fn with_llm(mut self, service: Arc<dyn llm::Llm>) -> Self {
        self.llm = service;
        self
    }

    pub fn with_notifiers(mut self, connectors: Vec<Arc<dyn notify::Connector>>) -> Self {
        self.notifiers = Arc::new(connectors);
        self
    }

    pub fn with_label_delay(mut self, delay: Duration) -> Self {
        self.label_delay = delay;
        self
    }

    pub fn with_managed(mut self, managed: config::ManagedSettings) -> Self {
        self.managed = Arc::new(managed);
        self
    }
}

/// The full API router. Tests build this against an in-memory repository.
pub fn build_app(state: AppState) -> Router {
    build_app_with_cors_origin(state, None)
}

/// Build the API router with an optional browser-origin allow-list. The
/// production binary supplies the origin derived from `STICKY_NOTES_PUBLIC_URL`.
/// Tests and local development without that setting retain permissive CORS.
pub fn build_app_with_cors_origin(state: AppState, allowed_origin: Option<HeaderValue>) -> Router {
    let api = Router::new()
        .route("/health", get(handlers::health))
        .route("/capabilities", get(handlers::capabilities))
        .route("/managed-settings", get(handlers::managed_settings))
        .route("/auth/register", post(handlers::register))
        .route("/auth/login", post(handlers::login))
        .route("/auth/logout", post(handlers::logout))
        .route(
            "/auth/me",
            get(handlers::me)
                .patch(handlers::update_account)
                .delete(handlers::delete_account),
        )
        .route(
            "/workspaces",
            get(handlers::list_workspaces).post(handlers::create_workspace),
        )
        .route(
            "/workspaces/{id}",
            axum::routing::patch(handlers::rename_workspace).delete(handlers::delete_workspace),
        )
        .route(
            "/workspaces/{id}/members",
            post(handlers::add_workspace_member),
        )
        .route(
            "/workspaces/{id}/members/{user_id}",
            axum::routing::delete(handlers::remove_workspace_member),
        )
        .route(
            "/notes",
            get(handlers::list_notes).post(handlers::create_note),
        )
        .route("/notes/reorder", post(handlers::reorder_notes))
        .route(
            "/notes/{id}",
            get(handlers::get_note)
                .patch(handlers::update_note)
                .delete(handlers::delete_note),
        )
        .route("/notes/{id}/versions", get(handlers::list_note_versions))
        .route(
            "/notes/{id}/versions/{version_id}/restore",
            post(handlers::restore_note_version),
        )
        .route(
            "/notes/{id}/collaborators",
            post(handlers::add_collaborator),
        )
        .route(
            "/notes/{id}/collaborators/{user_id}",
            axum::routing::delete(handlers::remove_collaborator),
        )
        .route("/notes/{id}/attachments", post(handlers::upload_attachment))
        .route("/notes/{id}/transcribe", post(handlers::transcribe_note))
        .route("/notes/{id}/rewrite", post(handlers::rewrite_note))
        .route(
            "/attachments/{id}",
            axum::routing::delete(handlers::delete_attachment),
        )
        .route("/files/{id}", get(handlers::serve_file))
        .route("/checklist-history", get(handlers::checklist_history))
        .route(
            "/settings",
            get(handlers::get_settings).put(handlers::put_settings),
        )
        .route("/search", get(handlers::semantic_search))
        .route("/search/stats", get(handlers::search_stats))
        .route("/search/reindex", post(handlers::reindex_search))
        .route("/search/reindex/status", get(handlers::reindex_status))
        .route("/unfurl", get(handlers::unfurl))
        .route(
            "/labels",
            get(handlers::list_labels).post(handlers::create_label),
        )
        .route(
            "/labels/{id}",
            axum::routing::patch(handlers::update_label).delete(handlers::delete_label),
        )
        .route(
            "/stages",
            get(handlers::list_stages).post(handlers::create_stage),
        )
        .route(
            "/stages/{id}",
            axum::routing::patch(handlers::update_stage).delete(handlers::delete_stage),
        )
        .route("/llm/test", post(handlers::llm_test))
        .route("/notify/test", post(handlers::notify_test))
        .route("/chat", get(handlers::chat_ws))
        .route("/ws", get(handlers::ws_handler))
        .with_state(state);

    let app = Router::new()
        .nest("/api", api)
        .layer(DefaultBodyLimit::max(30 * 1024 * 1024));

    match allowed_origin {
        Some(origin) => app.layer(
            CorsLayer::new()
                // A one-item list mirrors the origin only when it matches.
                // Passing a lone HeaderValue would send that value for every
                // request, which browsers reject but is needlessly confusing.
                .allow_origin([origin])
                .allow_methods(Any)
                .allow_headers(Any),
        ),
        None => app.layer(CorsLayer::very_permissive()),
    }
}

/// Turn a configured public URL into the exact value browsers send in their
/// `Origin` header. Paths and trailing slashes are deliberately discarded.
pub fn cors_origin_from_public_url(raw: &str) -> anyhow::Result<HeaderValue> {
    let url = reqwest::Url::parse(raw.trim())?;
    if !matches!(url.scheme(), "http" | "https") || url.host().is_none() {
        anyhow::bail!("STICKY_NOTES_PUBLIC_URL must be an absolute http(s) URL");
    }
    HeaderValue::try_from(url.origin().ascii_serialization())
        .map_err(|_| anyhow::anyhow!("STICKY_NOTES_PUBLIC_URL contains an invalid origin"))
}

#[cfg(test)]
mod tests {
    use super::cors_origin_from_public_url;

    #[test]
    fn cors_origin_uses_only_scheme_host_and_port() {
        assert_eq!(
            cors_origin_from_public_url("https://notes.example.com/app/")
                .unwrap()
                .to_str()
                .unwrap(),
            "https://notes.example.com",
        );
        assert!(cors_origin_from_public_url("notes.example.com").is_err());
    }
}
