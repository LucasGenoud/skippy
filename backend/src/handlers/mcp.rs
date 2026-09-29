//! Model Context Protocol server over Streamable HTTP, so an AI client can
//! search and read someone's notes and, with a write token, add to them.
//!
//! ```text
//! client ── POST /api/mcp {"method":"tools/call",...} ──▶ TokenUser
//!                                                            │
//!        ◀── {"result":{"content":[...]}} ── mcp_tools ◀─────┘
//! ```
//!
//! Stateless: each POST carries one JSON-RPC message and gets its answer in
//! the response body. There is no session id and no server-sent event
//! stream; the GET that would open one is refused, which the transport
//! allows.
//!
//! There is no Origin check. One guards a server that trusts whoever can
//! reach it, like a localhost daemon; this one trusts only the bearer token,
//! which a page rebound onto this host cannot read.

use axum::Json;
use axum::body::Bytes;
use axum::extract::State;
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde_json::{Value, json};

use super::mcp_tools;
use crate::AppState;
use crate::auth::TokenUser;

/// Protocol revisions this server speaks, newest first. A client asking for
/// one of them gets it; any other gets the newest.
const PROTOCOL_VERSIONS: [&str; 4] = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
const JSONRPC_VERSION: &str = "2.0";
const SERVER_NAME: &str = "skippy";
const INSTRUCTIONS: &str = "Notes from Skippy. A note links to another with \
    [[note-id|Title]] in its text; get_note lists a note's links so they can \
    be followed.";

// JSON-RPC error codes.
const PARSE_ERROR: i64 = -32700;
const INVALID_REQUEST: i64 = -32600;
const METHOD_NOT_FOUND: i64 = -32601;
const INVALID_PARAMS: i64 = -32602;

type RpcResult = Result<Value, (i64, String)>;

pub async fn mcp_post(State(state): State<AppState>, user: TokenUser, body: Bytes) -> Response {
    let Ok(message) = serde_json::from_slice::<Value>(&body) else {
        return rejected(PARSE_ERROR, "the body is not JSON");
    };
    let Some(message) = message.as_object() else {
        return rejected(INVALID_REQUEST, "send one JSON-RPC message per request");
    };

    let method = message.get("method").and_then(Value::as_str);
    let id = message.get("id").cloned();
    let (Some(method), Some(id)) = (method, id) else {
        // A notification, or a reply to a request: nothing to answer.
        if method.is_some() || message.contains_key("result") || message.contains_key("error") {
            return StatusCode::ACCEPTED.into_response();
        }
        return rejected(INVALID_REQUEST, "not a JSON-RPC message");
    };

    let params = message.get("params").cloned().unwrap_or_else(|| json!({}));
    let reply = match handle(&state, &user, method, &params).await {
        Ok(result) => json!({"jsonrpc": JSONRPC_VERSION, "id": id, "result": result}),
        Err((code, text)) => error_reply(id, code, &text),
    };
    Json(reply).into_response()
}

/// Streamable HTTP opens a server-to-client stream with GET. This server has
/// nothing to push, so it says so.
pub async fn mcp_get() -> Response {
    let mut response = StatusCode::METHOD_NOT_ALLOWED.into_response();
    response
        .headers_mut()
        .insert(header::ALLOW, HeaderValue::from_static("POST"));
    response
}

async fn handle(state: &AppState, user: &TokenUser, method: &str, params: &Value) -> RpcResult {
    match method {
        "initialize" => Ok(initialize(params)),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({"tools": mcp_tools::definitions(user.scope)})),
        "tools/call" => {
            let Some(name) = params.get("name").and_then(Value::as_str) else {
                return Err((INVALID_PARAMS, "tools/call needs a tool name".into()));
            };
            let arguments = params
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            match mcp_tools::call(state, &user.user_id, user.scope, name, &arguments).await {
                Some(outcome) => Ok(tool_result(outcome)),
                None => Err((INVALID_PARAMS, format!("unknown tool: {name}"))),
            }
        }
        _ => Err((METHOD_NOT_FOUND, format!("method not supported: {method}"))),
    }
}

fn initialize(params: &Value) -> Value {
    let requested = params.get("protocolVersion").and_then(Value::as_str);
    let version = PROTOCOL_VERSIONS
        .into_iter()
        .find(|v| Some(*v) == requested)
        .unwrap_or(PROTOCOL_VERSIONS[0]);
    json!({
        "protocolVersion": version,
        "capabilities": {"tools": {"listChanged": false}},
        "serverInfo": {"name": SERVER_NAME, "version": env!("CARGO_PKG_VERSION")},
        "instructions": INSTRUCTIONS,
    })
}

/// A tool's answer as MCP carries it. A failed tool is a result the model
/// reads and can recover from, not a protocol error.
fn tool_result(outcome: Result<Value, String>) -> Value {
    match outcome {
        Ok(structured) => json!({
            "content": [{"type": "text", "text": structured.to_string()}],
            "structuredContent": structured,
            "isError": false,
        }),
        Err(message) => json!({
            "content": [{"type": "text", "text": message}],
            "isError": true,
        }),
    }
}

fn error_reply(id: Value, code: i64, message: &str) -> Value {
    json!({
        "jsonrpc": JSONRPC_VERSION,
        "id": id,
        "error": {"code": code, "message": message},
    })
}

fn rejected(code: i64, message: &str) -> Response {
    (
        StatusCode::BAD_REQUEST,
        Json(error_reply(Value::Null, code, message)),
    )
        .into_response()
}
