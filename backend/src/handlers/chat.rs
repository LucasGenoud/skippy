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
use crate::llm::{ChatMessage, LlmConfig, TokenStream};
use crate::models::*;
use crate::search::SearchService;

use super::workspace_ai::{AiFeature, WorkspaceAi, workspace_ai};
use super::{apply_note_update, create_note_for_user, new_id};

mod writes;

use writes::{confirm_write, write_from_plan};

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
    /// The collection open inside that workspace. New notes are filed there
    /// and the prompts name it; ignored unless it belongs to the workspace.
    #[serde(default)]
    collection_id: Option<String>,
    /// The user switched writes off for this turn: a change request is
    /// answered, never planned.
    #[serde(default)]
    read_only: bool,
}

/// Who a turn is being answered for: the asker, the provider they configured,
/// and the workspace their client has open.
struct TurnContext<'a> {
    user_id: &'a str,
    cfg: &'a LlmConfig,
    workspace_id: Option<&'a str>,
    collection_id: Option<&'a str>,
    taxonomy: &'a Taxonomy,
    prompt: &'a str,
    permissions: WritePermissions,
}

/// The collections and labels the caller can see, loaded once per turn so
/// prompts can name them and plans can map names back to ids.
struct Taxonomy {
    collections: Vec<Collection>,
    labels: Vec<Label>,
}

impl Taxonomy {
    async fn load(state: &AppState, user_id: &str) -> Result<Self, TurnError> {
        const FAILED: &str = "could not load collections and labels";
        let collections = state.repo.collections_for_user(user_id).await;
        let labels = state.repo.labels_for_user(user_id).await;
        Ok(Self {
            collections: collections.map_err(|_| FAILED)?,
            labels: labels.map_err(|_| FAILED)?,
        })
    }

    /// The workspace's collection named or identified by `wanted`.
    fn collection_id(&self, workspace_id: &str, wanted: &str) -> Option<String> {
        let wanted = wanted.trim();
        self.collections
            .iter()
            .filter(|c| c.workspace_id == workspace_id)
            .find(|c| c.id == wanted || c.name.eq_ignore_ascii_case(wanted))
            .map(|c| c.id.clone())
    }

    fn collection_name(&self, id: Option<&str>) -> &str {
        self.collections
            .iter()
            .find(|c| Some(c.id.as_str()) == id)
            .map_or("none", |c| c.name.as_str())
    }

    /// Ids of the workspace's labels in `names`; names it lacks are dropped,
    /// since the taxonomy is the members' to grow, not the model's.
    fn label_ids(&self, workspace_id: &str, names: &[String]) -> Vec<String> {
        let mut ids = Vec::new();
        for name in names {
            let found = self.labels.iter().find(|l| {
                l.workspace_id == workspace_id && l.name.eq_ignore_ascii_case(name.trim())
            });
            if let Some(label) = found
                && !ids.contains(&label.id)
            {
                ids.push(label.id.clone());
            }
        }
        ids
    }

    fn label_names(&self, ids: &[String]) -> String {
        let names: Vec<&str> = self
            .labels
            .iter()
            .filter(|l| ids.contains(&l.id))
            .map(|l| l.name.as_str())
            .collect();
        if names.is_empty() {
            "none".to_string()
        } else {
            names.join(", ")
        }
    }

    fn place(&self, workspace_id: &str, collection_id: Option<&str>) -> assist::ChatPlace {
        let names = |id: Option<&str>| self.collection_name(id).to_string();
        assist::ChatPlace {
            collection: collection_id.map(|id| names(Some(id))),
            collections: self
                .collections
                .iter()
                .filter(|c| c.workspace_id == workspace_id)
                .map(|c| c.name.clone())
                .collect(),
            labels: self
                .labels
                .iter()
                .filter(|l| l.workspace_id == workspace_id)
                .map(|l| l.name.clone())
                .collect(),
        }
    }
}

/// Appends `extra` to a prompt's leading system message. One system message,
/// not two: some OpenAI-compatible servers refuse a second.
fn extend_system(mut messages: Vec<ChatMessage>, extra: &str) -> Vec<ChatMessage> {
    if let Some(first) = messages.first_mut() {
        first.content.push_str(extra);
    }
    messages
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
/// client → server:  {"token":"…","message":"…","history":[{"role","content"},…],
///                    "workspace_id"?,"collection_id"?,"read_only"?}
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
    let taxonomy = Taxonomy::load(state, &user_id).await?;
    let collection_id = workspace_id.as_deref().and_then(|w| {
        let wanted = request.collection_id.as_deref()?;
        taxonomy
            .collection_id(w, wanted)
            .filter(|id| id == wanted.trim())
    });
    let place = workspace_id.as_deref().map_or(String::new(), |w| {
        assist::place_text(&taxonomy.place(w, collection_id.as_deref()))
    });

    let decision = route(state, cfg, &history, message, &llm_settings.prompt, &place).await;
    // Read-only answers a change request over the notes it is about.
    let decision = match decision {
        RouteDecision::Write(query) if request.read_only => RouteDecision::Search(query),
        decision => decision,
    };

    // Phase 2, retrieve when the turn needs notes. A Search reads them to
    // answer; a Write reads them as candidates to add to.
    let notes = match &decision {
        RouteDecision::Search(query) | RouteDecision::Write(query) => {
            retrieve(state, &search, &scope, &taxonomy, &user_id, query).await?
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
            collection_id: collection_id.as_deref(),
            taxonomy: &taxonomy,
            prompt: &llm_settings.prompt,
            permissions: WritePermissions {
                create: llm_settings.chat_create,
                edit: llm_settings.chat_edit,
                organize: llm_settings.chat_organize,
            },
        };
        let applied = write_from_plan(state, &turn, &notes, &history, message, &place).await?;
        if let Some(applied) = applied {
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

    let mut extra = place;
    if request.read_only {
        extra.push_str(assist::READ_ONLY_NOTE);
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
    let messages = extend_system(messages, &extra);
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
    place: &str,
) -> RouteDecision {
    let messages = extend_system(assist::route_messages(history, message, prompt), place);
    let routing = state.llm.complete(cfg, messages);
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
    taxonomy: &Taxonomy,
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
        let label_ids = match state.repo.note_view(&note_id, user_id).await {
            Ok(Some(view)) => view.label_ids,
            _ => Vec::new(),
        };
        // Prompt rendering, not the embedding text: checklists keep their
        // per-item checked state here.
        let text = format!(
            "collection={}, labels={}, kind={}, pinned={}, archived={}, color={}, reminder_at={}\n{}",
            taxonomy.collection_name(record.collection_id.as_deref()),
            taxonomy.label_names(&label_ids),
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
