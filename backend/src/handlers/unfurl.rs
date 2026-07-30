//! Link-preview endpoint: fetch a URL server-side and return its Open Graph /
//! HTML metadata for the client's preview card. Results are cached in memory
//! (keyed by URL, time-limited) so repeated views of the same link, every
//! grid card and the editor share the client cache too, don't refetch.

use std::time::{Duration, Instant};

use axum::Json;
use axum::extract::{Query, State};
use serde::Deserialize;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::unfurl::{self, LinkPreview};

/// How long a cached preview stays fresh.
const CACHE_TTL: Duration = Duration::from_secs(6 * 60 * 60);
/// Soft cap on cache size; cleared wholesale when exceeded (previews are cheap
/// to rebuild and this only bounds memory).
const CACHE_CAP: usize = 512;

#[derive(Deserialize)]
pub struct UnfurlQuery {
    url: String,
}

/// Fetch link metadata for `?url=`. Auth-gated (the server makes an outbound
/// request on the caller's behalf). Invalid or SSRF-blocked URLs answer 400;
/// a fetch that fails after a valid URL still returns a host-only preview.
pub async fn unfurl(
    State(state): State<AppState>,
    AuthUser(_user_id): AuthUser,
    Query(query): Query<UnfurlQuery>,
) -> ApiResult<Json<LinkPreview>> {
    let key = query.url.trim().to_string();
    if key.is_empty() {
        return Err(ApiError::BadRequest("url is required".to_string()));
    }

    if let Some(cached) = cache_get(&state, &key) {
        return Ok(Json(cached));
    }

    let preview = unfurl::preview_for(&key, unfurl::allow_private())
        .await
        .map_err(|e| ApiError::BadRequest(format!("{e:#}")))?;
    cache_put(&state, key, preview.clone());
    Ok(Json(preview))
}

fn cache_get(state: &AppState, key: &str) -> Option<LinkPreview> {
    let mut cache = state.unfurl_cache.lock().unwrap();
    match cache.get(key) {
        Some((preview, at)) if at.elapsed() < CACHE_TTL => Some(preview.clone()),
        Some(_) => {
            cache.remove(key);
            None
        }
        None => None,
    }
}

fn cache_put(state: &AppState, key: String, preview: LinkPreview) {
    let mut cache = state.unfurl_cache.lock().unwrap();
    if cache.len() >= CACHE_CAP {
        cache.clear();
    }
    cache.insert(key, (preview, Instant::now()));
}
