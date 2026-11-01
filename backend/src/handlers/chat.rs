//! Notes chat over a WebSocket: route the turn, retrieve context, then either
//! answer over the notes or apply a create/append write the model planned.

use std::borrow::Cow;
use std::collections::HashSet;
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket};
use axum::extract::{Query, State, WebSocketUpgrade};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use futures::stream::{SplitSink, SplitStream};
use futures::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::OwnedSemaphorePermit;

use crate::AppState;
use crate::assist::{self, PromptNote, RouteDecision, WriteAction, WritePermissions};
use crate::error::ApiResult;
use crate::llm::{LlmConfig, TokenStream};
use crate::models::*;
use crate::search::SearchService;

use super::workspace_ai::{AiFeature, WorkspaceAi, workspace_ai};
use super::{apply_note_update, create_note_for_user, new_id};

/// One chat turn from the client.
#[derive(Deserialize)]
struct ChatRequest {
    /// Sent inside the encrypted WebSocket stream so reverse-proxy request
    /// logs never receive the bearer token.
    #[serde(default)]
    token: Option<String>,
    message: String,
    #[serde(default)]
    history: Vec<ChatHistoryEntry>,
    /// The workspace the client has open. Retrieval is limited to it and any
    /// note the turn writes lands in it, so chat answers over what the user is
    /// actually looking at. Absent means every note they can see.
    #[serde(default)]
    workspace_id: Option<String>,
}

/// Who a turn is being answered for: the asker, the provider they configured,
/// and the workspace their client has open.
struct TurnContext<'a> {
    user_id: &'a str,
    cfg: &'a LlmConfig,
    workspace_id: Option<&'a str>,
    prompt: &'a str,
    permissions: WritePermissions,
}

#[derive(Deserialize)]
struct ChatHistoryEntry {
    role: String,
    content: String,
}

/// Notes chat over a WebSocket (a streaming response has to reach Flutter
/// web, whose HTTP client can't stream bodies). Authentication and the turn
/// arrive together in the first frame; one request is handled per connection:
///
/// ```text
/// client → server:  {"token":"…","message":"…","history":[{"role","content"},…]}
/// server → client:  {"type":"sources","notes":[{"id","title"}, …]}
///                   {"type":"created","action":"create"|"append"|"update","note":{"id","title"}}
///                                                (0..1, only when the turn
///                                                 created or appended a note)
///                   {"type":"delta","text":"…"}   (0..n)
///                   {"type":"done"} | {"type":"error","message":"…"}
/// ```
pub async fn chat_ws(
    State(state): State<AppState>,
    Query(params): Query<super::events::LegacyWsParams>,
    upgrade: WebSocketUpgrade,
) -> Response {
    if let Some(token) = params.token.filter(|token| !token.is_empty()) {
        return match state.repo.user_id_for_token(&token).await {
            Ok(Some(user_id)) => upgrade
                .max_message_size(MAX_FRAME_BYTES)
                .max_frame_size(MAX_FRAME_BYTES)
                .on_upgrade(move |socket| chat_loop(socket, state, Some(user_id), None)),
            Ok(None) => StatusCode::UNAUTHORIZED.into_response(),
            Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        };
    }
    let Some(auth_permit) = crate::ws::pending_auth_permit() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    upgrade
        .max_message_size(MAX_FRAME_BYTES)
        .max_frame_size(MAX_FRAME_BYTES)
        .on_upgrade(move |socket| chat_loop(socket, state, None, Some(auth_permit)))
}

/// Largest frame a chat socket accepts; a turn's whole history rides in one.
const MAX_FRAME_BYTES: usize = 256 * 1024;
/// How long a client has to send its turn once connected.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);
/// How long the routing and write-planning calls may take before the turn
/// falls back to plain retrieval, or to answering instead of writing.
const PLANNING_TIMEOUT: Duration = Duration::from_secs(10);
/// How long the answer may stall between two tokens.
const TOKEN_TIMEOUT: Duration = Duration::from_secs(120);
/// Index hits fetched per note the prompt keeps. Trashed notes linger in the
/// index, and a workspace filter drops the other workspaces' hits on top.
const OVERFETCH_SCOPED: usize = 8;
const OVERFETCH_UNSCOPED: usize = 2;

