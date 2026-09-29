//! The tools the MCP endpoint offers. Every read goes through the same
//! participant-scoped repository queries as the app, and every write through
//! the note pipelines the HTTP handlers and chat use, so an AI client sees and
//! changes exactly what its token's owner could, with the same side effects.

use std::collections::{HashMap, HashSet};

use serde_json::{Value, json};

use super::notes::{apply_note_update, create_note_for_user};
use super::{new_id, resolve_workspace, workspaces};
use crate::AppState;
use crate::error::ApiError;
use crate::models::*;
use crate::note_links;

const DEFAULT_SEARCH_RESULTS: usize = 10;
const MAX_SEARCH_RESULTS: usize = 25;
const DEFAULT_LIST_RESULTS: usize = 20;
const MAX_LIST_RESULTS: usize = 100;
/// Search over-fetches vector candidates, since some fall to access checks.
const SEARCH_OVERFETCH: usize = 4;
const SNIPPET_CHARS: usize = 200;
/// Where a note reached through a direct share, in a workspace its reader is
/// not part of, says it lives.
const SHARED_WORKSPACE: &str = "Shared with you";

type Outcome = Result<Value, String>;

/// What a token of `scope` is offered.
pub(super) fn definitions(scope: TokenScope) -> Vec<Value> {
    let read = json!({"readOnlyHint": true});
    let mut tools = vec![
        json!({
            "name": "search_notes",
            "title": "Search notes",
            "description": "Find notes by meaning when the server has semantic search, \
                and by the words in them either way. Returns the best matches first.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "What to look for"},
                    "limit": {"type": "integer", "minimum": 1, "maximum": MAX_SEARCH_RESULTS},
                    "workspace_id": {"type": "string", "description": "Only this workspace"},
                },
                "required": ["query"],
            },
            "annotations": read,
        }),
        json!({
            "name": "list_notes",
            "title": "List notes",
            "description": "Recently edited notes, newest first. Archived and trashed \
                notes are left out unless include_archived is set; trash always is.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "workspace_id": {"type": "string"},
                    "collection_id": {"type": "string"},
                    "label": {"type": "string", "description": "A label name"},
                    "include_archived": {"type": "boolean"},
                    "limit": {"type": "integer", "minimum": 1, "maximum": MAX_LIST_RESULTS},
                },
            },
            "annotations": read,
        }),
        json!({
            "name": "get_note",
            "title": "Read a note",
            "description": "One note in full: its text with links shown as titles, \
                checklist items, labels, where it is filed, and the notes it links \
                to and is linked from.",
            "inputSchema": {
                "type": "object",
                "properties": {"id": {"type": "string"}},
                "required": ["id"],
            },
            "annotations": read,
        }),
        json!({
            "name": "list_workspaces",
            "title": "List workspaces",
            "description": "The workspaces this account belongs to, with their \
                collections and labels.",
            "inputSchema": {"type": "object", "properties": {}},
            "annotations": read,
        }),
    ];
    if scope == TokenScope::Read {
        return tools;
    }

    let write = json!({"readOnlyHint": false, "destructiveHint": false});
    tools.push(json!({
        "name": "create_note",
        "title": "Create a note",
        "description": "Create a note. Give items for a checklist, content for text. \
            To link to another note, write [[note-id|Title]] in the content. Labels \
            are matched by name to the workspace's existing labels.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "content": {"type": "string"},
                "items": {"type": "array", "items": {"type": "string"}},
                "kind": {"type": "string", "enum": [KIND_TEXT, KIND_MARKDOWN, KIND_CHECKLIST]},
                "workspace_id": {"type": "string", "description": "Default: the account's default workspace"},
                "collection_id": {"type": "string"},
                "labels": {"type": "array", "items": {"type": "string"}},
            },
        },
        "annotations": write,
    }));
    tools.push(json!({
        "name": "append_to_note",
        "title": "Add to a note",
        "description": "Add text or checklist items to the end of a note. On a \
            checklist, each line of text becomes an item.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "text": {"type": "string"},
                "items": {"type": "array", "items": {"type": "string"}},
            },
            "required": ["id"],
        },
        "annotations": write,
    }));
    tools
}

