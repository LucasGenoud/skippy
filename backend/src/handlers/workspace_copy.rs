//! Explicit, online copies. Source sharing and history never travel to a copy.
use crate::{
    AppState,
    auth::AuthUser,
    error::{ApiError, ApiResult},
    models::*,
};
use axum::{
    Json,
    extract::{Path, State},
    http::StatusCode,
};
use serde::Deserialize;
use std::collections::HashMap;

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CopyContent {
    Structure,
    Notes,
}
#[derive(Deserialize)]
pub struct CopyWorkspace {
    pub name: String,
    pub content: CopyContent,
    #[serde(default)]
    pub reminders: bool,
}

pub async fn duplicate_workspace(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(source_id): Path<String>,
    Json(body): Json<CopyWorkspace>,
) -> ApiResult<(StatusCode, Json<WorkspaceView>)> {
    let name = body.name.trim();
    if name.is_empty() || name.chars().count() > 60 || name.chars().any(char::is_control) {
        return Err(ApiError::BadRequest(
            "workspace name must be 1-60 characters".into(),
        ));
    }
    let source = state
        .repo
        .workspaces_for_user(&user_id)
        .await?
        .into_iter()
        .find(|w| w.id == source_id)
        .ok_or(ApiError::NotFound)?;
    // A disconnected client does not interrupt blob copying halfway through.
    tokio::spawn(async move { copy_workspace(state, user_id, source, body).await })
        .await
        .map_err(|error| ApiError::Internal(error.into()))?
}

async fn copy_workspace(
    state: AppState,
    user_id: String,
    source: WorkspaceView,
    body: CopyWorkspace,
) -> ApiResult<(StatusCode, Json<WorkspaceView>)> {
    let name = body.name.trim();
    let target = Workspace {
        id: super::new_id(),
        name: name.into(),
        owner_id: user_id.clone(),
        notes_enabled: true,
        board_enabled: true,
        is_default: false,
        created_at: super::now(),
    };
    state.repo.insert_workspace_copy(&target).await?;
    let result = copy_contents(&state, &user_id, &source, &target, &body).await;
    if let Err(error) = result {
        // Deletion records blob and vector cleanup before committing, so failed
        // copies cannot leak attachments when an object store is unavailable.
        state.repo.delete_workspace(&target.id).await?;
        state.drain_cleanup_jobs().await;
        return Err(error);
    }
    state.repo.finish_workspace_copy(&target.id).await?;
    state.notify_user(&user_id);
    let view = state
        .repo
        .workspaces_for_user(&user_id)
        .await?
        .into_iter()
        .find(|w| w.id == target.id)
        .ok_or(ApiError::NotFound)?;
    Ok((StatusCode::CREATED, Json(view)))
}

async fn copy_contents(
    state: &AppState,
    user_id: &str,
    source: &WorkspaceView,
    target: &Workspace,
    body: &CopyWorkspace,
) -> ApiResult<()> {
    let mut collections = HashMap::new();
    for (i, old) in source.collections.iter().enumerate() {
        let mut c = old.clone();
        c.id = if i == 0 {
            format!("{}-general", target.id)
        } else {
            super::new_id()
        };
        c.workspace_id = target.id.clone();
        state.repo.put_collection(user_id, &c).await?;
        collections.insert(old.id.clone(), c.id);
    }
    if source.collections.is_empty() {
        state
            .repo
            .delete_collection(user_id, &target.id, &format!("{}-general", target.id))
            .await?;
    }
    let mut labels = HashMap::new();
    for mut label in state
        .repo
        .labels_for_user(user_id)
        .await?
        .into_iter()
        .filter(|l| l.workspace_id == source.id)
    {
        let old = label.id.clone();
        label.id = super::new_id();
        label.workspace_id = target.id.clone();
        state.repo.insert_label(&label).await?;
        labels.insert(old, label.id);
    }
    let mut stages = HashMap::new();
    for mut stage in state
        .repo
        .stages_for_user(user_id)
        .await?
        .into_iter()
        .filter(|s| s.workspace_id == source.id)
    {
        let Some(collection) = stage
            .collection_id
            .as_ref()
            .and_then(|id| collections.get(id))
        else {
            continue;
        };
        let old = stage.id.clone();
        stage.id = super::new_id();
        stage.workspace_id = target.id.clone();
        stage.collection_id = Some(collection.clone());
        state.repo.insert_stage(&stage).await?;
        stages.insert(old, stage.id);
    }
    for old in &source.smart_views {
        let mut view = old.clone();
        view.id = super::new_id();
        state
            .repo
            .put_smart_view(user_id, &target.id, &view)
            .await?;
    }
    if matches!(body.content, CopyContent::Structure) {
        return Ok(());
    }
    let mut new_ids = Vec::new();
    for view in state
        .repo
        .notes_for_user(user_id)
        .await?
        .into_iter()
        .filter(|n| n.note.workspace_id == source.id && !n.note.trashed)
    {
        let Some(mut note) = state
            .repo
            .note_record_for_user(&view.note.id, user_id)
            .await?
        else {
            continue;
        };
        note.id = super::new_id();
        note.workspace_id = target.id.clone();
        note.created_by = Some(user_id.into());
        note.last_editor_id = None;
        note.collection_id = note
            .collection_id
            .as_ref()
            .and_then(|id| collections.get(id))
            .cloned();
        if note.collection_id.is_none() {
            return Err(ApiError::Conflict(
                "source collection changed during duplication; try again".into(),
            ));
        }
        note.stage_id = note
            .stage_id
            .as_ref()
            .and_then(|id| stages.get(id))
            .cloned();
        if !body.reminders {
            note.reminder_at = None;
            note.reminder_repeat = None;
            note.reminder_fired_at = None;
        }
        if note.transcript_status == TRANSCRIPT_PENDING {
            note.transcript_status = TRANSCRIPT_FAILED.into();
        }
        state.repo.insert_note(&note).await?;

        let label_ids = view
            .label_ids
            .iter()
            .filter_map(|id| labels.get(id))
            .cloned()
            .collect::<Vec<_>>();
        state.repo.set_note_labels(&note.id, &label_ids).await?;
        if body.reminders {
            for reminder in view.item_reminders {
                state.repo.set_item_reminder(&note.id, &reminder).await?;
            }
        }
        for old in view.attachments {
            let bytes = state.files.read(&old.id).await.ok_or_else(|| {
                ApiError::Conflict("an attachment could not be read; try again".into())
            })?;
            let mut attachment = old.clone();
            attachment.id = super::new_id();
            attachment.url = None;
            // Metadata first makes even a partially written blob discoverable
            // by rollback and durable cleanup.
            state.repo.insert_attachment(&attachment, &note.id).await?;
            state.files.save(&attachment.id, &bytes).await?;
            if let Some(text) = old.ocr_text {
                state.repo.set_attachment_ocr(&attachment.id, &text).await?;
            }
        }
        new_ids.push(note.id);
    }
    for id in new_ids {
        state.index_note_later(&id);
    }
    Ok(())
}