/// What the server sends during a turn, in the order [`chat_ws`] documents.
#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ChatFrame<'a> {
    Sources {
        notes: Vec<NoteRef<'a>>,
    },
    Created {
        action: &'static str,
        note: NoteRef<'a>,
        undo: &'a serde_json::Value,
    },
    Delta {
        text: &'a str,
    },
    Done,
    Error {
        message: &'a str,
    },
}

#[derive(Serialize)]
struct NoteRef<'a> {
    id: &'a str,
    title: &'a str,
}

type ChatSink = SplitSink<WebSocket, Message>;
type ChatStream = SplitStream<WebSocket>;

/// Why a turn ended early, worded for the client.
type TurnError = Cow<'static, str>;

/// Sends one frame. False once the client has gone.
async fn send(sink: &mut ChatSink, frame: ChatFrame<'_>) -> bool {
    let Ok(text) = serde_json::to_string(&frame) else {
        return false;
    };
    sink.send(Message::text(text)).await.is_ok()
}

async fn chat_loop(
    socket: WebSocket,
    state: AppState,
    authenticated_user: Option<String>,
    auth_permit: Option<OwnedSemaphorePermit>,
) {
    let (mut sink, mut stream) = socket.split();
    // Every failure ends the turn the same way: one error frame, best effort,
    // then the connection closes.
    let turn = run_turn(
        &mut sink,
        &mut stream,
        &state,
        authenticated_user,
        auth_permit,
    );
    if let Err(message) = turn.await {
        send(&mut sink, ChatFrame::Error { message: &message }).await;
    }
}

/// One turn, start to finish. An `Err` is what the client is told.
async fn run_turn(
    sink: &mut ChatSink,
    stream: &mut ChatStream,
    state: &AppState,
    authenticated_user: Option<String>,
    auth_permit: Option<OwnedSemaphorePermit>,
) -> Result<(), TurnError> {
    let request = read_request(stream).await?;
    let user_id = authenticate(state, &request, authenticated_user, auth_permit).await?;
    let message = request.message.trim();
    if message.is_empty() {
        return Err("empty message".into());
    }

    // Preconditions: retrieval needs the server-side embedder.
    let Some(search) = state.search.clone() else {
        return Err("chat needs semantic search enabled on this server".into());
    };

    let history: Vec<(String, String)> = request
        .history
        .into_iter()
        .map(|h| (h.role, h.content))
        .collect();

    // Scope the turn to the open workspace and therefore its vector
    // collection, and answer it with that workspace's AI. An unscoped turn
    // runs on the caller's default workspace and searches each workspace
    // represented in their visible notes that has chat on.
    let workspace_id = request
        .workspace_id
        .as_deref()
        .map(str::trim)
        .filter(|w| !w.is_empty())
        .map(str::to_owned);
    let ai = chat_ai(state, &user_id, workspace_id.as_deref()).await?;
    let Some(cfg) = ai.config(AiFeature::Chat) else {
        return Err("chat is off in this workspace, or its owner has no AI provider".into());
    };
    let llm_settings = ai.settings();
    let scope = turn_scope(state, &user_id, workspace_id.as_deref()).await?;

    let decision = route(state, cfg, &history, message, &llm_settings.prompt).await;

    // Phase 2, retrieve when the turn needs notes. A Search reads them to
    // answer; a Write reads them as candidates to add to.
    let notes = match &decision {
        RouteDecision::Search(query) | RouteDecision::Write(query) => {
            retrieve(state, &search, &scope, &user_id, query).await?
        }
        RouteDecision::Direct => Vec::new(),
    };

    // Phase 2b, write: turn a create/append request into one structured edit
    // and apply it, streaming a confirmation. A failed or unusable plan falls
    // through to answering over the retrieved notes, so a weak model can never
    // silently drop the turn (or, worse, touch a note it shouldn't).
    if matches!(decision, RouteDecision::Write(_)) {
        let turn = TurnContext {
            user_id: &user_id,
            cfg,
            workspace_id: workspace_id.as_deref(),
            prompt: &llm_settings.prompt,
            permissions: WritePermissions {
                create: llm_settings.chat_create,
                edit: llm_settings.chat_edit,
                organize: llm_settings.chat_organize,
            },
        };
        if let Some(applied) = write_from_plan(state, &turn, &notes, &history, message).await? {
            confirm_write(sink, &applied).await;
            return Ok(());
        }
    }

    let sources = notes
        .iter()
        .map(|note| NoteRef {
            id: &note.id,
            title: &note.title,
        })
        .collect();
    if !send(sink, ChatFrame::Sources { notes: sources }).await {
        return Ok(());
    }

    let messages = match &decision {
        // Write reaches here only when its plan was unusable: answer over the
        // retrieved notes like an ordinary read turn rather than writing.
        RouteDecision::Search(_) | RouteDecision::Write(_) => {
            assist::chat_messages(&notes, &history, message, &llm_settings.prompt)
        }
        RouteDecision::Direct => {
            assist::chat_messages_direct(&history, message, &llm_settings.prompt)
        }
    };
    let tokens = state
        .llm
        .stream(cfg, messages)
        .await
        .map_err(|e| TurnError::Owned(format!("{e:#}")))?;
    stream_answer(sink, stream, tokens).await
}

