use axum::{Json, http::StatusCode, response::{IntoResponse, Response}};

use crate::store::RepoError;

pub enum ApiError {
    Unauthorized,
    Forbidden(&'static str),
    NotFound,
    BadRequest(String),
    Conflict(String),
    /// Optional feature (e.g. semantic search) not enabled on this server.
    Unavailable(&'static str),
    Internal(anyhow::Error),
}

impl From<RepoError> for ApiError {
    fn from(e: RepoError) -> Self {
        match e {
            RepoError::Conflict(m) => ApiError::Conflict(m),
            RepoError::Other(e) => ApiError::Internal(e),
        }
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(e: anyhow::Error) -> Self {
        ApiError::Internal(e)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            ApiError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized".to_string()),
            ApiError::Forbidden(m) => (StatusCode::FORBIDDEN, m.to_string()),
            ApiError::NotFound => (StatusCode::NOT_FOUND, "not found".to_string()),
            ApiError::BadRequest(m) => (StatusCode::BAD_REQUEST, m),
            ApiError::Conflict(m) => (StatusCode::CONFLICT, m),
            ApiError::Unavailable(m) => (StatusCode::SERVICE_UNAVAILABLE, m.to_string()),
            ApiError::Internal(e) => {
                eprintln!("internal error: {e:#}");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error".to_string())
            }
        };
        (status, Json(serde_json::json!({ "error": message }))).into_response()
    }
}

pub type ApiResult<T> = Result<T, ApiError>;
