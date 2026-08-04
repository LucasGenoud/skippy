use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};

use crate::store::RepoError;

#[derive(Debug)]
pub enum ApiError {
    Unauthorized,
    Forbidden(&'static str),
    NotFound,
    BadRequest(String),
    Conflict(String),
    RateLimited(u64),
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
        let (status, message, retry_after) = match self {
            ApiError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized".to_string(), None),
            ApiError::Forbidden(m) => (StatusCode::FORBIDDEN, m.to_string(), None),
            ApiError::NotFound => (StatusCode::NOT_FOUND, "not found".to_string(), None),
            ApiError::BadRequest(m) => (StatusCode::BAD_REQUEST, m, None),
            ApiError::Conflict(m) => (StatusCode::CONFLICT, m, None),
            ApiError::RateLimited(seconds) => (
                StatusCode::TOO_MANY_REQUESTS,
                "too many attempts; try again later".to_string(),
                Some(seconds),
            ),
            ApiError::Unavailable(m) => (StatusCode::SERVICE_UNAVAILABLE, m.to_string(), None),
            ApiError::Internal(e) => {
                crate::telemetry::event(
                    "error",
                    "request_internal_error",
                    serde_json::json!({
                        "request_id": crate::telemetry::current_request_id(),
                        "error": format!("{e:#}"),
                    }),
                );
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "internal error".to_string(),
                    None,
                )
            }
        };
        let mut response = (status, Json(serde_json::json!({ "error": message }))).into_response();
        if let Some(seconds) = retry_after {
            response.headers_mut().insert(
                axum::http::header::RETRY_AFTER,
                seconds
                    .to_string()
                    .parse()
                    .expect("retry seconds are a header"),
            );
        }
        response
    }
}

pub type ApiResult<T> = Result<T, ApiError>;
