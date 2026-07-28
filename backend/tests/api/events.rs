//! Change-event WebSocket authentication and delivery.

use crate::helpers::*;
use futures::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message as WsMessage;

async fn websocket_server(state: AppState) -> std::net::SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, build_app(state)).await.unwrap();
    });
    addr
}

#[tokio::test]
async fn change_socket_authenticates_in_its_first_frame() {
    let app_state = state().await;
    let app = build_app(app_state.clone());
    let (token, user_id) = register(&app, "ada").await;
    let addr = websocket_server(app_state.clone()).await;

    let (mut socket, _) = tokio_tungstenite::connect_async(format!("ws://{addr}/api/ws"))
        .await
        .expect("ws connect");
    socket
        .send(WsMessage::text(json!({"token": token}).to_string()))
        .await
        .unwrap();

    // Authentication and subscription happen asynchronously after the frame.
    // Repeat the idempotent nudge until the subscribed socket receives one.
    let mut received = false;
    for _ in 0..50 {
        app_state
            .hub
            .notify(std::slice::from_ref(&user_id), "notes_changed");
        if let Ok(Some(Ok(WsMessage::Text(text)))) =
            tokio::time::timeout(std::time::Duration::from_millis(20), socket.next()).await
        {
            received = text == "notes_changed";
            if received {
                break;
            }
        }
    }
    assert!(
        received,
        "authenticated socket never received its change nudge"
    );

    let (mut rejected, _) = tokio_tungstenite::connect_async(format!("ws://{addr}/api/ws"))
        .await
        .expect("second ws connect");
    rejected
        .send(WsMessage::text(r#"{"token":"not-a-session"}"#))
        .await
        .unwrap();
    let frame = tokio::time::timeout(std::time::Duration::from_secs(1), rejected.next())
        .await
        .expect("invalid authentication should close promptly");
    assert!(matches!(frame, Some(Ok(WsMessage::Close(_)))));
}

#[tokio::test]
async fn legacy_query_auth_remains_available_during_mobile_rollout() {
    let app_state = state().await;
    let app = build_app(app_state.clone());
    let (token, user_id) = register(&app, "ada").await;
    let addr = websocket_server(app_state.clone()).await;

    // Older native clients send no first frame, so receiving a nudge proves
    // the query credential was authenticated before the upgrade completed.
    let (mut socket, _) =
        tokio_tungstenite::connect_async(format!("ws://{addr}/api/ws?token={token}"))
            .await
            .expect("legacy ws connect");
    let mut received = false;
    for _ in 0..50 {
        app_state
            .hub
            .notify(std::slice::from_ref(&user_id), "notes_changed");
        if let Ok(Some(Ok(WsMessage::Text(text)))) =
            tokio::time::timeout(std::time::Duration::from_millis(20), socket.next()).await
        {
            received = text == "notes_changed";
            if received {
                break;
            }
        }
    }
    assert!(received, "legacy socket never received its change nudge");
}
