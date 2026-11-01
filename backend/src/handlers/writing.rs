//! Explicit, opt-in AI edits for a single note.
//!
//! Unlike automatic labeling, these requests synchronously return the edited
//! note because the user deliberately asked to replace its content. The final
//! update still runs through [`super::apply_note_update`] so versions, search,
//! labeling, notifications, and shared-note permissions remain consistent.

use std::fmt;
use std::time::Duration;

use axum::Json;
use axum::extract::{Path, State};
use serde::Deserialize;
use serde_json::{Map, Value};

use crate::AppState;
use crate::assist;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::llm::{ChatMessage, LlmConfig};
use crate::models::{
    ChecklistItem, KIND_AUDIO, KIND_CHECKLIST, KIND_MARKDOWN, NoteRecord, NoteView, UpdateNote,
};

use super::workspace_ai::{AiFeature, workspace_ai};
use super::{apply_note_update, require_participant};

/// The most text a rewrite takes in or hands back.
const MAX_REWRITE_CHARS: usize = 20_000;

/// A first reply that cannot be used gets one correction round.
const REWRITE_ATTEMPTS: usize = 2;

/// The whole rewrite, correction included, finishes inside this or gives up,
/// so it ends before a proxy's usual 60 second read timeout and long before
/// the app stops waiting.
const REWRITE_BUDGET: Duration = Duration::from_secs(50);

#[derive(Deserialize)]
pub struct RewriteRequest {
    #[serde(alias = "mode")]
    pub task_id: String,
}

/// The text fields a rewrite replaces. Kind, ticks, nesting, labels and
/// attachments are never the model's to change.
struct NoteEdit {
    title: String,
    content: Option<String>,
    items: Option<Vec<ChecklistItem>>,
}

/// Why a reply could not be used, worded for the model's correction round.
enum EditProblem {
    NotJson,
    NoContent,
    Emptied,
    NoItems,
    ItemCount { expected: usize, got: usize },
    EmptiedItem,
    TooLong,
}

impl fmt::Display for EditProblem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotJson => write!(f, "it was not a JSON object"),
            Self::NoContent => write!(f, "it had no \"content\""),
            Self::Emptied => write!(f, "it left the note empty"),
            Self::NoItems => write!(f, "it had no \"items\" list of strings"),
            Self::ItemCount { expected, got } => write!(
                f,
                "it listed {got} of the {expected} items; return exactly one item for each original item, in order"
            ),
            Self::EmptiedItem => write!(f, "it emptied an item that had text"),
            Self::TooLong => write!(f, "it was longer than {MAX_REWRITE_CHARS} characters"),
        }
    }
}

/// Clean up a note or correct its grammar with the provider of the workspace
/// holding it. The model's response is deliberately constrained to the editable text
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
    if note_chars(&record) > MAX_REWRITE_CHARS {
        return Err(ApiError::BadRequest(
            "this note is too long for AI editing".to_string(),
        ));
    }

    let ai = workspace_ai(&state, &record.workspace_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    let Some(cfg) = ai.config(AiFeature::Writing) else {
        return Err(ApiError::Unavailable("AI note editing is not enabled"));
    };
    let instruction = ai
        .task_prompt(&request.task_id)
        .ok_or_else(|| ApiError::BadRequest("unknown AI rewrite task".to_string()))?;

    let messages = rewrite_messages(&record, instruction, &ai.settings().prompt);
    let edit = tokio::time::timeout(REWRITE_BUDGET, request_edit(&state, cfg, &record, messages))
        .await
        .map_err(|_| ApiError::Upstream("the AI took too long to answer"))??;
    let body = UpdateNote {
        // Someone may have written in the note while the model worked; their
        // words win over a rewrite of what was there before.
        if_unmodified_since: Some(record.updated_at.clone()),
        title: Some(edit.title),
        content: edit.content,
        items: edit.items,
        ..Default::default()
    };
    match apply_note_update(&state, &user_id, &id, body).await {
        Ok(view) => Ok(Json(view)),
        Err(ApiError::Conflict(_)) => Err(ApiError::Conflict(
            "the note changed while the AI was editing it".to_string(),
        )),
        Err(error) => Err(error),
    }
}

