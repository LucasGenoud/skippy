//! Public, read-only share links.
//!
//! A link combines a random stored identifier with an HMAC capability that
//! anyone can exchange for a read-only payload, with no account and no
//! session. Copying a `share_links` row therefore does not itself expose a
//! working public URL. Three properties shape everything here:
//!
//! * **Only the workspace owner publishes.** Both a note link and a whole-view
//!   link follow the owning workspace's lifecycle authority, matching the rest
//!   of the app where trashing, deleting, and rewriting the roster are the
//!   owner's calls.
//! * **The payload is what the owner can see, narrowed to the target.** It is
//!   assembled from `notes_for_user(owner)`, so a public page can never show
//!   more than the person who published it, and nothing extra has to be
//!   re-implemented here.
//! * **Nothing about people goes out.** [`PublicNote`] lists every public
//!   field explicitly (see its docs), and the only identity in the response is
//!   the publisher's display name.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::{HeaderName, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use chrono::{DateTime, Utc};
use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::models::*;

use super::{is_note_workspace_owner, new_token, now};

fn public_token(secret: &[u8], stored_id: &str) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret).expect("HMAC accepts any key length");
    mac.update(b"share-link\n");
    mac.update(stored_id.as_bytes());
    format!("{stored_id}.{}", hex::encode(mac.finalize().into_bytes()))
}

fn stored_id_from_public_token<'a>(secret: &[u8], token: &'a str) -> Option<&'a str> {
    let (stored_id, signature) = token.split_once('.')?;
    if stored_id.is_empty() || signature.is_empty() || signature.contains('.') {
        return None;
    }
    let provided = hex::decode(signature).ok()?;
    let mut mac = Hmac::<Sha256>::new_from_slice(secret).ok()?;
    mac.update(b"share-link\n");
    mac.update(stored_id.as_bytes());
    mac.verify_slice(&provided).ok()?;
    Some(stored_id)
}

fn expired(link: &ShareLink) -> bool {
    let Some(expires_at) = &link.expires_at else {
        return false;
    };
    match DateTime::parse_from_rfc3339(expires_at) {
        Ok(instant) => instant.with_timezone(&Utc) <= Utc::now(),
        // An unparseable expiry is treated as expired: a link nobody can date
        // must not be one that lives forever.
        Err(_) => true,
    }
}

pub async fn list_share_links(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
) -> ApiResult<Json<Vec<ShareLinkView>>> {
    let links = state.repo.share_links_for_user(&user_id).await?;
    let mut out = Vec::with_capacity(links.len());
    for link in links {
        // Settings describes this as the list of things that are currently
        // public. Keep expired capabilities out of it; create_share_link also
        // replaces them when the same target is published again.
        if expired(&link) {
            continue;
        }
        out.push(view_of(&state, &link).await?);
    }
    Ok(Json(out))
}

pub async fn create_share_link(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Json(body): Json<CreateShareLink>,
) -> ApiResult<(StatusCode, Json<ShareLinkView>)> {
    let target = body.target.trim().to_string();
    if !SHARE_TARGETS.contains(&target.as_str()) {
        return Err(ApiError::BadRequest(format!(
            "unknown share target '{target}'"
        )));
    }
    if let Some(expires_at) = &body.expires_at {
        let instant = DateTime::parse_from_rfc3339(expires_at)
            .map_err(|_| ApiError::BadRequest("expires_at must be RFC3339".to_string()))?;
        if instant.with_timezone(&Utc) <= Utc::now() {
            return Err(ApiError::BadRequest(
                "expires_at is already in the past".to_string(),
            ));
        }
    }

    // Resolve and authorize the target, keeping only the id column it uses so
    // a stray `label_id` on a note link cannot end up stored.
    let (note_id, workspace_id, label_id) = match target.as_str() {
        SHARE_TARGET_NOTE => {
            let id = required(&body.note_id, "note_id")?;
            // `_for_user` rather than a bare record lookup: a stranger must
            // get 404 so note ids stay unguessable, and only someone who can
            // already see the note is told that publishing is the owner's.
            let record = state
                .repo
                .note_record_for_user(&id, &user_id)
                .await?
                .ok_or(ApiError::NotFound)?;
            if !is_note_workspace_owner(&state, &record, &user_id).await? {
                return Err(ApiError::Forbidden(
                    "only the owner can share a note publicly",
                ));
            }
            if record.trashed {
                return Err(ApiError::BadRequest(
                    "a trashed note cannot be shared".to_string(),
                ));
            }
            (Some(id), None, None)
        }
        SHARE_TARGET_NOTES | SHARE_TARGET_BOARD => {
            let id = required(&body.workspace_id, "workspace_id")?;
            require_workspace_owner(&state, &id, &user_id).await?;
            (None, Some(id), None)
        }
        SHARE_TARGET_LABEL => {
            let id = required(&body.label_id, "label_id")?;
            let label = state
                .repo
                .labels_for_user(&user_id)
                .await?
                .into_iter()
                .find(|l| l.id == id)
                .ok_or(ApiError::NotFound)?;
            require_workspace_owner(&state, &label.workspace_id, &user_id).await?;
            (None, None, Some(id))
        }
        _ => unreachable!("target was checked against SHARE_TARGETS"),
    };

    // Publishing the same thing twice hands back the link that already exists.
    // Minting a second one would leave the first live and unlisted next to it,
    // and "share" reads as an idempotent action, not as "make another URL".
    if let Some(existing) = state
        .repo
        .share_link_for_target(
            &user_id,
            &target,
            note_id.as_deref(),
            workspace_id.as_deref(),
            label_id.as_deref(),
        )
        .await?
    {
        if !expired(&existing) {
            let view = view_of(&state, &existing).await?;
            return Ok((StatusCode::OK, Json(view)));
        }
        // An expired token is no longer a public link. Remove it before
        // minting the replacement so idempotency does not strand a target on
        // a permanently dead capability.
        state
            .repo
            .delete_share_link(&user_id, &existing.token)
            .await?;
    }

    let link = ShareLink {
        token: new_token(),
        created_by: user_id,
        target,
        note_id,
        workspace_id,
        label_id,
        created_at: now(),
        expires_at: body.expires_at,
    };
    state.repo.insert_share_link(&link).await?;
    let view = view_of(&state, &link).await?;
    Ok((StatusCode::CREATED, Json(view)))
}

