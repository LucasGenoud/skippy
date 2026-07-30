//! LLM access over any OpenAI-compatible chat-completions API (OpenAI itself,
//! Ollama's `/v1` endpoints, LM Studio, vLLM, ...). Unlike [`crate::search`]
//! and [`crate::transcribe`] this is not a server-wide optional service:
//! every user brings their own endpoint/key/model, stored in their settings
//! document and parsed per call by [`crate::assist::parse_llm_settings`].
//!
//! The HTTP client itself is always present on `AppState`; a user without a
//! configured endpoint simply never reaches it.

use std::collections::VecDeque;
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use futures::stream::BoxStream;
use serde::Serialize;

/// Per-call connection details, parsed from the requesting user's settings.
#[derive(Debug, Clone, PartialEq)]
pub struct LlmConfig {
    /// Base URL including the version prefix, e.g. `https://api.openai.com/v1`
    /// or `http://localhost:11434/v1`.
    pub base_url: String,
    /// May be empty (Ollama); the Authorization header is omitted then.
    pub api_key: String,
    pub model: String,
}

/// One message in an OpenAI-style conversation.
#[derive(Debug, Clone, Serialize)]
pub struct ChatMessage {
    pub role: &'static str,
    pub content: String,
}

impl ChatMessage {
    pub fn system(content: impl Into<String>) -> Self {
        Self {
            role: "system",
            content: content.into(),
        }
    }
    pub fn user(content: impl Into<String>) -> Self {
        Self {
            role: "user",
            content: content.into(),
        }
    }
    pub fn assistant(content: impl Into<String>) -> Self {
        Self {
            role: "assistant",
            content: content.into(),
        }
    }
}

/// Streamed completion: each item is a content delta.
pub type TokenStream = BoxStream<'static, anyhow::Result<String>>;

/// Chat-completions access. A trait so tests can inject a deterministic fake
/// instead of standing up a model server.
#[async_trait]
pub trait Llm: Send + Sync {
    /// One-shot completion (auto-labeling, connection test).
    async fn complete(&self, cfg: &LlmConfig, messages: Vec<ChatMessage>)
    -> anyhow::Result<String>;
    /// Streaming completion; yields content deltas (notes chat).
    async fn stream(
        &self,
        cfg: &LlmConfig,
        messages: Vec<ChatMessage>,
    ) -> anyhow::Result<TokenStream>;
}

/// Talks to an OpenAI-compatible `POST {base}/chat/completions`.
pub struct OpenAiCompatLlm;

impl Default for OpenAiCompatLlm {
    fn default() -> Self {
        Self
    }
}

impl OpenAiCompatLlm {
    async fn request(
        &self,
        cfg: &LlmConfig,
        messages: &[ChatMessage],
        stream: bool,
    ) -> anyhow::Result<reqwest::RequestBuilder> {
        let url = format!("{}/chat/completions", cfg.base_url.trim_end_matches('/'));
        let target = crate::outbound::resolve_http_url(
            &url,
            crate::outbound::allow_private_user_endpoints(),
        )
        .await?;
        // A fresh, DNS-pinned client prevents rebinding between validation and
        // connect. There is no global timeout because streaming chats can be
        // long-lived; callers bound non-streaming or idle time separately.
        let client = target
            .client_builder()
            .connect_timeout(crate::outbound::CONNECT_TIMEOUT)
            .build()?;
        let mut req = client.post(target.url).json(&serde_json::json!({
            "model": cfg.model,
            "messages": messages,
            "stream": stream,
        }));
        if !cfg.api_key.is_empty() {
            req = req.bearer_auth(&cfg.api_key);
        }
        Ok(req)
    }
}

/// Turn a non-2xx response into an error carrying a truncated body (and never
/// the API key).
async fn status_error(response: reqwest::Response) -> anyhow::Error {
    let status = response.status();
    let body = crate::outbound::read_body_prefix(response, 16 * 1024).await;
    let body = String::from_utf8_lossy(&body)
        .chars()
        .take(300)
        .collect::<String>();
    anyhow::anyhow!("llm returned {status}: {body}")
}

const MAX_COMPLETION_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
const MAX_SSE_BUFFER_BYTES: usize = 1024 * 1024;

#[async_trait]
impl Llm for OpenAiCompatLlm {
    async fn complete(
        &self,
        cfg: &LlmConfig,
        messages: Vec<ChatMessage>,
    ) -> anyhow::Result<String> {
        let response = self
            .request(cfg, &messages, false)
            .await?
            .timeout(Duration::from_secs(30))
            .send()
            .await?;
        if !response.status().is_success() {
            return Err(status_error(response).await);
        }
        let body =
            crate::outbound::read_body_capped(response, MAX_COMPLETION_RESPONSE_BYTES).await?;
        let value: serde_json::Value = serde_json::from_slice(&body)?;
        value["choices"][0]["message"]["content"]
            .as_str()
            .map(|s| s.to_string())
            .ok_or_else(|| anyhow::anyhow!("llm response had no message content"))
    }

