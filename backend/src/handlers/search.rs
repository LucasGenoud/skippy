//! Semantic (meaning-based) note search.

use axum::extract::{Query, State};
use axum::Json;
use serde::Deserialize;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};

#[derive(Deserialize)]
pub struct SearchParams {
    q: String,
    #[serde(default)]
    limit: Option<usize>,
}

/// Meaning-based note search. Returns ranked note ids with scores; the
/// client maps them onto notes it already has.
pub async fn semantic_search(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Query(params): Query<SearchParams>,
) -> ApiResult<Json<serde_json::Value>> {
    let Some(search) = &state.search else {
        return Err(ApiError::Unavailable("semantic search is not enabled on this server"));
    };
    let query = params.q.trim();
    if query.is_empty() {
        return Ok(Json(serde_json::json!([])));
    }
    let limit = params.limit.unwrap_or(20).min(50);
    let hits: Vec<_> = search
        .search(&user_id, query, limit)
        .await?
        .into_iter()
        .map(|(note_id, score)| serde_json::json!({"note_id": note_id, "score": score}))
        .collect();
    Ok(Json(serde_json::json!(hits)))
}
