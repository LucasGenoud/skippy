//! The LLM keys of a user's settings document: the provider, link
//! summaries, chat write permissions, and the rewrite tasks.

use serde::Deserialize;

use crate::llm::LlmConfig;

/// LLM-related keys parsed out of a user's settings document. The document is
/// otherwise client-owned and opaque; these keys are the shared contract with
/// the app's `SettingsStore`. Which features run is not here: that is each
/// workspace's switches (see `handlers::workspace_ai`).
#[derive(Debug, PartialEq)]
pub struct LlmSettings {
    /// Present only when base URL and model are both set.
    pub config: Option<LlmConfig>,
    /// Whether newly added links should be summarized into text/Markdown notes.
    pub auto_summarize_links: bool,
    pub link_summary_length: LinkSummaryLength,
    /// Optional user instructions shared by every AI feature.
    pub prompt: String,
    pub chat_create: bool,
    pub chat_edit: bool,
    pub chat_organize: bool,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum LinkSummaryLength {
    #[default]
    Short,
    Medium,
    Long,
}

impl LinkSummaryLength {
    pub fn prompt(self) -> &'static str {
        match self {
            Self::Short => "one or two very short sentences",
            Self::Medium => "a compact overview in three or four short sentences",
            Self::Long => "a detailed overview in up to six short paragraphs",
        }
    }

    pub fn max_chars(self) -> usize {
        match self {
            Self::Short => 500,
            Self::Medium => 1_000,
            Self::Long => 2_000,
        }
    }
}

/// Read the `llm_*` keys from a settings JSON document (as stored by
/// `put_settings`).
pub fn parse_llm_settings(settings_json: Option<&str>) -> LlmSettings {
    let value: serde_json::Value = settings_json
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default();
    parse_llm_settings_value(&value)
}

/// Same as [`parse_llm_settings`] but over an already-parsed document, used
/// after the server overlays its env-managed keys (see [`crate::config`]).
pub fn parse_llm_settings_value(value: &serde_json::Value) -> LlmSettings {
    let text = |key: &str| {
        value[key]
            .as_str()
            .map(str::trim)
            .unwrap_or_default()
            .to_string()
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
        auto_summarize_links: value["auto_summarize_links"] == true,
        link_summary_length: serde_json::from_value(value["link_summary_length"].clone())
            .unwrap_or_default(),
        prompt: text("llm_prompt"),
        chat_create: value["llm_chat_create"] != false,
        chat_edit: value["llm_chat_edit"] != false,
        chat_organize: value["llm_chat_organize"] != false,
    }
}

/// A rewrite task from the settings document: `name` labels it in the note
/// menu, `prompt` is what the model is told to do.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct RewriteTask {
    pub id: String,
    #[serde(default)]
    pub name: String,
    pub prompt: String,
}

/// Longest task instruction the server will send to a model.
const MAX_REWRITE_PROMPT_CHARS: usize = 4_000;

/// The rewrite tasks a settings document offers. A document that never set
/// any gets the two defaults; one that emptied its list gets none.
pub fn rewrite_tasks(settings: &serde_json::Value) -> Vec<RewriteTask> {
    let Some(tasks) = settings["llm_rewrite_tasks"].as_array() else {
        return default_rewrite_tasks();
    };
    tasks
        .iter()
        .filter_map(|value| serde_json::from_value::<RewriteTask>(value.clone()).ok())
        .map(|task| RewriteTask {
            id: task.id.trim().to_string(),
            name: task.name.trim().to_string(),
            prompt: task.prompt.trim().to_string(),
        })
        .filter(|task| {
            !task.id.is_empty()
                && !task.name.is_empty()
                && !task.prompt.is_empty()
                && task.prompt.chars().count() <= MAX_REWRITE_PROMPT_CHARS
        })
        .collect()
}

/// Mirrors the app's `kDefaultNoteRewriteTasks`.
fn default_rewrite_tasks() -> Vec<RewriteTask> {
    let task = |id: &str, name: &str, prompt: &str| RewriteTask {
        id: id.to_string(),
        name: name.to_string(),
        prompt: prompt.to_string(),
    };
    vec![
        task(
            "concise",
            "Make concise",
            "Clean up this note and make it concise. Preserve every important fact, intent, and task; do not add new information.",
        ),
        task(
            "grammar",
            "Fix grammar",
            "Fix grammar, spelling, punctuation, and syntax only. Do not summarize, rephrase for style, add information, remove information, or change tone.",
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_settings_absent_and_partial() {
        assert_eq!(parse_llm_settings(None).config, None);
        assert_eq!(parse_llm_settings(Some("not json")).config, None);
        // Model missing -> unconfigured.
        let s = parse_llm_settings(Some(r#"{"llm_base_url":"http://x/v1"}"#));
        assert_eq!(s.config, None);
    }

    #[test]
    fn parse_settings_full() {
        let s = parse_llm_settings(Some(
            r#"{"llm_base_url":" http://x/v1 ","llm_api_key":"k","llm_model":"m"}"#,
        ));
        let cfg = s.config.expect("configured");
        assert_eq!(cfg.base_url, "http://x/v1");
        assert_eq!(cfg.api_key, "k");
        assert_eq!(cfg.model, "m");
    }

    #[test]
    fn rewrite_tasks_default_until_the_list_is_set() {
        let names = |doc: serde_json::Value| -> Vec<String> {
            rewrite_tasks(&doc).into_iter().map(|t| t.name).collect()
        };
        assert_eq!(names(json!({})), ["Make concise", "Fix grammar"]);
        assert!(names(json!({"llm_rewrite_tasks": []})).is_empty());
        assert_eq!(
            names(json!({"llm_rewrite_tasks": [
                {"id": "a", "name": "Shorten", "prompt": "Shorter."},
                {"id": "b", "name": "", "prompt": "No name."},
                {"id": "c", "name": "Empty", "prompt": " "},
            ]})),
            ["Shorten"]
        );
    }
}