/// Run tool `name`. None when there is no such tool; a write tool called with
/// a read token is refused as a tool error, so the model learns why.
pub(super) async fn call(
    state: &AppState,
    user_id: &str,
    scope: TokenScope,
    name: &str,
    args: &Value,
) -> Option<Outcome> {
    let writes = matches!(name, "create_note" | "append_to_note");
    if writes && scope == TokenScope::Read {
        return Some(Err("this token can only read notes".into()));
    }
    let outcome = match name {
        "search_notes" => search_notes(state, user_id, args).await,
        "list_notes" => list_notes(state, user_id, args).await,
        "get_note" => get_note(state, user_id, args).await,
        "list_workspaces" => list_workspaces(state, user_id).await,
        "create_note" => create_note(state, user_id, args).await,
        "append_to_note" => append_to_note(state, user_id, args).await,
        _ => return None,
    };
    Some(outcome)
}

// ---------------------------------------------------------------------------
// Reads

async fn search_notes(state: &AppState, user_id: &str, args: &Value) -> Outcome {
    let query = required(args, "query")?;
    let limit = limit(args, DEFAULT_SEARCH_RESULTS, MAX_SEARCH_RESULTS);
    let workspace = optional(args, "workspace_id");
    let names = Names::load(state, user_id).await?;
    let views: Vec<NoteView> = visible_notes(state, user_id)
        .await?
        .into_iter()
        .filter(|v| workspace.is_none_or(|w| v.note.workspace_id == w))
        .collect();

    // Meaning first, when the server can: the vector index only nominates
    // candidates, and `views` is what this account may actually read.
    let mut hits: Vec<&NoteView> = Vec::new();
    if let Some(search) = &state.search {
        let workspace_ids: Vec<String> = views
            .iter()
            .map(|v| v.note.workspace_id.clone())
            .collect::<HashSet<_>>()
            .into_iter()
            .collect();
        let found = search
            .search(&workspace_ids, query, limit * SEARCH_OVERFETCH)
            .await
            .unwrap_or_default();
        for (id, _) in found {
            if let Some(view) = views.iter().find(|v| v.note.id == id) {
                hits.push(view);
            }
        }
    }

    // Then the words themselves, which also covers a server without search.
    let needle = query.to_lowercase();
    let mut by_recency: Vec<&NoteView> = views.iter().collect();
    by_recency.sort_by(|a, b| b.note.updated_at.cmp(&a.note.updated_at));
    for view in by_recency {
        let matches = view.note.title.to_lowercase().contains(&needle)
            || body_text(view).to_lowercase().contains(&needle);
        if matches && !hits.iter().any(|h| h.note.id == view.note.id) {
            hits.push(view);
        }
    }

    let notes: Vec<Value> = hits
        .into_iter()
        .take(limit)
        .map(|v| summary(v, &names))
        .collect();
    Ok(json!({"notes": notes}))
}

async fn list_notes(state: &AppState, user_id: &str, args: &Value) -> Outcome {
    let limit = limit(args, DEFAULT_LIST_RESULTS, MAX_LIST_RESULTS);
    let workspace = optional(args, "workspace_id");
    let collection = optional(args, "collection_id");
    let include_archived = args.get("include_archived").and_then(Value::as_bool) == Some(true);
    let names = Names::load(state, user_id).await?;
    let label_ids = optional(args, "label").map(|name| names.label_ids_named(name));

    let mut views: Vec<NoteView> = visible_notes(state, user_id)
        .await?
        .into_iter()
        .filter(|v| include_archived || !v.note.archived)
        .filter(|v| workspace.is_none_or(|w| v.note.workspace_id == w))
        .filter(|v| collection.is_none_or(|c| v.note.collection_id.as_deref() == Some(c)))
        .filter(|v| {
            label_ids
                .as_ref()
                .is_none_or(|ids| v.label_ids.iter().any(|id| ids.contains(id)))
        })
        .collect();
    views.sort_by(|a, b| b.note.updated_at.cmp(&a.note.updated_at));

    let notes: Vec<Value> = views
        .iter()
        .take(limit)
        .map(|v| summary(v, &names))
        .collect();
    Ok(json!({"notes": notes}))
}

