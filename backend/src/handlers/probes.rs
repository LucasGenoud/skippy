//! Configuration probes behind the Settings "Test" buttons. Both take the
//! config from the request body (not stored settings) so the user can test
//! before saving, and both report failure as a *result* (`ok: false`), not an
//! HTTP error.

use axum::extract::State;
use axum::Json;
use serde::Deserialize;

use crate::AppState;
use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};

#[derive(Deserialize)]
pub struct LlmTestRequest {
    base_url: String,
    #[serde(default)]
    api_key: String,
    model: String,
}

/// Probe an LLM configuration with a tiny completion. Powers the "Test
/// connection" button in Settings.
pub async fn llm_test(
    State(state): State<AppState>,
    AuthUser(_user_id): AuthUser,
    Json(body): Json<LlmTestRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    // Server-managed keys win over the (possibly locked/blank) body fields, so
    // "Test connection" works even when the endpoint, model, or key is pinned
    // via env and never sent by the client.
    let pick = |key: &str, body: &str| {
        state.managed.text(key).map(str::to_string).unwrap_or_else(|| body.trim().to_string())
    };
    let cfg = crate::llm::LlmConfig {
        base_url: pick("llm_base_url", &body.base_url),
        api_key: pick("llm_api_key", &body.api_key),
        model: pick("llm_model", &body.model),
    };
    if cfg.base_url.is_empty() || cfg.model.is_empty() {
        return Err(ApiError::BadRequest("base_url and model are required".to_string()));
    }
    let probe = state.llm.complete(&cfg, vec![crate::llm::ChatMessage::user("Say OK")]);
    let result = match tokio::time::timeout(std::time::Duration::from_secs(20), probe).await {
        Ok(Ok(_)) => serde_json::json!({"ok": true}),
        Ok(Err(e)) => serde_json::json!({"ok": false, "error": format!("{e:#}")}),
        Err(_) => serde_json::json!({"ok": false, "error": "timed out after 20s"}),
    };
    Ok(Json(result))
}

/// Probe a notification configuration by sending a real test message. Powers
/// the "Send test notification" button in Settings. The body is a
/// settings-shaped JSON fragment with the connector keys (e.g. `ntfy_url`),
/// so new connectors need no endpoint changes.
pub async fn notify_test(
    State(state): State<AppState>,
    AuthUser(_user_id): AuthUser,
    Json(body): Json<serde_json::Value>,
) -> ApiResult<Json<serde_json::Value>> {
    if !body.is_object() {
        return Err(ApiError::BadRequest("expected a JSON object".to_string()));
    }
    if !state.notifiers.iter().any(|c| c.configured(&body)) {
        return Err(ApiError::BadRequest(
            "configure at least one notification channel".to_string(),
        ));
    }
    let notification = crate::notify::Notification {
        title: "Sticky Notes".to_string(),
        body: "Test notification — reminders will arrive here.".to_string(),
    };
    let errors = crate::notify::send_configured(&state.notifiers, &body, &notification).await;
    let result = if errors.is_empty() {
        serde_json::json!({"ok": true})
    } else {
        serde_json::json!({"ok": false, "error": errors.join("; ")})
    };
    Ok(Json(result))
}
