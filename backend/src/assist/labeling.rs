//! Auto-labeling: ask the model to pick from the workspace's own labels, and
//! read its answer back.

use super::{cap, custom_prompt, json_array};
use crate::llm::ChatMessage;
use crate::models::Label;

/// Max note text sent in a labeling prompt.
const LABELING_NOTE_CHARS: usize = 4_000;

/// Prompt asking the model to pick applicable labels for a note, strictly
/// from the user's existing label names.
pub fn labeling_messages(
    label_names: &[String],
    note_text: &str,
    prompt: &str,
) -> Vec<ChatMessage> {
    vec![
        ChatMessage::system(format!(
            "You assign labels to sticky notes. Reply with a JSON array of the \
             label names that clearly apply to the note, chosen only from the \
             provided list. Reply [] if none apply. Output the JSON array and \
             nothing else.{}",
            custom_prompt(prompt)
        )),
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
    json_array(reply)
        .and_then(|names| serde_json::from_value(serde_json::Value::Array(names)).ok())
        .unwrap_or_default()
}

/// Map model-suggested names onto the user's labels: case-insensitive,
/// trimmed; unknown names are dropped, duplicates collapse.
pub fn map_label_names(names: &[String], labels: &[Label]) -> Vec<String> {
    let mut ids = Vec::new();
    for name in names {
        let wanted = name.trim().to_lowercase();
        let Some(label) = labels
            .iter()
            .find(|l| l.name.trim().to_lowercase() == wanted)
        else {
            continue;
        };
        if !ids.contains(&label.id) {
            ids.push(label.id.clone());
        }
    }
    ids
}

#[cfg(test)]
mod tests {
    use super::*;

    fn label(id: &str, name: &str) -> Label {
        Label {
            id: id.into(),
            workspace_id: "w1".to_string(),
            name: name.into(),
            color: None,
            icon: None,
            position: 0.0,
        }
    }

    #[test]
    fn label_reply_variants() {
        assert_eq!(
            parse_label_reply(r#"["Work","Home"]"#),
            vec!["Work", "Home"]
        );
        assert_eq!(parse_label_reply("```json\n[\"Work\"]\n```"), vec!["Work"]);
        assert_eq!(
            parse_label_reply("Sure! The labels are: [\"Work\"] hope that helps"),
            vec!["Work"]
        );
        assert!(parse_label_reply("no labels apply").is_empty());
        assert!(parse_label_reply("]").is_empty());
        assert!(parse_label_reply("[not json]").is_empty());
    }

    #[test]
    fn label_names_map_case_insensitively_and_drop_unknown() {
        let labels = [label("1", "Work"), label("2", "Recipes")];
        let names = [
            "work".into(),
            " RECIPES ".into(),
            "Nope".into(),
            "Work".into(),
        ];
        assert_eq!(map_label_names(&names, &labels), vec!["1", "2"]);
    }
}
