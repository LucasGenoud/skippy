//! Pure helpers for the LLM features (auto-labeling and notes chat): parsing
//! the per-user LLM settings out of the opaque settings document, building
//! prompts, and interpreting model replies. Kept free of I/O so the handlers
//! stay thin and everything here is unit-testable.

use crate::llm::{ChatMessage, LlmConfig};
use crate::models::Label;

/// Max note text sent in a labeling prompt.
const LABELING_NOTE_CHARS: usize = 4_000;
/// Max text per retrieved note in the chat system prompt.
const CHAT_NOTE_CHARS: usize = 1_500;
/// Max history turns forwarded to the model.
const CHAT_HISTORY_TURNS: usize = 12;
/// Max chars per history entry and per user message.
const CHAT_MESSAGE_CHARS: usize = 4_000;
/// How many retrieved notes make it into the chat prompt.
pub const CHAT_CONTEXT_NOTES: usize = 6;

/// LLM-related keys parsed out of a user's settings document. The document is
/// otherwise client-owned and opaque; these keys are the shared contract with
/// the app's `SettingsStore`.
#[derive(Debug, PartialEq)]
pub struct LlmSettings {
    /// Present only when base URL and model are both set.
    pub config: Option<LlmConfig>,
    /// Auto-labeling toggle; defaults on (it only matters once configured).
    pub labeling: bool,
    /// Notes-chat toggle; defaults on.
    pub chat: bool,
}

/// Read `llm_base_url` / `llm_api_key` / `llm_model` / `llm_labeling` /
/// `llm_chat` from a settings JSON document (as stored by `put_settings`).
pub fn parse_llm_settings(settings_json: Option<&str>) -> LlmSettings {
    let value: serde_json::Value = settings_json
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default();
    let text = |key: &str| {
        value[key].as_str().map(str::trim).unwrap_or_default().to_string()
    };
    let base_url = text("llm_base_url");
    let model = text("llm_model");
    let config = (!base_url.is_empty() && !model.is_empty()).then(|| LlmConfig {
        base_url,
        api_key: text("llm_api_key"),
        model,
    });
    LlmSettings {
        config,
        labeling: value["llm_labeling"] != false,
        chat: value["llm_chat"] != false,
    }
}

/// Truncate to at most `max` characters on a char boundary.
fn cap(text: &str, max: usize) -> &str {
    match text.char_indices().nth(max) {
        Some((idx, _)) => &text[..idx],
        None => text,
    }
}

/// Prompt asking the model to pick applicable labels for a note, strictly
/// from the user's existing label names.
pub fn labeling_messages(label_names: &[String], note_text: &str) -> Vec<ChatMessage> {
    vec![
        ChatMessage::system(
            "You assign labels to sticky notes. Reply with a JSON array of the \
             label names that clearly apply to the note, chosen only from the \
             provided list. Reply [] if none apply. Output the JSON array and \
             nothing else.",
        ),
        ChatMessage::user(format!(
            "Available labels: {}\n\nNote:\n{}",
            serde_json::to_string(label_names).unwrap_or_else(|_| "[]".into()),
            cap(note_text, LABELING_NOTE_CHARS),
        )),
    ]
}

/// Lenient parse of the model's labeling reply into label names: tolerates
/// code fences and surrounding prose by slicing the first `[` .. last `]`.
/// Returns an empty list when nothing parseable remains.
pub fn parse_label_reply(reply: &str) -> Vec<String> {
    let start = match reply.find('[') {
        Some(i) => i,
        None => return Vec::new(),
    };
    let end = match reply.rfind(']') {
        Some(i) if i > start => i,
        _ => return Vec::new(),
    };
    serde_json::from_str::<Vec<String>>(&reply[start..=end]).unwrap_or_default()
}

/// Map model-suggested names onto the user's labels: case-insensitive,
/// trimmed; unknown names are dropped, duplicates collapse.
pub fn map_label_names(names: &[String], labels: &[Label]) -> Vec<String> {
    let mut ids = Vec::new();
    for name in names {
        let wanted = name.trim().to_lowercase();
        let Some(label) = labels.iter().find(|l| l.name.trim().to_lowercase() == wanted)
        else {
            continue;
        };
        if !ids.contains(&label.id) {
            ids.push(label.id.clone());
        }
    }
    ids
}