async fn get_note(state: &AppState, user_id: &str, args: &Value) -> Outcome {
    let id = required(args, "id")?;
    let view = state
        .repo
        .note_view(id, user_id)
        .await
        .map_err(|e| message(e.into()))?
        .ok_or_else(|| message(ApiError::NotFound))?;
    let names = Names::load(state, user_id).await?;
    let others = visible_notes(state, user_id).await?;
    let title_of = |id: &str| {
        others
            .iter()
            .find(|v| v.note.id == id)
            .map(|v| v.note.title.clone())
    };

    let mut seen = HashSet::new();
    let links: Vec<Value> = note_links::find(&view.note.content)
        .into_iter()
        .filter(|link| seen.insert(link.note_id))
        .map(|link| {
            let title = title_of(link.note_id).unwrap_or_else(|| link.title.to_string());
            json!({"id": link.note_id, "title": title})
        })
        .collect();
    let needle = format!("[[{}|", view.note.id);
    let linked_from: Vec<Value> = others
        .iter()
        .filter(|v| v.note.id != view.note.id && v.note.content.contains(&needle))
        .map(|v| json!({"id": v.note.id, "title": v.note.title}))
        .collect();

    let note = &view.note;
    Ok(json!({
        "id": note.id,
        "title": note.title,
        "kind": note.kind,
        "text": body_text(&view),
        "content": note.content,
        "items": note.items.iter().map(|i| json!({
            "text": i.text, "done": i.done, "depth": i.depth,
        })).collect::<Vec<_>>(),
        "labels": names.label_names(&view.label_ids),
        "workspace_id": note.workspace_id,
        "workspace": names.workspace(&note.workspace_id),
        "collection": note.collection_id.as_deref().and_then(|c| names.collections.get(c)),
        "pinned": note.pinned,
        "archived": note.archived,
        "trashed": note.trashed,
        "reminder_at": note.reminder_at,
        "created_at": note.created_at,
        "updated_at": note.updated_at,
        "links": links,
        "linked_from": linked_from,
        "attachments": view.attachments.iter().map(|a| json!({
            "filename": a.filename, "mime": a.mime,
        })).collect::<Vec<_>>(),
    }))
}

async fn list_workspaces(state: &AppState, user_id: &str) -> Outcome {
    let workspaces = workspaces::ensure_workspaces(state, user_id)
        .await
        .map_err(message)?;
    let labels = state
        .repo
        .labels_for_user(user_id)
        .await
        .map_err(|e| message(e.into()))?;
    let out: Vec<Value> = workspaces
        .iter()
        .map(|w| {
            json!({
                "id": w.id,
                "name": w.name,
                "is_default": w.is_default,
                "collections": w.collections.iter().map(|c| json!({
                    "id": c.id, "name": c.name,
                })).collect::<Vec<_>>(),
                "labels": labels.iter()
                    .filter(|l| l.workspace_id == w.id)
                    .map(|l| l.name.clone())
                    .collect::<Vec<_>>(),
            })
        })
        .collect();
    Ok(json!({"workspaces": out}))
}

// ---------------------------------------------------------------------------
// Writes