/// The first (and only) request frame, ignoring pings.
async fn read_request(stream: &mut ChatStream) -> Result<ChatRequest, TurnError> {
    let first_text = tokio::time::timeout(REQUEST_TIMEOUT, async {
        while let Some(Ok(msg)) = stream.next().await {
            if let Message::Text(text) = msg {
                return Some(text);
            }
        }
        None
    })
    .await;
    let Ok(Some(text)) = first_text else {
        return Err("expected a chat request".into());
    };
    serde_json::from_str(&text).map_err(|_| TurnError::from("malformed chat request"))
}

/// The caller: already known from a query-string token, or read from the
/// token in the first frame. A socket that authenticates that way gives back
/// its pending-auth slot as soon as the token checks out.
async fn authenticate(
    state: &AppState,
    request: &ChatRequest,
    authenticated_user: Option<String>,
    auth_permit: Option<OwnedSemaphorePermit>,
) -> Result<String, TurnError> {
    const UNAUTHORIZED: &str = "unauthorized";
    if let Some(user_id) = authenticated_user {
        return Ok(user_id);
    }
    let token = request
        .token
        .as_deref()
        .filter(|token| !token.is_empty())
        .ok_or(UNAUTHORIZED)?;
    let Ok(Some(user_id)) = state.repo.user_id_for_token(token).await else {
        return Err(UNAUTHORIZED.into());
    };
    drop(auth_permit);
    Ok(user_id)
}

/// Which notes a turn may read.
struct Scope {
    /// The open workspace's notes; `None` for an unscoped turn.
    allowed_notes: Option<HashSet<String>>,
    /// The vector collections to search.
    workspaces: Vec<String>,
}

async fn turn_scope(
    state: &AppState,
    user_id: &str,
    workspace_id: Option<&str>,
) -> Result<Scope, TurnError> {
    let Some(id) = workspace_id else {
        let workspaces = chat_workspaces(state, user_id)
            .await
            .map_err(|_| "could not load workspaces")?;
        return Ok(Scope {
            allowed_notes: None,
            workspaces,
        });
    };
    let notes = super::workspace_note_ids(state, user_id, id)
        .await
        .map_err(|_| "that workspace is not available")?;
    Ok(Scope {
        allowed_notes: Some(notes),
        workspaces: vec![id.to_string()],
    })
}

/// Phase 1, route: the model decides whether this turn needs notes at all
/// and, if so, writes the search query itself (resolving references from the
/// conversation, so "and the plants?" looks up plants and a bare "thanks"
/// looks up nothing). A failed or unparseable routing call falls back to
/// plain retrieval on a blend of recent user turns, a weak model can't make
/// chat worse than ordinary RAG, only better.
async fn route(
    state: &AppState,
    cfg: &LlmConfig,
    history: &[(String, String)],
    message: &str,
    prompt: &str,
) -> RouteDecision {
    let routing = state
        .llm
        .complete(cfg, assist::route_messages(history, message, prompt));
    match tokio::time::timeout(PLANNING_TIMEOUT, routing).await {
        Ok(Ok(reply)) => assist::parse_route_reply(&reply),
        _ => None,
    }
    .unwrap_or_else(|| RouteDecision::Search(assist::retrieval_query(history, message)))
}

