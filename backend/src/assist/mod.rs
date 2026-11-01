//! Pure helpers for the LLM features (auto-labeling and notes chat): parsing
//! the per-user LLM settings out of the opaque settings document, building
//! prompts, and interpreting model replies. Kept free of I/O so the handlers
//! stay thin and everything here is unit-testable.

mod chat;
mod labeling;
mod settings;
mod write_plan;

pub use chat::*;
pub use labeling::*;
pub use settings::*;
pub use write_plan::*;

use crate::llm::ChatMessage;

/// A note as the chat prompts show it: its id, so the write planner can name
/// a target, its title, and its text rendered for the model.
pub struct PromptNote {
    pub id: String,
    pub title: String,
    pub text: String,
}

/// Max history turns forwarded to the model.
const CHAT_HISTORY_TURNS: usize = 12;

/// Max chars per history entry and per user message.
const CHAT_MESSAGE_CHARS: usize = 4_000;

fn custom_prompt(prompt: &str) -> String {
    let prompt = cap(prompt.trim(), CHAT_MESSAGE_CHARS);
    if prompt.is_empty() {
        String::new()
    } else {
        format!("\n\nUser's custom AI instructions: {prompt}")
    }
}

/// Truncate to at most `max` characters on a char boundary.
fn cap(text: &str, max: usize) -> &str {
    match text.char_indices().nth(max) {
        Some((idx, _)) => &text[..idx],
        None => text,
    }
}

/// Append the capped history and the new user message to a prompt.
fn with_conversation(
    mut messages: Vec<ChatMessage>,
    history: &[(String, String)],
    message: &str,
) -> Vec<ChatMessage> {
    let skip = history.len().saturating_sub(CHAT_HISTORY_TURNS);
    for (role, content) in &history[skip..] {
        let content = cap(content, CHAT_MESSAGE_CHARS).to_string();
        match role.as_str() {
            "user" => messages.push(ChatMessage::user(content)),
            "assistant" => messages.push(ChatMessage::assistant(content)),
            _ => {}
        }
    }
    messages.push(ChatMessage::user(
        cap(message, CHAT_MESSAGE_CHARS).to_string(),
    ));
    messages
}