pub async fn delete_share_link(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(token): Path<String>,
) -> ApiResult<StatusCode> {
    let stored_id =
        stored_id_from_public_token(&state.file_secret, &token).ok_or(ApiError::NotFound)?;
    if state.repo.delete_share_link(&user_id, stored_id).await? {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::NotFound)
    }
}

/// The public page's data. **Unauthenticated on purpose**: the token in the
/// path is the credential. Missing, revoked, and expired all answer 404, so a
/// probe cannot tell a wrong token from one that used to work.
pub async fn public_share(
    State(state): State<AppState>,
    Path(token): Path<String>,
) -> ApiResult<Response> {
    let stored_id =
        stored_id_from_public_token(&state.file_secret, &token).ok_or(ApiError::NotFound)?;
    let link = state
        .repo
        .share_link(stored_id)
        .await?
        .filter(|link| !expired(link))
        .ok_or(ApiError::NotFound)?;

    let owner = state
        .repo
        .user_by_id(&link.created_by)
        .await?
        .ok_or(ApiError::NotFound)?;
    // Everything the publisher can currently see. The target narrows it below,
    // which is what keeps a public page from ever outrunning its owner's own
    // access: lose access to a note, and it drops out of the page too.
    let mut visible = state.repo.notes_for_user(&link.created_by).await?;
    state.sign_views(&mut visible);
    let labels = state.repo.labels_for_user(&link.created_by).await?;

    let (title, notes, stages) = match link.target.as_str() {
        SHARE_TARGET_NOTE => {
            let note_id = link.note_id.clone().unwrap_or_default();
            let view = visible
                .into_iter()
                .find(|v| v.note.id == note_id && !v.note.trashed)
                .ok_or(ApiError::NotFound)?;
            (title_of_note(&view), vec![view], vec![])
        }
        SHARE_TARGET_NOTES => {
            let workspace_id = link.workspace_id.clone().unwrap_or_default();
            let workspace = state
                .repo
                .workspace(&workspace_id)
                .await?
                .ok_or(ApiError::NotFound)?;
            (
                workspace.name,
                live_in_workspace(visible, &workspace_id),
                vec![],
            )
        }
        SHARE_TARGET_BOARD => {
            let workspace_id = link.workspace_id.clone().unwrap_or_default();
            let workspace = state
                .repo
                .workspace(&workspace_id)
                .await?
                .ok_or(ApiError::NotFound)?;
            let stages = state
                .repo
                .stages_for_user(&link.created_by)
                .await?
                .into_iter()
                .filter(|stage| stage.workspace_id == workspace_id)
                .collect();
            (
                workspace.name,
                live_in_workspace(visible, &workspace_id),
                stages,
            )
        }
        SHARE_TARGET_LABEL => {
            let label_id = link.label_id.clone().unwrap_or_default();
            let label = labels
                .iter()
                .find(|l| l.id == label_id)
                .ok_or(ApiError::NotFound)?;
            let notes = visible
                .into_iter()
                .filter(|v| !v.note.trashed && !v.note.archived && v.label_ids.contains(&label_id))
                .collect();
            (label.name.clone(), notes, vec![])
        }
        // A target the running build does not know: refuse rather than guess.
        _ => return Err(ApiError::NotFound),
    };

    // Only the labels the payload actually references, so a public page does
    // not enumerate a workspace's whole taxonomy.
    let used: std::collections::HashSet<&String> =
        notes.iter().flat_map(|v| v.label_ids.iter()).collect();
    let labels = labels
        .into_iter()
        .filter(|label| used.contains(&label.id))
        .collect();

    let share = PublicShare {
        target: link.target.clone(),
        title,
        shared_by: owner.name,
        notes: notes.iter().map(public_note).collect(),
        labels,
        stages,
        expires_at: link.expires_at.clone(),
    };
    Ok((
        [
            // A shared page is not for search engines, whatever the holder of
            // the link does with it, and not for shared caches either.
            (
                HeaderName::from_static("x-robots-tag"),
                HeaderValue::from_static("noindex, nofollow"),
            ),
            (
                axum::http::header::CACHE_CONTROL,
                HeaderValue::from_static("private, no-store"),
            ),
        ],
        Json(share),
    )
        .into_response())
}