/// The best notes for `query` that the caller can still read, rendered for
/// the prompt. Over-fetches because the index holds more than they may see.
async fn retrieve(
    state: &AppState,
    search: &SearchService,
    scope: &Scope,
    user_id: &str,
    query: &str,
) -> Result<Vec<PromptNote>, TurnError> {
    let overfetch = if scope.allowed_notes.is_some() {
        OVERFETCH_SCOPED
    } else {
        OVERFETCH_UNSCOPED
    };
    let hits = search
        .search(
            &scope.workspaces,
            query,
            assist::CHAT_CONTEXT_NOTES * overfetch,
        )
        .await
        .map_err(|e| {
            state.report_background_failure("chat_retrieval", &e);
            "search failed"
        })?;

    let mut notes = Vec::new();
    for (note_id, _score) in hits {
        if notes.len() >= assist::CHAT_CONTEXT_NOTES {
            break;
        }
        if scope
            .allowed_notes
            .as_ref()
            .is_some_and(|ids| !ids.contains(&note_id))
        {
            continue;
        }
        // Index ACL rows are eventually consistent. Re-check the primary
        // repository before reading any note text into an LLM prompt.
        let Ok(Some(record)) = state.repo.note_record_for_user(&note_id, user_id).await else {
            continue;
        };
        if record.trashed {
            continue;
        }
        // Prompt rendering, not the embedding text: checklists keep their
        // per-item checked state here.
        let text = format!(
            "kind={}, pinned={}, archived={}, color={}, reminder_at={}\n{}",
            record.kind,
            record.pinned,
            record.archived,
            record.color,
            record.reminder_at.as_deref().unwrap_or("none"),
            assist::note_prompt_text(&record),
        );
        notes.push(PromptNote {
            id: record.id,
            title: record.title,
            text,
        });
    }
    Ok(notes)
}

/// Forwards deltas until the stream ends, errors, stalls, or the client
/// leaves. Dropping `tokens` aborts the underlying HTTP request.
async fn stream_answer(
    sink: &mut ChatSink,
    stream: &mut ChatStream,
    mut tokens: TokenStream,
) -> Result<(), TurnError> {
    loop {
        tokio::select! {
            token = tokio::time::timeout(TOKEN_TIMEOUT, tokens.next()) => match token {
                Err(_) => return Err("the model stopped responding".into()),
                Ok(None) => {
                    send(sink, ChatFrame::Done).await;
                    return Ok(());
                }
                Ok(Some(Ok(text))) => {
                    if !send(sink, ChatFrame::Delta { text: &text }).await {
                        return Ok(()); // client gone
                    }
                }
                Ok(Some(Err(e))) => return Err(format!("{e:#}").into()),
            },
            incoming = stream.next() => match incoming {
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => return Ok(()),
                _ => {} // ignore pings/client chatter
            },
        }
    }
}

/// The AI a turn runs on: the open workspace's, which the caller must belong
/// to, or their default workspace's.
async fn chat_ai(
    state: &AppState,
    user_id: &str,
    workspace_id: Option<&str>,
) -> Result<WorkspaceAi, &'static str> {
    const UNAVAILABLE: &str = "that workspace is not available";
    let id = match workspace_id {
        Some(id) => {
            if !state
                .repo
                .is_workspace_member(id, user_id)
                .await
                .unwrap_or(false)
            {
                return Err(UNAVAILABLE);
            }
            id.to_string()
        }
        None => super::resolve_workspace(state, user_id, None)
            .await
            .map_err(|_| UNAVAILABLE)?,
    };
    match workspace_ai(state, &id).await {
        Ok(Some(ai)) => Ok(ai),
        _ => Err(UNAVAILABLE),
    }
}

/// Every workspace an unscoped turn may read: those holding a note the caller
/// can see, less the ones whose owner turned chat off.
async fn chat_workspaces(state: &AppState, user_id: &str) -> ApiResult<Vec<String>> {
    let ids = state.repo.visible_note_workspaces(user_id).await?;
    let mut open = Vec::new();
    for id in ids {
        if let Some(ai) = workspace_ai(state, &id).await?
            && ai.allows(AiFeature::Chat)
        {
            open.push(id);
        }
    }
    Ok(open)
}

/// A write a turn applied: which kind, the note as it now stands, the sentence
/// that confirms it, and the patch that would undo it.
struct AppliedWrite {
    action: &'static str,
    view: NoteView,
    confirmation: String,
    undo: serde_json::Value,
}