async fn create_note(state: &AppState, user_id: &str, args: &Value) -> Outcome {
    let title = optional(args, "title").unwrap_or_default().to_string();
    let content = optional(args, "content").unwrap_or_default().to_string();
    let items = strings(args, "items");
    if title.trim().is_empty() && content.trim().is_empty() && items.is_empty() {
        return Err("give the note a title, content or items".into());
    }
    let kind = match optional(args, "kind") {
        Some(kind @ (KIND_TEXT | KIND_MARKDOWN | KIND_CHECKLIST)) => kind,
        Some(other) => {
            return Err(format!(
                "kind must be text, markdown or checklist, not {other}"
            ));
        }
        None if !items.is_empty() && content.is_empty() => KIND_CHECKLIST,
        None => KIND_TEXT,
    };

    let workspace_id = resolve_workspace(state, user_id, optional(args, "workspace_id"))
        .await
        .map_err(message)?;
    let (label_ids, unknown_labels) =
        labels_named(state, user_id, &workspace_id, &strings(args, "labels")).await?;
    let (content, items) = if kind == KIND_CHECKLIST {
        (content, items.iter().map(|text| item(text)).collect())
    } else {
        // Prose cannot show checklist rows, so any items join the text.
        (append_lines(&content, &items), Vec::new())
    };

    let body = CreateNote {
        kind: Some(kind.to_string()),
        title,
        content,
        items: (!items.is_empty()).then_some(items),
        workspace_id: Some(workspace_id),
        collection_id: optional(args, "collection_id").map(str::to_string),
        label_ids: (!label_ids.is_empty()).then_some(label_ids),
        ..Default::default()
    };
    let view = create_note_for_user(state, user_id, body)
        .await
        .map_err(message)?;
    Ok(json!({
        "id": view.note.id,
        "title": view.note.title,
        "kind": view.note.kind,
        "workspace_id": view.note.workspace_id,
        "unknown_labels": unknown_labels,
    }))
}

async fn append_to_note(state: &AppState, user_id: &str, args: &Value) -> Outcome {
    let id = required(args, "id")?;
    let text = optional(args, "text").unwrap_or_default();
    let items = strings(args, "items");
    if text.trim().is_empty() && items.is_empty() {
        return Err("give text or items to add".into());
    }
    let record = state
        .repo
        .note_record_for_user(id, user_id)
        .await
        .map_err(|e| message(e.into()))?
        .ok_or_else(|| message(ApiError::NotFound))?;
    if record.trashed {
        return Err("that note is in the trash".into());
    }

    let mut body = UpdateNote::default();
    if record.kind == KIND_CHECKLIST {
        let mut merged = record.items.clone();
        let lines = text.lines().filter(|line| !line.trim().is_empty());
        merged.extend(lines.chain(items.iter().map(String::as_str)).map(item));
        body.items = Some(merged);
    } else {
        let mut added = text.to_string();
        added = append_lines(&added, &items);
        body.content = Some(append_lines(&record.content, &[added]));
    }
    let view = apply_note_update(state, user_id, id, body)
        .await
        .map_err(message)?;
    Ok(json!({"id": view.note.id, "title": view.note.title}))
}

// ---------------------------------------------------------------------------
// Helpers

/// Names for the ids a note carries, loaded once per call.
struct Names {
    workspaces: HashMap<String, String>,
    collections: HashMap<String, String>,
    labels: Vec<Label>,
}

impl Names {
    async fn load(state: &AppState, user_id: &str) -> Result<Self, String> {
        let workspaces = state
            .repo
            .workspaces_for_user(user_id)
            .await
            .map_err(|e| message(e.into()))?;
        let labels = state
            .repo
            .labels_for_user(user_id)
            .await
            .map_err(|e| message(e.into()))?;
        Ok(Names {
            collections: workspaces
                .iter()
                .flat_map(|w| &w.collections)
                .map(|c| (c.id.clone(), c.name.clone()))
                .collect(),
            workspaces: workspaces.into_iter().map(|w| (w.id, w.name)).collect(),
            labels,
        })
    }

    fn workspace(&self, id: &str) -> &str {
        self.workspaces
            .get(id)
            .map_or(SHARED_WORKSPACE, String::as_str)
    }

    fn label_names(&self, ids: &[String]) -> Vec<String> {
        self.labels
            .iter()
            .filter(|l| ids.contains(&l.id))
            .map(|l| l.name.clone())
            .collect()
    }

    fn label_ids_named(&self, name: &str) -> HashSet<String> {
        self.labels
            .iter()
            .filter(|l| l.name.eq_ignore_ascii_case(name.trim()))
            .map(|l| l.id.clone())
            .collect()
    }
}