/// Asks for the edit, showing the model its own reply and what was wrong with
/// it when that reply cannot be used.
async fn request_edit(
    state: &AppState,
    cfg: &LlmConfig,
    record: &NoteRecord,
    mut messages: Vec<ChatMessage>,
) -> ApiResult<NoteEdit> {
    for attempt in 1..=REWRITE_ATTEMPTS {
        let reply = state
            .llm
            .complete(cfg, messages.clone())
            .await
            .map_err(|error| {
                crate::telemetry::event(
                    "error",
                    "ai_rewrite_provider_failed",
                    serde_json::json!({
                        "request_id": crate::telemetry::current_request_id(),
                        "error": format!("{error:#}"),
                    }),
                );
                ApiError::Upstream("the AI provider did not answer")
            })?;
        let problem = match read_edit(&reply, record) {
            Ok(edit) => return Ok(edit),
            Err(problem) => problem,
        };
        if attempt == REWRITE_ATTEMPTS {
            break;
        }
        messages.push(ChatMessage::assistant(reply));
        messages.push(ChatMessage::user(format!(
            "That reply could not be used: {problem}. Reply again with ONLY the JSON object, in the same shape."
        )));
    }
    Err(ApiError::Upstream(
        "the AI returned an edit that could not be used",
    ))
}

/// The edit in a reply, held to what a rewrite may do: change the words, and
/// never leave text where there was some before.
fn read_edit(reply: &str, record: &NoteRecord) -> Result<NoteEdit, EditProblem> {
    let object = assist::json_object(reply).ok_or(EditProblem::NotJson)?;
    // A model that leaves the title out has nothing to change in it.
    let title = text_field(&object, "title").unwrap_or_else(|| record.title.clone());
    let edit = if record.kind == KIND_CHECKLIST {
        NoteEdit {
            title,
            content: None,
            items: Some(edited_items(&object, record)?),
        }
    } else {
        let content = match text_field(&object, "content") {
            Some(content) => content,
            None if record.content.trim().is_empty() => record.content.clone(),
            None => return Err(EditProblem::NoContent),
        };
        if content.trim().is_empty() && !record.content.trim().is_empty() {
            return Err(EditProblem::Emptied);
        }
        NoteEdit {
            title,
            content: Some(content),
            items: None,
        }
    };
    if edit_chars(&edit) > MAX_REWRITE_CHARS {
        return Err(EditProblem::TooLong);
    }
    Ok(edit)
}

fn text_field(object: &Map<String, Value>, key: &str) -> Option<String> {
    object.get(key)?.as_str().map(str::to_owned)
}

/// The rewritten rows, matched to the originals by position so each keeps its
/// id, tick and nesting. Items may come back as strings or as objects with a
/// "text", which some models echo from the checklist they were shown.
fn edited_items(
    object: &Map<String, Value>,
    record: &NoteRecord,
) -> Result<Vec<ChecklistItem>, EditProblem> {
    let texts: Vec<String> = object
        .get("items")
        .and_then(Value::as_array)
        .and_then(|items| {
            items
                .iter()
                .map(|item| match item {
                    Value::String(text) => Some(text.clone()),
                    Value::Object(row) => text_field(row, "text"),
                    _ => None,
                })
                .collect()
        })
        .ok_or(EditProblem::NoItems)?;
    if texts.len() != record.items.len() {
        return Err(EditProblem::ItemCount {
            expected: record.items.len(),
            got: texts.len(),
        });
    }
    if record
        .items
        .iter()
        .zip(&texts)
        .any(|(item, text)| !item.text.trim().is_empty() && text.trim().is_empty())
    {
        return Err(EditProblem::EmptiedItem);
    }
    Ok(record
        .items
        .iter()
        .zip(texts)
        .map(|(original, text)| ChecklistItem {
            id: original.id.clone(),
            text,
            done: original.done,
            // A rewrite changes wording, never structure.
            depth: original.depth,
        })
        .collect())
}

fn note_chars(record: &NoteRecord) -> usize {
    record.title.chars().count()
        + record.content.chars().count()
        + record
            .items
            .iter()
            .map(|item| item.text.chars().count())
            .sum::<usize>()
}

fn edit_chars(edit: &NoteEdit) -> usize {
    edit.title.chars().count()
        + edit.content.as_deref().map_or(0, |c| c.chars().count())
        + edit
            .items
            .iter()
            .flatten()
            .map(|item| item.text.chars().count())
            .sum::<usize>()
}

fn rewrite_messages(
    record: &NoteRecord,
    instruction: &str,
    custom_prompt: &str,
) -> Vec<ChatMessage> {
    let format_instruction = match record.kind.as_str() {
        KIND_MARKDOWN => {
            "This is a Markdown note: preserve meaningful Markdown syntax and structure."
        }
        KIND_CHECKLIST => {
            "This is a checklist: return the title and every item as plain text only, without Markdown syntax or formatting."
        }
        _ => {
            "This is a plain-text note: return the title and content as plain text only, without Markdown syntax or formatting."
        }
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
        ChatMessage::system(format!(
            "You edit one personal note. {instruction} {format_instruction} {language_instruction} {shape}{}",
            if custom_prompt.trim().is_empty() {
                String::new()
            } else {
                format!(" User's custom AI instructions: {}", custom_prompt.trim())
            }
        )),
        ChatMessage::user(note),
    ]
}