/// The chat write path: ask the model to turn the user's create/append request
/// into one structured edit ([`assist::write_plan_messages`]) and apply it
/// through the shared create/update pipeline, so it gets indexing,
/// auto-labeling, version history, and the WS refresh nudge.
///
/// `Ok(None)` means the plan was unusable (timeout, unparseable, or a
/// hallucinated target) and the caller should answer over the retrieved notes
/// instead of writing something the user didn't ask for. An `Err` is a write
/// that was planned and failed.
async fn write_from_plan(
    state: &AppState,
    turn: &TurnContext<'_>,
    candidates: &[PromptNote],
    history: &[(String, String)],
    message: &str,
) -> Result<Option<AppliedWrite>, TurnError> {
    let planner =
        assist::write_plan_messages(candidates, history, message, turn.permissions, turn.prompt);
    let planning = state.llm.complete(turn.cfg, planner);
    let Ok(Ok(reply)) = tokio::time::timeout(PLANNING_TIMEOUT, planning).await else {
        return Ok(None);
    };
    let candidate_ids: Vec<String> = candidates.iter().map(|note| note.id.clone()).collect();
    let Some(action) = assist::parse_write_action(&reply, &candidate_ids, turn.permissions) else {
        return Ok(None);
    };

    match action {
        WriteAction::Create {
            kind,
            title,
            content,
            items,
        } => create_from_plan(state, turn, kind, title, content, items)
            .await
            .map(Some),
        WriteAction::Append {
            note_id,
            content,
            items,
        } => append_from_plan(state, turn, &note_id, content, items).await,
        WriteAction::Update {
            note_id,
            title,
            content,
            items,
            color,
            pinned,
            archived,
            trashed,
            reminder_at,
            reminder_repeat,
        } => {
            let patch = UpdateNote {
                title,
                content,
                color,
                pinned,
                archived,
                trashed,
                reminder_at,
                reminder_repeat,
                ..Default::default()
            };
            update_from_plan(state, turn, &note_id, items, patch).await
        }
    }
}

async fn create_from_plan(
    state: &AppState,
    turn: &TurnContext<'_>,
    kind: String,
    title: String,
    content: String,
    items: Vec<String>,
) -> Result<AppliedWrite, TurnError> {
    let is_checklist = kind == KIND_CHECKLIST;
    let (content, item_structs) = if is_checklist {
        let structs: Vec<ChecklistItem> = items
            .iter()
            .map(|text| ChecklistItem {
                id: new_id(),
                text: text.clone(),
                done: false,
                // The assistant writes a flat list; nesting is the reader's
                // to add.
                depth: 0,
            })
            .collect();
        (content, structs)
    } else {
        // A text note can't render checklist rows, so fold any items the
        // model produced into the body, nothing is lost.
        let mut body = content;
        for item in &items {
            if !body.is_empty() {
                body.push('\n');
            }
            body.push_str(item);
        }
        (body, Vec::new())
    };
    let n = item_structs.len();
    let body = CreateNote {
        kind: Some(kind),
        title,
        content,
        items: (!item_structs.is_empty()).then_some(item_structs),
        // The note belongs where the user is looking; absent, the create
        // pipeline falls back to their default workspace.
        workspace_id: turn.workspace_id.map(str::to_owned),
        ..Default::default()
    };
    let view = create_note_for_user(state, turn.user_id, body)
        .await
        .map_err(|_| "could not create the note")?;
    let confirmation = if is_checklist {
        format!(
            "Created a checklist{} with {n} item{}.",
            titled(&view.note.title),
            plural(n)
        )
    } else {
        format!("Created a note{}.", titled(&view.note.title))
    };
    let undo = if view.owner.id == turn.user_id {
        serde_json::json!({"trashed": true, "pinned": false})
    } else {
        // Workspace members may create and archive notes, but only the
        // workspace owner controls trash.
        serde_json::json!({"archived": true, "pinned": false})
    };
    Ok(AppliedWrite {
        action: "create",
        view,
        confirmation,
        undo,
    })
}

