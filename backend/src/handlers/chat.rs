//! Notes chat over a WebSocket: route the turn, retrieve context, then either
//! answer over the notes or apply a create/append write the model planned.

use axum::extract::ws::{Message, WebSocket};
use axum::extract::{Query, State, WebSocketUpgrade};
use axum::response::Response;
use futures::{SinkExt, StreamExt};
use serde::Deserialize;

use crate::AppState;
use crate::error::{ApiError, ApiResult};
use crate::models::*;

use super::events::WsParams;
use super::{apply_note_update, create_note_for_user, new_id};

/// One chat turn from the client.
#[derive(Deserialize)]
struct ChatRequest {
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
    cfg: &'a crate::llm::LlmConfig,
    workspace_id: Option<&'a str>,
}

#[derive(Deserialize)]
struct ChatHistoryEntry {
    role: String,
    content: String,
}

/// Notes chat over a WebSocket (a streaming response has to reach Flutter
/// web, whose HTTP client can't stream bodies — the app already speaks
/// token-in-query WS for change events). One request per connection:
///
/// ```text
/// client → server:  {"message": "…", "history": [{"role","content"}, …]}
/// server → client:  {"type":"sources","notes":[{"id","title"}, …]}
///                   {"type":"created","action":"create"|"append","note":{"id","title"}}
///                                                (0..1, only when the turn
///                                                 created or appended a note)
///                   {"type":"delta","text":"…"}   (0..n)
///                   {"type":"done"} | {"type":"error","message":"…"}
/// ```
pub async fn chat_ws(
    State(state): State<AppState>,
    Query(params): Query<WsParams>,
    upgrade: WebSocketUpgrade,
) -> ApiResult<Response> {
    let user_id = state
        .repo
        .user_id_for_token(&params.token)
        .await?
        .ok_or(ApiError::Unauthorized)?;
    Ok(upgrade.on_upgrade(move |socket| chat_loop(socket, state, user_id)))
}

