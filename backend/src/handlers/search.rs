//! Semantic (meaning-based) note search.

use axum::extract::{Query, State};
use axum::Json;
use serde::Deserialize;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::models::NoteFields;

/// Whether a note has any text the embedder would index — its title, content,
/// or a checklist item. Mirrors the emptiness check in
/// [`crate::search::SearchService::note_text`]: a note with only whitespace (or
/// only non-text attachments) is never embedded.
fn has_embeddable_text(note: &NoteFields) -> bool {
    !note.title.trim().is_empty()
        || !note.content.trim().is_empty()
        || note.items.iter().any(|i| !i.text.trim().is_empty())
}

#[derive(Deserialize)]
pub struct SearchParams {
    q: String,
    #[serde(default)]
    limit: Option<usize>,
    /// Restrict results to one workspace, so search matches what the open
    /// workspace shows. Absent searches everything the caller can see.
    #[serde(default)]
    workspace_id: Option<String>,
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
    let workspace = params.workspace_id.as_deref().map(str::trim).filter(|w| !w.is_empty());
    // The vector index is scoped by participant, not by workspace, so a
    // workspace filter is applied afterwards — over-fetch to keep the ranked
    // list full once the other workspaces' hits drop out.
    let fetch = if workspace.is_some() { (limit * 4).min(200) } else { limit };
    let allowed = match workspace {
        Some(workspace_id) => {
            Some(crate::handlers::workspace_note_ids(&state, &user_id, workspace_id).await?)
        }
        None => None,
    };
    let hits: Vec<_> = search
        .search(&user_id, query, fetch)
        .await?
        .into_iter()
        .filter(|(note_id, _)| allowed.as_ref().is_none_or(|ids| ids.contains(note_id)))
        .take(limit)
        .map(|(note_id, score)| serde_json::json!({"note_id": note_id, "score": score}))
        .collect();
    Ok(Json(serde_json::json!(hits)))
}

/// Diagnostics for the semantic-search index: which model embeds notes, its
/// vector width, and how many of the caller's notes are indexed. Returns
/// `{"enabled": false}` when the server has semantic search off.
pub async fn search_stats(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
) -> ApiResult<Json<serde_json::Value>> {
    let Some(search) = &state.search else {
        return Ok(Json(serde_json::json!({ "enabled": false })));
    };
    // Notes with no embeddable text (e.g. audio- or image-only notes) are never
    // indexed — see `index_note` — so counting them in the total would leave the
    // "X / Y embedded" stat permanently short of complete. Only count notes that
    // actually have text to embed.
    let total_notes = state
        .repo
        .notes_for_user(&user_id)
        .await?
        .iter()
        .filter(|v| has_embeddable_text(&v.note))
        .count();
    let indexed_notes = search.indexed_count(&user_id).await?;
    Ok(Json(serde_json::json!({
        "enabled": true,
        "model": search.model_name(),
        "dimensions": search.dims(),
        "total_notes": total_notes,
        "indexed_notes": indexed_notes,
    })))
}

/// Re-embed all of the caller's notes in the background (e.g. after an
/// embedding-model change, or to fill coverage gaps). Returns the number of
/// notes to embed; the client polls [`reindex_status`] to drive a progress
/// bar. Embedding runs one note at a time so progress can be counted.
pub async fn reindex_search(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
) -> ApiResult<Json<serde_json::Value>> {
    let Some(search) = state.search.clone() else {
        return Err(ApiError::Unavailable("semantic search is not enabled on this server"));
    };

    // Don't start a second job while one is still running for this user.
    {
        let progress = state.reindex_progress.lock().unwrap();
        if let Some(p) = progress.get(&user_id)
            && p.done < p.total
        {
            return Ok(Json(serde_json::json!({ "total": p.total, "running": true })));
        }
    }

    let ids: Vec<String> =
        state.repo.notes_for_user(&user_id).await?.into_iter().map(|n| n.note.id).collect();
    let total = ids.len();
    state
        .reindex_progress
        .lock()
        .unwrap()
        .insert(user_id.clone(), crate::ReindexProgress { done: 0, total });

    let worker = state.clone();
    tokio::spawn(async move {
        for id in ids {
            if let Ok(Some(record)) = worker.repo.note_record(&id).await {
                let participants = worker.repo.participant_ids(&id).await.unwrap_or_default();
                if let Err(e) = search.index_note(&record, participants).await {
                    eprintln!("reindex failed for {id}: {e:#}");
                }
            }
            // Count the note as processed even if it errored, so a single bad
            // note can't stall the bar; the next reindex retries it.
            if let Some(p) = worker.reindex_progress.lock().unwrap().get_mut(&user_id) {
                p.done += 1;
            }
        }
    });

    Ok(Json(serde_json::json!({ "total": total, "running": total > 0 })))
}

/// Progress of the caller's running reindex job (see [`reindex_search`]).
/// `running` is false when no job exists or the last one finished.
pub async fn reindex_status(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
) -> Json<serde_json::Value> {
    let progress = state.reindex_progress.lock().unwrap().get(&user_id).copied();
    match progress {
        Some(p) => Json(serde_json::json!({
            "running": p.done < p.total,
            "done": p.done,
            "total": p.total,
        })),
        None => Json(serde_json::json!({ "running": false, "done": 0, "total": 0 })),
    }
}