/// Everything the account can read, less the trash.
async fn visible_notes(state: &AppState, user_id: &str) -> Result<Vec<NoteView>, String> {
    Ok(state
        .repo
        .notes_for_user(user_id)
        .await
        .map_err(|e| message(e.into()))?
        .into_iter()
        .filter(|v| !v.note.trashed)
        .collect())
}

/// A note's body as a reader sees it: links as titles, a checklist as rows.
fn body_text(view: &NoteView) -> String {
    let note = &view.note;
    if note.kind != KIND_CHECKLIST {
        return note_links::plain_text(&note.content);
    }
    note.items
        .iter()
        .map(|i| {
            let mark = if i.done { "x" } else { " " };
            format!("{}[{mark}] {}", "  ".repeat(i.depth as usize), i.text)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn summary(view: &NoteView, names: &Names) -> Value {
    let snippet: String = body_text(view).chars().take(SNIPPET_CHARS).collect();
    json!({
        "id": view.note.id,
        "title": view.note.title,
        "kind": view.note.kind,
        "snippet": snippet,
        "workspace": names.workspace(&view.note.workspace_id),
        "labels": names.label_names(&view.label_ids),
        "pinned": view.note.pinned,
        "archived": view.note.archived,
        "updated_at": view.note.updated_at,
    })
}

/// The ids of the workspace's labels named in `wanted`, and the names it has
/// no label for. Labels are never created here: the taxonomy is the members'.
async fn labels_named(
    state: &AppState,
    user_id: &str,
    workspace_id: &str,
    wanted: &[String],
) -> Result<(Vec<String>, Vec<String>), String> {
    let labels = state
        .repo
        .labels_for_user(user_id)
        .await
        .map_err(|e| message(e.into()))?;
    let mut ids = Vec::new();
    let mut unknown = Vec::new();
    for name in wanted {
        let found = labels
            .iter()
            .find(|l| l.workspace_id == workspace_id && l.name.eq_ignore_ascii_case(name.trim()));
        match found {
            Some(label) => ids.push(label.id.clone()),
            None => unknown.push(name.clone()),
        }
    }
    Ok((ids, unknown))
}

fn item(text: &str) -> ChecklistItem {
    ChecklistItem {
        id: new_id(),
        text: text.to_string(),
        done: false,
        depth: 0,
    }
}

/// `base` with each non-empty line of `lines` after it, one per line.
fn append_lines(base: &str, lines: &[String]) -> String {
    let mut out = base.to_string();
    for line in lines.iter().filter(|l| !l.trim().is_empty()) {
        if !out.is_empty() {
            out.push('\n');
        }
        out.push_str(line);
    }
    out
}

fn optional<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args.get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

fn required<'a>(args: &'a Value, key: &str) -> Result<&'a str, String> {
    optional(args, key).ok_or_else(|| format!("{key} is required"))
}

fn strings(args: &Value, key: &str) -> Vec<String> {
    args.get(key)
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn limit(args: &Value, default: usize, max: usize) -> usize {
    args.get("limit")
        .and_then(Value::as_u64)
        .map_or(default, |n| n as usize)
        .clamp(1, max)
}

/// What a model is told when the server refuses. Internals are logged as an
/// HTTP request's are, and kept from the model.
fn message(error: ApiError) -> String {
    match error {
        ApiError::NotFound => "not found".into(),
        ApiError::BadRequest(m) | ApiError::Conflict(m) => m,
        ApiError::Forbidden(m) | ApiError::Unavailable(m) => m.into(),
        ApiError::Internal(e) => {
            crate::telemetry::event(
                "error",
                "mcp_tool_internal_error",
                json!({
                    "request_id": crate::telemetry::current_request_id(),
                    "error": format!("{e:#}"),
                }),
            );
            "the server could not complete this".into()
        }
        ApiError::Unauthorized | ApiError::RateLimited(_) => {
            "the server could not complete this".into()
        }
    }
}