/// Build the RAG conversation: a system prompt embedding the retrieved notes,
/// then the (capped) history and the new user message. History roles other
/// than user/assistant are dropped.
pub fn chat_messages(
    notes: &[(String, String)], // (title, text)
    history: &[(String, String)], // (role, content)
    message: &str,
) -> Vec<ChatMessage> {
    let mut context = String::from(
        "You are an assistant for the user's personal sticky notes app. Answer \
         the user's question using the notes below. If the notes don't contain \
         the answer, say so plainly. Be concise.\n\nNotes:",
    );
    if notes.is_empty() {
        context.push_str("\n(none found)");
    }
    for (n, (title, text)) in notes.iter().enumerate() {
        let title = if title.trim().is_empty() { "Untitled" } else { title.trim() };
        context.push_str(&format!("\n\n[{}] {}\n{}", n + 1, title, cap(text, CHAT_NOTE_CHARS)));
    }
    let mut messages = vec![ChatMessage::system(context)];
    let skip = history.len().saturating_sub(CHAT_HISTORY_TURNS);
    for (role, content) in &history[skip..] {
        let content = cap(content, CHAT_MESSAGE_CHARS).to_string();
        match role.as_str() {
            "user" => messages.push(ChatMessage::user(content)),
            "assistant" => messages.push(ChatMessage::assistant(content)),
            _ => {}
        }
    }
    messages.push(ChatMessage::user(cap(message, CHAT_MESSAGE_CHARS).to_string()));
    messages
}

#[cfg(test)]
mod tests {
    use super::*;

    fn label(id: &str, name: &str) -> Label {
        Label { id: id.into(), name: name.into() }
    }

    #[test]
    fn parse_settings_absent_and_partial() {
        assert_eq!(parse_llm_settings(None).config, None);
        assert_eq!(parse_llm_settings(Some("not json")).config, None);
        // Model missing -> unconfigured.
        let s = parse_llm_settings(Some(r#"{"llm_base_url":"http://x/v1"}"#));
        assert_eq!(s.config, None);
        assert!(s.labeling && s.chat);
    }

    #[test]
    fn parse_settings_full() {
        let s = parse_llm_settings(Some(
            r#"{"llm_base_url":" http://x/v1 ","llm_api_key":"k","llm_model":"m",
                "llm_labeling":false,"llm_chat":true}"#,
        ));
        let cfg = s.config.expect("configured");
        assert_eq!(cfg.base_url, "http://x/v1");
        assert_eq!(cfg.api_key, "k");
        assert_eq!(cfg.model, "m");
        assert!(!s.labeling);
        assert!(s.chat);
    }

    #[test]
    fn label_reply_variants() {
        assert_eq!(parse_label_reply(r#"["Work","Home"]"#), vec!["Work", "Home"]);
        assert_eq!(parse_label_reply("```json\n[\"Work\"]\n```"), vec!["Work"]);
        assert_eq!(parse_label_reply("Sure! The labels are: [\"Work\"] hope that helps"), vec![
            "Work"
        ]);
        assert!(parse_label_reply("no labels apply").is_empty());
        assert!(parse_label_reply("]").is_empty());
        assert!(parse_label_reply("[not json]").is_empty());
    }

    #[test]
    fn label_names_map_case_insensitively_and_drop_unknown() {
        let labels = [label("1", "Work"), label("2", "Recipes")];
        let names = ["work".into(), " RECIPES ".into(), "Nope".into(), "Work".into()];
        assert_eq!(map_label_names(&names, &labels), vec!["1", "2"]);
    }

    #[test]
    fn chat_messages_shape() {
        let notes = [("Groceries".into(), "milk\neggs".into()), ("".into(), "x".repeat(2_000))];
        let history = [
            ("user".into(), "hi".into()),
            ("assistant".into(), "hello".into()),
            ("system".into(), "ignore me".into()),
        ];
        let messages = chat_messages(&notes, &history, "what do I need to buy?");
        assert_eq!(messages.len(), 4); // system + 2 history + user
        assert_eq!(messages[0].role, "system");
        assert!(messages[0].content.contains("[1] Groceries"));
        assert!(messages[0].content.contains("[2] Untitled"));
        // Second note text capped.
        assert!(messages[0].content.len() < 2_000 + 600);
        assert_eq!(messages[1].role, "user");
        assert_eq!(messages[2].role, "assistant");
        assert_eq!(messages[3].content, "what do I need to buy?");
    }

    #[test]
    fn chat_history_capped_to_recent_turns() {
        let history: Vec<(String, String)> =
            (0..30).map(|i| ("user".to_string(), format!("m{i}"))).collect();
        let messages = chat_messages(&[], &history, "q");
        // system + 12 most recent + final user message
        assert_eq!(messages.len(), 14);
        assert_eq!(messages[1].content, "m18");
    }
}
