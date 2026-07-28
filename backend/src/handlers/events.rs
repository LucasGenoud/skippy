//! The change-event WebSocket: clients hold one open connection and receive
//! `notes_changed` nudges, responding with a debounced refetch.

use axum::extract::ws::{Message, WebSocket};
use axum::extract::{Query, State, WebSocketUpgrade};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use futures::{SinkExt, StreamExt};
use serde::Deserialize;
use tokio::sync::OwnedSemaphorePermit;

use crate::AppState;

use super::CHANGED_MSG;

/// Authentication is the socket's first frame rather than a query parameter.
/// Query strings are routinely retained by reverse-proxy access logs; a bearer
/// credential must not appear there.
#[derive(Deserialize)]
struct WsAuth {
    token: String,
}

/// Temporary rolling-upgrade compatibility for installed native clients.
/// New clients put the token in frame one; once old clients have aged out this
/// query fallback can be removed completely.
#[derive(Default, Deserialize)]
pub struct LegacyWsParams {
    pub(crate) token: Option<String>,
}

pub async fn ws_handler(
    State(state): State<AppState>,
    Query(params): Query<LegacyWsParams>,
    upgrade: WebSocketUpgrade,
) -> Response {
    if let Some(token) = params.token.filter(|token| !token.is_empty()) {
        return match state.repo.user_id_for_token(&token).await {
            Ok(Some(user_id)) => upgrade
                .max_message_size(4 * 1024)
                .max_frame_size(4 * 1024)
                .on_upgrade(move |socket| ws_loop(socket, state, Some(user_id), None)),
            Ok(None) => StatusCode::UNAUTHORIZED.into_response(),
            Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        };
    }
    let Some(auth_permit) = crate::ws::pending_auth_permit() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    upgrade
        .max_message_size(4 * 1024)
        .max_frame_size(4 * 1024)
        .on_upgrade(move |socket| ws_loop(socket, state, None, Some(auth_permit)))
}

async fn ws_loop(
    socket: WebSocket,
    state: AppState,
    authenticated_user: Option<String>,
    auth_permit: Option<OwnedSemaphorePermit>,
) {
    let (mut sink, mut stream) = socket.split();

    let user_id = match authenticated_user {
        Some(user_id) => user_id,
        None => {
            // Authenticate promptly before subscribing to any user event
            // channel. The permit bounds anonymous sockets during this wait.
            let auth = tokio::time::timeout(std::time::Duration::from_secs(5), async {
                while let Some(Ok(message)) = stream.next().await {
                    if let Message::Text(text) = message {
                        return serde_json::from_str::<WsAuth>(&text).ok();
                    }
                }
                None
            })
            .await
            .ok()
            .flatten();
            let Some(token) = auth
                .map(|auth| auth.token)
                .filter(|token| !token.is_empty())
            else {
                let _ = sink.send(Message::Close(None)).await;
                return;
            };
            let Ok(Some(user_id)) = state.repo.user_id_for_token(&token).await else {
                let _ = sink.send(Message::Close(None)).await;
                return;
            };
            drop(auth_permit);
            user_id
        }
    };

    let mut events = state.hub.subscribe(&user_id);
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