    async fn stream(
        &self,
        cfg: &LlmConfig,
        messages: Vec<ChatMessage>,
    ) -> anyhow::Result<TokenStream> {
        let response = self.request(cfg, &messages, true).await?.send().await?;
        if !response.status().is_success() {
            return Err(status_error(response).await);
        }
        // State: (byte stream, line buffer, deltas not yet yielded, saw [DONE]).
        let state = (
            response.bytes_stream(),
            String::new(),
            VecDeque::new(),
            false,
        );
        let stream = futures::stream::try_unfold(
            state,
            |(mut bytes, mut buf, mut pending, mut done)| async move {
                loop {
                    if let Some(delta) = pending.pop_front() {
                        return Ok(Some((delta, (bytes, buf, pending, done))));
                    }
                    if done {
                        return Ok(None);
                    }
                    match bytes.next().await {
                        Some(chunk) => {
                            buf.push_str(&String::from_utf8_lossy(&chunk?));
                            if buf.len() > MAX_SSE_BUFFER_BYTES {
                                return Err(anyhow::anyhow!(
                                    "llm stream frame exceeded {} bytes",
                                    MAX_SSE_BUFFER_BYTES
                                ));
                            }
                            let (deltas, finished) = drain_sse_deltas(&mut buf);
                            pending.extend(deltas);
                            done = finished;
                        }
                        // Stream ended without [DONE]; treat as complete.
                        None => return Ok(None),
                    }
                }
            },
        );
        Ok(stream.boxed())
    }
}

/// Drain complete SSE lines from the front of `buf` (a trailing partial line
/// stays buffered), returning the extracted content deltas and whether the
/// `[DONE]` sentinel was seen. Comment/`event:` lines, role-only first deltas,
/// finish chunks, and unparseable keep-alive lines are all skipped rather than
/// treated as errors, providers differ in what they pepper into the stream.
pub fn drain_sse_deltas(buf: &mut String) -> (Vec<String>, bool) {
    let mut deltas = Vec::new();
    let mut done = false;
    while let Some(newline) = buf.find('\n') {
        let line: String = buf.drain(..=newline).collect();
        let line = line.trim_end_matches(['\n', '\r']);
        let Some(payload) = line.strip_prefix("data:") else {
            continue;
        };
        let payload = payload.trim_start();
        if payload == "[DONE]" {
            done = true;
            continue;
        }
        let Ok(value) = serde_json::from_str::<serde_json::Value>(payload) else {
            continue;
        };
        if let Some(content) = value["choices"][0]["delta"]["content"].as_str()
            && !content.is_empty()
        {
            deltas.push(content.to_string());
        }
    }
    (deltas, done)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn delta_line(text: &str) -> String {
        format!(
            "data: {}\n",
            serde_json::json!({"choices": [{"delta": {"content": text}}]})
        )
    }

    #[test]
    fn extracts_deltas_and_done() {
        let mut buf = format!("{}{}data: [DONE]\n", delta_line("Hel"), delta_line("lo"));
        let (deltas, done) = drain_sse_deltas(&mut buf);
        assert_eq!(deltas, vec!["Hel", "lo"]);
        assert!(done);
        assert!(buf.is_empty());
    }

    #[test]
    fn keeps_partial_line_buffered() {
        let full = delta_line("split");
        let (head, tail) = full.split_at(20);
        let mut buf = head.to_string();
        let (deltas, done) = drain_sse_deltas(&mut buf);
        assert!(deltas.is_empty());
        assert!(!done);
        buf.push_str(tail);
        let (deltas, _) = drain_sse_deltas(&mut buf);
        assert_eq!(deltas, vec!["split"]);
    }

    #[test]
    fn skips_role_only_and_finish_chunks() {
        let mut buf = concat!(
            "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n",
        )
        .to_string();
        let (deltas, done) = drain_sse_deltas(&mut buf);
        assert_eq!(deltas, vec!["hi"]);
        assert!(!done);
    }

    #[test]
    fn skips_comments_events_and_garbage() {
        let mut buf = concat!(
            ": keep-alive\n",
            "event: message\n",
            "data: not json at all\n",
            "\r\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\r\n",
        )
        .to_string();
        let (deltas, done) = drain_sse_deltas(&mut buf);
        assert_eq!(deltas, vec!["ok"]);
        assert!(!done);
    }
}
