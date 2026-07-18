//! The change-event WebSocket: clients hold one open connection and receive
//! `notes_changed` nudges, responding with a debounced refetch.

use axum::extract::ws::{Message, WebSocket};
use axum::extract::{Query, State, WebSocketUpgrade};
use axum::response::Response;
use futures::{SinkExt, StreamExt};
use serde::Deserialize;

use crate::AppState;
use crate::error::{ApiError, ApiResult};

use super::CHANGED_MSG;

/// Token-in-query auth, shared with the chat socket: browsers can't set
/// headers on a WebSocket upgrade.
#[derive(Deserialize)]
pub struct WsParams {
    pub(super) token: String,
}

pub async fn ws_handler(
    State(state): State<AppState>,
    Query(params): Query<WsParams>,
    upgrade: WebSocketUpgrade,
) -> ApiResult<Response> {
    let user_id = state
        .repo
        .user_id_for_token(&params.token)
        .await?
        .ok_or(ApiError::Unauthorized)?;
    Ok(upgrade.on_upgrade(move |socket| ws_loop(socket, state, user_id)))
}

async fn ws_loop(socket: WebSocket, state: AppState, user_id: String) {
    let mut events = state.hub.subscribe(&user_id);
    let (mut sink, mut stream) = socket.split();
    loop {
        tokio::select! {
            event = events.recv() => {
                match event {
                    Ok(msg) => {
                        if sink.send(Message::text(msg)).await.is_err() {
                            break;
                        }
                    }
                    // Lagged: we dropped events; a generic nudge still works.
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                        if sink.send(Message::text(CHANGED_MSG)).await.is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            incoming = stream.next() => {
                match incoming {
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Err(_)) => break,
                    _ => {} // ignore pings/client chatter
                }
            }
        }
    }
}
