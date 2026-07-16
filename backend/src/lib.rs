pub mod auth;
pub mod error;
pub mod files;
pub mod handlers;
pub mod models;
pub mod search;
pub mod store;
pub mod transcribe;
pub mod ws;

use std::sync::Arc;

use axum::extract::DefaultBodyLimit;
use axum::routing::{get, post};
use axum::Router;
use tower_http::cors::CorsLayer;

use crate::files::FileStore;
use crate::store::Repository;
use crate::ws::Hub;

#[derive(Clone)]
pub struct AppState {
    pub repo: Arc<dyn Repository>,
    pub hub: Hub,
    pub files: FileStore,
    /// Present when semantic search is enabled.
    pub search: Option<Arc<search::SearchService>>,
    /// Present when audio transcription (Whisper) is enabled.
    pub transcribe: Option<Arc<dyn transcribe::Transcriber>>,
}

impl AppState {
    pub fn new(repo: Arc<dyn Repository>, files: FileStore) -> Self {
        Self { repo, hub: Hub::default(), files, search: None, transcribe: None }
    }

    pub fn with_search(mut self, service: Arc<search::SearchService>) -> Self {
        self.search = Some(service);
        self
    }

    pub fn with_transcription(mut self, service: Arc<dyn transcribe::Transcriber>) -> Self {
        self.transcribe = Some(service);
        self
    }
}

/// The full API router. Tests build this against an in-memory repository.
pub fn build_app(state: AppState) -> Router {
    let api = Router::new()
        .route("/health", get(handlers::health))
        .route("/capabilities", get(handlers::capabilities))
        .route("/auth/register", post(handlers::register))
        .route("/auth/login", post(handlers::login))
        .route("/auth/logout", post(handlers::logout))
        .route("/auth/me", get(handlers::me))
        .route("/notes", get(handlers::list_notes).post(handlers::create_note))
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
        .route("/notes/{id}/collaborators", post(handlers::add_collaborator))
        .route(
            "/notes/{id}/collaborators/{user_id}",
            axum::routing::delete(handlers::remove_collaborator),
        )
        .route("/notes/{id}/attachments", post(handlers::upload_attachment))
        .route("/notes/{id}/transcribe", post(handlers::transcribe_note))
        .route("/attachments/{id}", axum::routing::delete(handlers::delete_attachment))
        .route("/files/{id}", get(handlers::serve_file))
        .route("/checklist-history", get(handlers::checklist_history))
        .route("/settings", get(handlers::get_settings).put(handlers::put_settings))
        .route("/search", get(handlers::semantic_search))
        .route("/labels", get(handlers::list_labels).post(handlers::create_label))
        .route(
            "/labels/{id}",
            axum::routing::patch(handlers::update_label).delete(handlers::delete_label),
        )
        .route("/ws", get(handlers::ws_handler))
        .with_state(state);

    Router::new()
        .nest("/api", api)
        .layer(DefaultBodyLimit::max(30 * 1024 * 1024))
        .layer(CorsLayer::very_permissive())
}