/// Live notes of one workspace, in the grid's own order.
fn live_in_workspace(views: Vec<NoteView>, workspace_id: &str) -> Vec<NoteView> {
    let mut notes: Vec<NoteView> = views
        .into_iter()
        .filter(|v| v.note.workspace_id == workspace_id && !v.note.trashed && !v.note.archived)
        .collect();
    notes.sort_by(|a, b| {
        b.note
            .pinned
            .cmp(&a.note.pinned)
            .then(a.note.position.total_cmp(&b.note.position))
    });
    notes
}

fn public_note(view: &NoteView) -> PublicNote {
    PublicNote {
        id: view.note.id.clone(),
        kind: view.note.kind.clone(),
        title: view.note.title.clone(),
        content: view.note.content.clone(),
        items: view.note.items.clone(),
        color: view.note.color.clone(),
        pinned: view.note.pinned,
        position: view.note.position,
        label_ids: view.label_ids.clone(),
        stage_id: view.note.stage_id.clone(),
        stage_position: view.note.stage_position,
        created_at: view.note.created_at.clone(),
        updated_at: view.note.updated_at.clone(),
        attachments: view.attachments.clone(),
    }
}

fn title_of_note(view: &NoteView) -> String {
    let title = view.note.title.trim();
    if !title.is_empty() {
        return title.to_string();
    }
    "Shared note".to_string()
}

fn required(value: &Option<String>, field: &str) -> ApiResult<String> {
    value
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_string)
        .ok_or_else(|| ApiError::BadRequest(format!("{field} is required for this target")))
}

/// Publishing a whole view exposes every note in it, including notes other
/// members wrote, so it takes the workspace's owner rather than any member.
async fn require_workspace_owner(
    state: &AppState,
    workspace_id: &str,
    user_id: &str,
) -> ApiResult<()> {
    let workspace = state
        .repo
        .workspace(workspace_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    if workspace.owner_id != user_id {
        return Err(ApiError::Forbidden(
            "only the workspace owner can share it publicly",
        ));
    }
    Ok(())
}

/// Name the link's target for the owner's list of links. A target that has
/// since been deleted still lists (the row cascades away, but a rename or a
/// lost label should not break the screen), so this never fails.
async fn view_of(state: &AppState, link: &ShareLink) -> ApiResult<ShareLinkView> {
    let title = match link.target.as_str() {
        SHARE_TARGET_NOTE => match &link.note_id {
            Some(id) => state
                .repo
                .note_record(id)
                .await?
                .map(|record| {
                    let title = record.title.trim().to_string();
                    if title.is_empty() {
                        "Shared note".to_string()
                    } else {
                        title
                    }
                })
                .unwrap_or_else(|| "Shared note".to_string()),
            None => "Shared note".to_string(),
        },
        SHARE_TARGET_NOTES | SHARE_TARGET_BOARD => match &link.workspace_id {
            Some(id) => state
                .repo
                .workspace(id)
                .await?
                .map(|w| w.name)
                .unwrap_or_else(|| "Workspace".to_string()),
            None => "Workspace".to_string(),
        },
        _ => match &link.label_id {
            Some(id) => state
                .repo
                .labels_for_user(&link.created_by)
                .await?
                .into_iter()
                .find(|l| l.id == *id)
                .map(|l| l.name)
                .unwrap_or_else(|| "Label".to_string()),
            None => "Label".to_string(),
        },
    };
    Ok(ShareLinkView {
        token: public_token(&state.file_secret, &link.token),
        target: link.target.clone(),
        note_id: link.note_id.clone(),
        workspace_id: link.workspace_id.clone(),
        label_id: link.label_id.clone(),
        title,
        created_at: link.created_at.clone(),
        expires_at: link.expires_at.clone(),
    })
}