/// `None` when the note vanished since retrieval, or the plan adds nothing.
async fn append_from_plan(
    state: &AppState,
    turn: &TurnContext<'_>,
    note_id: &str,
    content: String,
    items: Vec<String>,
) -> Result<Option<AppliedWrite>, TurnError> {
    let Ok(Some(record)) = state.repo.note_record_for_user(note_id, turn.user_id).await else {
        return Ok(None);
    };
    let is_checklist = record.kind == KIND_CHECKLIST;
    let mut body = UpdateNote::default();
    let mut added = 0usize;
    if is_checklist && !items.is_empty() {
        let mut merged = record.items.clone();
        for text in &items {
            merged.push(ChecklistItem {
                id: new_id(),
                text: text.clone(),
                done: false,
                depth: 0,
            });
        }
        added = items.len();
        body.items = Some(merged);
    }

    // New prose (and, on a text note, any items) append to the body.
    let mut extra = content;
    if !is_checklist {
        for text in &items {
            if !extra.is_empty() {
                extra.push('\n');
            }
            extra.push_str(text);
            added += 1;
        }
    }
    if !extra.trim().is_empty() {
        let mut merged = record.content.clone();
        if !merged.is_empty() {
            merged.push('\n');
        }
        merged.push_str(&extra);
        body.content = Some(merged);
    }
    if body.items.is_none() && body.content.is_none() {
        return Ok(None);
    }

    let undo = serde_json::json!({
        "kind": record.kind,
        "title": record.title,
        "content": record.content,
        "items": record.items,
    });
    let view = apply_note_update(state, turn.user_id, note_id, body)
        .await
        .map_err(|_| "could not update the note")?;
    let confirmation = if added > 0 {
        format!(
            "Added {added} item{} to{}.",
            plural(added),
            titled(&view.note.title)
        )
    } else {
        format!("Updated{}.", titled(&view.note.title))
    };
    Ok(Some(AppliedWrite {
        action: "append",
        view,
        confirmation,
        undo,
    }))
}

/// `None` when the note vanished since retrieval.
async fn update_from_plan(
    state: &AppState,
    turn: &TurnContext<'_>,
    note_id: &str,
    items: Option<Vec<String>>,
    mut patch: UpdateNote,
) -> Result<Option<AppliedWrite>, TurnError> {
    let Ok(Some(record)) = state.repo.note_record_for_user(note_id, turn.user_id).await else {
        return Ok(None);
    };
    // Rows keep their ids, ticks and nesting by position, so a rewrite of the
    // list reads as an edit rather than a new list.
    patch.items = items.map(|texts| {
        texts
            .into_iter()
            .enumerate()
            .map(|(index, text)| match record.items.get(index) {
                Some(item) => ChecklistItem {
                    id: item.id.clone(),
                    text,
                    done: item.done,
                    depth: item.depth,
                },
                None => ChecklistItem {
                    id: new_id(),
                    text,
                    done: false,
                    depth: 0,
                },
            })
            .collect()
    });
    let undo = serde_json::json!({
        "title": record.title,
        "content": record.content,
        "items": record.items,
        "color": record.color,
        "pinned": record.pinned,
        "archived": record.archived,
        "trashed": record.trashed,
        "reminder_at": record.reminder_at,
        "reminder_repeat": record.reminder_repeat,
    });
    let view = apply_note_update(state, turn.user_id, note_id, patch)
        .await
        .map_err(|_| "could not update the note")?;
    Ok(Some(AppliedWrite {
        action: "update",
        view,
        confirmation: "Updated the note.".to_string(),
        undo,
    }))
}

/// A `created` frame carries the note so the client can offer a chip that
/// opens it; the confirmation streams as ordinary delta text. Unknown frame
/// types are ignored by older clients, so this is backwards-compatible. A
/// client that leaves part way still had its turn handled.
async fn confirm_write(sink: &mut ChatSink, applied: &AppliedWrite) {
    let created = ChatFrame::Created {
        action: applied.action,
        note: NoteRef {
            id: &applied.view.note.id,
            title: &applied.view.note.title,
        },
        undo: &applied.undo,
    };
    if !send(sink, created).await {
        return;
    }
    let delta = ChatFrame::Delta {
        text: &applied.confirmation,
    };
    if !send(sink, delta).await {
        return;
    }
    send(sink, ChatFrame::Done).await;
}

/// " \"Groceries\"" or "" for a blank title, folded into a sentence.
fn titled(title: &str) -> String {
    let t = title.trim();
    if t.is_empty() {
        String::new()
    } else {
        format!(" \"{t}\"")
    }
}

fn plural(n: usize) -> &'static str {
    if n == 1 { "" } else { "s" }
}
