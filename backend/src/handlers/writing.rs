//! Explicit, opt-in AI edits for a single note.
//!
//! Unlike automatic labeling, these requests synchronously return the edited
//! note because the user deliberately asked to replace its content. The final
//! update still runs through [`super::apply_note_update`] so versions, search,
//! labeling, notifications, and shared-note permissions remain consistent.

use axum::Json;
use axum::extract::{Path, State};
use serde::Deserialize;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::models::{KIND_AUDIO, KIND_CHECKLIST, KIND_MARKDOWN, NoteRecord, NoteView, UpdateNote};

use super::{apply_note_update, require_participant};

const MAX_REWRITE_CHARS: usize = 20_000;

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RewriteMode {
    Concise,
    Grammar,
}

#[derive(Deserialize)]
pub struct RewriteRequest {
    pub mode: RewriteMode,
}

#[derive(Deserialize)]
struct RewriteReply {
    title: String,
    #[serde(default)]
    content: String,
    #[serde(default)]
    items: Vec<String>,
}

/// Clean up a note or correct its grammar with the requesting user's enabled
/// LLM. The model's response is deliberately constrained to the editable text
/// fields; note kind, checklist completion state, labels, and attachments are
/// never model-controlled.
pub async fn rewrite_note(
    State(state): State<AppState>,
    AuthUser(user_id): AuthUser,
    Path(id): Path<String>,
    Json(request): Json<RewriteRequest>,
) -> ApiResult<Json<NoteView>> {
    let record = require_participant(&state, &id, &user_id).await?;
    if record.trashed {
        return Err(ApiError::BadRequest(
            "cannot edit a trashed note".to_string(),
        ));
    }
    if record.kind == KIND_AUDIO {
        return Err(ApiError::BadRequest(
            "AI editing is unavailable for audio notes".to_string(),
        ));
    }

    let settings = state.repo.settings_for_user(&user_id).await?;
    let effective = state.managed.overlay(settings.as_deref());
    let llm_settings = crate::assist::parse_llm_settings_value(&effective);
    let Some(cfg) = llm_settings.config.filter(|_| llm_settings.writing) else {
        return Err(ApiError::Unavailable("AI note editing is not enabled"));
    };

    let reply = state
        .llm
        .complete(&cfg, rewrite_messages(&record, request.mode))
        .await
        .map_err(ApiError::Internal)?;
    let RewriteReply {
        title,
        content,
        items,
    } = parse_reply(&reply, &record)?;
    let items = (record.kind == KIND_CHECKLIST).then(|| {
        record
            .items
            .iter()
            .zip(items)
            .map(|(original, text)| crate::models::ChecklistItem {
                id: original.id.clone(),
                text,
                done: original.done,
                // A rewrite changes wording, never structure.
                depth: original.depth,
            })
            .collect()
    });
    let body = UpdateNote {
        workspace_id: None,
        kind: None,
        title: Some(title),
        content: (record.kind != KIND_CHECKLIST).then_some(content),
        items,
        color: None,
        pinned: None,
        archived: None,
        trashed: None,
        position: None,
        reminder_at: None,
        reminder_repeat: None,
        label_ids: None,
        stage_id: None,
        stage_position: None,
    };
    Ok(Json(apply_note_update(&state, &user_id, &id, body).await?))
}

fn rewrite_messages(record: &NoteRecord, mode: RewriteMode) -> Vec<crate::llm::ChatMessage> {
    let instruction = match mode {
        RewriteMode::Concise => {
            "Clean up this note and make it concise. Preserve every important fact, intent, and task; do not add new information."
        }
        RewriteMode::Grammar => {
            "Fix grammar, spelling, punctuation, and syntax only. Do not summarize, rephrase for style, add information, remove information, or change tone."
        }
    };
    let format_instruction = match record.kind.as_str() {
        KIND_MARKDOWN => {
            "This is a Markdown note: preserve meaningful Markdown syntax and structure."
        }
        KIND_CHECKLIST => {
            "This is a checklist: return the title and every item as plain text only, without Markdown syntax or formatting."
        }
        _ => "This is a plain-text note: return the title and content as plain text only, without Markdown syntax or formatting.",
    };
    let language_instruction = "Keep every part of the note in its original language. Never translate it or switch languages; for mixed-language notes, preserve the language of each title, paragraph, and checklist item.";
    let note = if record.kind == KIND_CHECKLIST {
        format!(
            "Title: {}\nChecklist items (keep their order):\n{}",
            record.title,
            record
                .items
                .iter()
                .map(|item| format!("- {}", item.text))
                .collect::<Vec<_>>()
                .join("\n"),
        )
    } else {
        format!("Title: {}\nContent:\n{}", record.title, record.content)
    };
    let shape = if record.kind == KIND_CHECKLIST {
        "Reply ONLY with JSON in this exact shape: {\"title\":\"...\",\"items\":[\"...\"]}. Return exactly one item for every original checklist item."
    } else {
        "Reply ONLY with JSON in this exact shape: {\"title\":\"...\",\"content\":\"...\"}."
    };
    vec![
        crate::llm::ChatMessage::system(format!(
            "You edit one personal note. {instruction} {format_instruction} {language_instruction} {shape}"
        )),
        crate::llm::ChatMessage::user(note),
    ]
}

fn parse_reply(reply: &str, record: &NoteRecord) -> ApiResult<RewriteReply> {
    let trimmed = reply.trim();
    let json = trimmed
        .strip_prefix("```json")
        .or_else(|| trimmed.strip_prefix("```"))
        .map(|body| body.trim().trim_end_matches("```").trim())
        .unwrap_or(trimmed);
    let parsed: RewriteReply = serde_json::from_str(json)
        .map_err(|_| ApiError::BadRequest("AI returned an invalid note edit".to_string()))?;
    let total_chars = parsed.title.chars().count()
        + parsed.content.chars().count()
        + parsed
            .items
            .iter()
            .map(|item| item.chars().count())
            .sum::<usize>();
    if total_chars > MAX_REWRITE_CHARS {
        return Err(ApiError::BadRequest("AI note edit is too long".to_string()));
    }
    if record.kind == KIND_CHECKLIST && parsed.items.len() != record.items.len() {
        return Err(ApiError::BadRequest(
            "AI returned an invalid checklist edit".to_string(),
        ));
    }
    Ok(parsed)
}