async fn chat_loop(socket: WebSocket, state: AppState, user_id: String) {
    let (mut sink, mut stream) = socket.split();

    // Terminal error helper: best-effort send, then the connection closes.
    async fn send_error(sink: &mut (impl SinkExt<Message> + Unpin), message: &str) {
        let frame = serde_json::json!({"type": "error", "message": message}).to_string();
        let _ = sink.send(Message::text(frame)).await;
    }

    // First (and only) request frame, ignoring pings.
    let request = tokio::time::timeout(std::time::Duration::from_secs(30), async {
        while let Some(Ok(msg)) = stream.next().await {
            if let Message::Text(text) = msg {
                return Some(text);
            }
        }
        None
    })
    .await;
    let Ok(Some(text)) = request else {
        send_error(&mut sink, "expected a chat request").await;
        return;
    };
    let Ok(request) = serde_json::from_str::<ChatRequest>(&text) else {
        send_error(&mut sink, "malformed chat request").await;
        return;
    };
    let message = request.message.trim();
    if message.is_empty() {
        send_error(&mut sink, "empty message").await;
        return;
    }

    // Preconditions: retrieval needs the server-side embedder, generation
    // needs the user's own LLM config with chat enabled.
    let Some(search) = state.search.clone() else {
        send_error(&mut sink, "chat needs semantic search enabled on this server").await;
        return;
    };
    let settings = state.repo.settings_for_user(&user_id).await.ok().flatten();
    let effective = state.managed.overlay(settings.as_deref());
    let llm_settings = crate::assist::parse_llm_settings_value(&effective);
    let Some(cfg) = llm_settings.config.filter(|_| llm_settings.chat) else {
        send_error(&mut sink, "configure an AI provider in Settings to use chat").await;
        return;
    };

    let history: Vec<(String, String)> =
        request.history.into_iter().map(|h| (h.role, h.content)).collect();

    // Scope the turn to the open workspace. The vector index partitions by
    // participant, not by workspace, so the narrowing happens over its hits.
    let workspace_id =
        request.workspace_id.as_deref().map(str::trim).filter(|w| !w.is_empty()).map(str::to_owned);
    let allowed_notes = match &workspace_id {
        Some(id) => match super::workspace_note_ids(&state, &user_id, id).await {
            Ok(ids) => Some(ids),
            Err(_) => {
                send_error(&mut sink, "that workspace is not available").await;
                return;
            }
        },
        None => None,
    };

    // Phase 1 — route: the model decides whether this turn needs notes at
    // all and, if so, writes the search query itself (resolving references
    // from the conversation, so "and the plants?" looks up plants and a bare
    // "thanks" looks up nothing). A failed or unparseable routing call falls
    // back to plain retrieval on a blend of recent user turns — a weak model
    // can't make chat worse than ordinary RAG, only better.
    let decision = match tokio::time::timeout(
        std::time::Duration::from_secs(10),
        state.llm.complete(&cfg, crate::assist::route_messages(&history, message)),
    )
    .await
    {
        Ok(Ok(reply)) => crate::assist::parse_route_reply(&reply),
        _ => None,
    }
    .unwrap_or_else(|| {
        crate::assist::RouteDecision::Search(crate::assist::retrieval_query(&history, message))
    });

    // Phase 2 — retrieve when the turn needs notes. A Search reads them to
    // answer; a Write reads them as candidates to add to. Over-fetch because
    // trashed notes linger in the vector index; keep the best non-trashed hits.
    let mut notes: Vec<(String, String, String)> = Vec::new(); // (id, title, text)
    let retrieval = match &decision {
        crate::assist::RouteDecision::Search(q) | crate::assist::RouteDecision::Write(q) => Some(q),
        crate::assist::RouteDecision::Direct => None,
    };
    if let Some(query) = retrieval {
        // Over-fetch: trashed notes linger in the index, and a workspace filter
        // drops the other workspaces' hits on top of that.
        let overfetch = if allowed_notes.is_some() { 8 } else { 2 };
        let hits = match search
            .search(&user_id, query, crate::assist::CHAT_CONTEXT_NOTES * overfetch)
            .await
        {
            Ok(hits) => hits,
            Err(e) => {
                eprintln!("chat retrieval failed for {user_id}: {e:#}");
                send_error(&mut sink, "search failed").await;
                return;
            }
        };
        for (note_id, _score) in hits {
            if notes.len() >= crate::assist::CHAT_CONTEXT_NOTES {
                break;
            }
            if allowed_notes.as_ref().is_some_and(|ids| !ids.contains(&note_id)) {
                continue;
            }
            let Ok(Some(record)) = state.repo.note_record(&note_id).await else { continue };
            if record.trashed {
                continue;
            }
            // Prompt rendering, not the embedding text: checklists keep
            // their per-item checked state here.
            let text = crate::assist::note_prompt_text(&record);
            notes.push((record.id, record.title, text));
        }
    }

    // Phase 2b — write: turn a create/append request into one structured edit
    // and apply it, streaming a confirmation. A failed or unusable plan falls
    // through to answering over the retrieved notes, so a weak model can never
    // silently drop the turn (or, worse, touch a note it shouldn't).
    if matches!(decision, crate::assist::RouteDecision::Write(_))
        && chat_write(
            &mut sink,
            &state,
            &TurnContext { user_id: &user_id, cfg: &cfg, workspace_id: workspace_id.as_deref() },
            &notes,
            &history,
            message,
        )
        .await
    {
        return;
    }

    let source_list: Vec<serde_json::Value> = notes
        .iter()
        .map(|(id, title, _)| serde_json::json!({"id": id, "title": title}))
        .collect();
    let sources = serde_json::json!({"type": "sources", "notes": source_list});
    if sink.send(Message::text(sources.to_string())).await.is_err() {
        return;
    }

    let prompt_notes: Vec<(String, String)> =
        notes.iter().map(|(_, title, text)| (title.clone(), text.clone())).collect();
    let messages = match &decision {
        // Write reaches here only when its plan was unusable: answer over the
        // retrieved notes like an ordinary read turn rather than writing.
        crate::assist::RouteDecision::Search(_) | crate::assist::RouteDecision::Write(_) => {
            crate::assist::chat_messages(&prompt_notes, &history, message)
        }
        crate::assist::RouteDecision::Direct => {
            crate::assist::chat_messages_direct(&history, message)
        }
    };

    let mut tokens = match state.llm.stream(&cfg, messages).await {
        Ok(tokens) => tokens,
        Err(e) => {
            send_error(&mut sink, &format!("{e:#}")).await;
            return;
        }
    };

    // Forward deltas until the stream ends, errors, stalls, or the client
    // leaves. Dropping `tokens` aborts the underlying HTTP request.
    loop {
        tokio::select! {
            token = tokio::time::timeout(std::time::Duration::from_secs(120), tokens.next()) => {
                match token {
                    Err(_) => {
                        send_error(&mut sink, "the model stopped responding").await;
                        break;
                    }
                    Ok(None) => {
                        let _ = sink.send(Message::text(r#"{"type":"done"}"#.to_string())).await;
                        break;
                    }
                    Ok(Some(Ok(text))) => {
                        let frame = serde_json::json!({"type": "delta", "text": text}).to_string();
                        if sink.send(Message::text(frame)).await.is_err() {
                            break; // client gone
                        }
                    }
                    Ok(Some(Err(e))) => {
                        send_error(&mut sink, &format!("{e:#}")).await;
                        break;
                    }
                }
            }
            incoming = stream.next() => {
                match incoming {
                    Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                    _ => {} // ignore pings/client chatter
                }
            }
        }
    }
}

/// The chat write path: ask the model to turn the user's create/append request
/// into one structured edit ([`assist::write_plan_messages`]), apply it through
/// the shared create/update pipeline, and stream a `created` frame plus a short
/// confirmation. Returns `true` when it fully handled the turn (a terminal
/// frame was sent — success or a hard failure); `false` means the plan was
/// unusable (timeout, unparseable, or a hallucinated append target) and the
/// caller should fall through to answering over the retrieved notes rather than
/// write something the user didn't ask for.
///
/// [`assist::write_plan_messages`]: crate::assist::write_plan_messages
async fn chat_write<S>(
    sink: &mut S,
    state: &AppState,
    turn: &TurnContext<'_>,
    candidates: &[(String, String, String)], // (id, title, text)
    history: &[(String, String)],
    message: &str,
) -> bool
where
    S: SinkExt<Message> + Unpin,
{
    async fn send<S: SinkExt<Message> + Unpin>(sink: &mut S, value: serde_json::Value) -> bool {
        sink.send(Message::text(value.to_string())).await.is_ok()
    }
    // " \"Groceries\"" or "" for a blank title — folded into a sentence.
    fn titled(title: &str) -> String {
        let t = title.trim();
        if t.is_empty() { String::new() } else { format!(" \"{t}\"") }
    }
    fn plural(n: usize) -> &'static str {
        if n == 1 { "" } else { "s" }
    }

    // Plan the edit; a failed/timed-out planner falls through to answering.
    let planner = crate::assist::write_plan_messages(candidates, history, message);
    let reply = match tokio::time::timeout(
        std::time::Duration::from_secs(10),
        state.llm.complete(turn.cfg, planner),
    )
    .await
    {
        Ok(Ok(reply)) => reply,
        _ => return false,
    };
    let candidate_ids: Vec<String> = candidates.iter().map(|(id, _, _)| id.clone()).collect();
    let Some(action) = crate::assist::parse_write_action(&reply, &candidate_ids) else {
        return false;
    };

    // Apply the edit through the same pipeline the HTTP handlers use, so it
    // gets indexing, auto-labeling, version history, and the WS refresh nudge.
    let (action_label, view, confirmation) = match action {
        crate::assist::WriteAction::Create { kind, title, content, items } => {
            let is_checklist = kind == KIND_CHECKLIST;
            let (content, item_structs) = if is_checklist {
                let structs: Vec<ChecklistItem> = items
                    .iter()
                    .map(|text| ChecklistItem { id: new_id(), text: text.clone(), done: false })
                    .collect();
                (content, structs)
            } else {
                // A text note can't render checklist rows, so fold any items
                // the model produced into the body — nothing is lost.
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
                // The note belongs where the user is looking; absent, the
                // create pipeline falls back to their default workspace.
                workspace_id: turn.workspace_id.map(str::to_owned),
                ..Default::default()
            };
            let view = match create_note_for_user(state, turn.user_id, body).await {
                Ok(view) => view,
                Err(_) => {
                    send(sink, serde_json::json!({"type":"error","message":"could not create the note"})).await;
                    return true;
                }
            };
            let confirmation = if is_checklist {
                format!("Created a checklist{} with {n} item{}.", titled(&view.note.title), plural(n))
            } else {
                format!("Created a note{}.", titled(&view.note.title))
            };
            ("create", view, confirmation)
        }
        crate::assist::WriteAction::Append { note_id, content, items } => {
            let Ok(Some(record)) = state.repo.note_record(&note_id).await else {
                return false; // vanished between retrieval and now
            };
            let is_checklist = record.kind == KIND_CHECKLIST;
            let mut body = UpdateNote::default();
            let mut added = 0usize;
            if is_checklist && !items.is_empty() {
                let mut merged = record.items.clone();
                for text in &items {
                    merged.push(ChecklistItem { id: new_id(), text: text.clone(), done: false });
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
                return false; // nothing usable to add
            }
            let view = match apply_note_update(state, turn.user_id, &note_id, body).await {
                Ok(view) => view,
                Err(_) => {
                    send(sink, serde_json::json!({"type":"error","message":"could not update the note"})).await;
                    return true;
                }
            };
            let confirmation = if added > 0 {
                format!("Added {added} item{} to{}.", plural(added), titled(&view.note.title))
            } else {
                format!("Updated{}.", titled(&view.note.title))
            };
            ("append", view, confirmation)
        }
    };

    // A `created` frame carries the note so the client can offer a chip that
    // opens it; the confirmation streams as ordinary delta text. Unknown frame
    // types are ignored by older clients, so this is backwards-compatible.
    let created = serde_json::json!({
        "type": "created",
        "action": action_label,
        "note": {"id": view.note.id, "title": view.note.title},
    });
    if !send(sink, created).await {
        return true; // client gone; turn is still "handled"
    }
    if !send(sink, serde_json::json!({"type": "delta", "text": confirmation})).await {
        return true;
    }
    send(sink, serde_json::json!({"type": "done"})).await;
    true
}
