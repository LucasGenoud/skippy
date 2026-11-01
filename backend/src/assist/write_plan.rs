//! Chat writes: the planner prompt that turns a request into one structured
//! edit, and the strict reading of the plan the model returns.

use super::{PromptNote, cap, custom_prompt, with_conversation};
use crate::llm::ChatMessage;

/// Max checklist entries a single write turn may add (guards against a
/// runaway model), and the per-entry length cap.
const MAX_WRITE_ITEMS: usize = 50;

const WRITE_ITEM_CHARS: usize = 200;
// Candidate notes are shown whole here too: the planner has to see everything
// a list already holds, or it appends a duplicate of an entry it never saw.

/// A concrete note edit the write planner resolved the user's request into.
#[derive(Debug, PartialEq)]
pub enum WriteAction {
    /// Make a brand-new note. `kind` is always "text" or "checklist".
    Create {
        kind: String,
        title: String,
        content: String,
        items: Vec<String>,
    },
    /// Add to an existing note; `note_id` is one of the retrieved candidates.
    Append {
        note_id: String,
        content: String,
        items: Vec<String>,
    },
    /// Replace editable text and/or change note organization.
    Update {
        note_id: String,
        title: Option<String>,
        content: Option<String>,
        items: Option<Vec<String>>,
        color: Option<String>,
        pinned: Option<bool>,
        archived: Option<bool>,
        trashed: Option<bool>,
        reminder_at: Option<Option<String>>,
        reminder_repeat: Option<Option<String>>,
    },
}

#[derive(Debug, Clone, Copy)]
pub struct WritePermissions {
    pub create: bool,
    pub edit: bool,
    pub organize: bool,
}

/// Prompt asking the model to turn a create/append request into one structured
/// edit. It sees the retrieved candidate notes (with ids) so it can choose to
/// add to one of them, and the conversation so references resolve. Kept as a
/// lenient JSON-reply prompt (like routing and labeling) so it needs no native
/// tool-calling support.
pub fn write_plan_messages(
    candidates: &[PromptNote],
    history: &[(String, String)],
    message: &str,
    permissions: WritePermissions,
    prompt: &str,
) -> Vec<ChatMessage> {
    let mut context = String::from(
        "You turn the user's request into a single change to their sticky \
         notes. Reply with ONLY one JSON object, no other text.\n\
         To create a new note:\n\
         {\"action\":\"create\",\"kind\":\"text\"|\"markdown\"|\"checklist\",\"title\":\"…\",\
         \"content\":\"…\",\"items\":[\"…\"]}\n\
         Use \"checklist\" with an \"items\" array for a list of things (to-dos, \
         shopping, steps); use \"text\" with \"content\" for prose. Keep \
         the title short; it may be empty. Include only the fields you need.\n\
         To add to an existing note listed below:\n\
         {\"action\":\"append\",\"note_id\":\"<id from the list>\",\"content\":\"…\",\
         \"items\":[\"…\"]}\n\
         Only append when the user clearly means one of the existing notes; put \
         new checklist entries in \"items\" and new prose in \"content\". If in \
         doubt, create a new note instead.\n\n\
         To change an existing note:\n\
         {\"action\":\"update\",\"note_id\":\"<id>\",\"title\":\"…\",\"content\":\"…\",\
         \"items\":[\"…\"],\"pinned\":true|false,\"archived\":true|false,\
         \"trashed\":true|false,\"color\":\"…\",\"reminder_at\":\"RFC3339\"|null,\
         \"reminder_repeat\":\"daily\"|\"weekly\"|\"monthly\"|\"yearly\"|null}\n\
         Include only fields the user requested. The items array is the full \
         replacement checklist. Never invent a note id.\n\n\
         Existing notes you may change:",
    );
    context.push_str(&format!(
        "\n\nCurrent UTC time: {}.\nAllowed changes: create={}, edit content={}, organize={}. Never plan a disabled change.",
        chrono::Utc::now().to_rfc3339(),
        permissions.create, permissions.edit, permissions.organize,
    ));
    context.push_str(&custom_prompt(prompt));
    if candidates.is_empty() {
        context.push_str("\n(none)");
    }
    for note in candidates {
        let title = if note.title.trim().is_empty() {
            "Untitled"
        } else {
            note.title.trim()
        };
        context.push_str(&format!("\n\n[id={}] {title}\n{}", note.id, note.text));
    }
    with_conversation(vec![ChatMessage::system(context)], history, message)
}

/// Collect a JSON value's `key` as a cleaned list of strings: trims, caps
/// length, drops blanks, and limits the count. Non-array or non-string
/// entries are ignored.
fn string_list(value: &serde_json::Value, key: &str) -> Vec<String> {
    value[key]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| v.as_str())
        .map(|s| cap(s.trim(), WRITE_ITEM_CHARS).to_string())
        .filter(|s| !s.is_empty())
        .take(MAX_WRITE_ITEMS)
        .collect()
}

/// Lenient parse of the write-planner reply into an executable action.
/// `None` means the reply was unusable (unparseable, unknown action, an
/// append to an unknown note, or an edit that adds nothing), the caller then
/// falls back to answering rather than writing something unintended.
pub fn parse_write_action(
    reply: &str,
    valid_ids: &[String],
    permissions: WritePermissions,
) -> Option<WriteAction> {
    let start = reply.find('{')?;
    let end = reply.rfind('}').filter(|&e| e > start)?;
    let value: serde_json::Value = serde_json::from_str(&reply[start..=end]).ok()?;
    let content = value["content"]
        .as_str()
        .map(str::trim)
        .unwrap_or_default()
        .to_string();
    let items = string_list(&value, "items");
    match value["action"].as_str()?.trim() {
        "create" => {
            if !permissions.create {
                return None;
            }
            let kind = match value["kind"].as_str().map(str::trim) {
                Some("checklist") => "checklist",
                Some("markdown") => "markdown",
                _ => "text",
            }
            .to_string();
            let title = value["title"]
                .as_str()
                .map(str::trim)
                .unwrap_or_default()
                .to_string();
            // A checklist with no items but some content is fine; a wholly
            // empty create is not worth a note.
            if title.is_empty() && content.is_empty() && items.is_empty() {
                return None;
            }
            Some(WriteAction::Create {
                kind,
                title,
                content,
                items,
            })
        }
        "append" => {
            if !permissions.edit {
                return None;
            }
            let note_id = value["note_id"].as_str()?.trim().to_string();
            if !valid_ids.iter().any(|id| id == &note_id) {
                return None; // hallucinated target, don't touch a random note
            }
            if content.is_empty() && items.is_empty() {
                return None;
            }
            Some(WriteAction::Append {
                note_id,
                content,
                items,
            })
        }
        "update" => {
            let note_id = value["note_id"].as_str()?.trim().to_string();
            if !valid_ids.iter().any(|id| id == &note_id) {
                return None;
            }
            let text = |key: &str| value.get(key).and_then(|v| v.as_str()).map(str::to_string);
            let title = text("title");
            let content = text("content");
            let items = value
                .get("items")
                .and_then(serde_json::Value::as_array)
                .filter(|items| items.iter().all(serde_json::Value::is_string))
                .map(|_| string_list(&value, "items"));
            if !permissions.edit && (title.is_some() || content.is_some() || items.is_some()) {
                return None;
            }
            let color = text("color");
            let pinned = value.get("pinned").and_then(|v| v.as_bool());
            let archived = value.get("archived").and_then(|v| v.as_bool());
            let trashed = value.get("trashed").and_then(|v| v.as_bool());
            let reminder_at = match value.get("reminder_at") {
                Some(serde_json::Value::Null) => Some(None),
                Some(serde_json::Value::String(v)) => Some(Some(v.clone())),
                _ => None,
            };
            let reminder_repeat = match value.get("reminder_repeat") {
                Some(serde_json::Value::Null) => Some(None),
                Some(serde_json::Value::String(v)) => Some(Some(v.clone())),
                _ => None,
            };
            if !permissions.organize
                && (color.is_some()
                    || pinned.is_some()
                    || archived.is_some()
                    || trashed.is_some()
                    || reminder_at.is_some()
                    || reminder_repeat.is_some())
            {
                return None;
            }
            if title.is_none()
                && content.is_none()
                && items.is_none()
                && color.is_none()
                && pinned.is_none()
                && archived.is_none()
                && trashed.is_none()
                && reminder_at.is_none()
                && reminder_repeat.is_none()
            {
                return None;
            }
            Some(WriteAction::Update {
                note_id,
                title,
                content,
                items,
                color,
                pinned,
                archived,
                trashed,
                reminder_at,
                reminder_repeat,
            })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all_writes() -> WritePermissions {
        WritePermissions {
            create: true,
            edit: true,
            organize: true,
        }
    }

    #[test]
    fn write_plan_messages_list_candidates_and_conversation() {
        let candidates = [PromptNote {
            id: "abc".into(),
            title: "Groceries".into(),
            text: "- [ ] milk".into(),
        }];
        let history = [("user".to_string(), "hi".to_string())];
        let messages = write_plan_messages(&candidates, &history, "add bread", all_writes(), "");
        assert_eq!(messages[0].role, "system");
        assert!(messages[0].content.contains("[id=abc] Groceries"));
        assert!(messages[0].content.contains("\"action\":\"append\""));
        assert_eq!(messages.last().unwrap().content, "add bread");
    }

    #[test]
    fn write_action_create_variants() {
        use WriteAction::*;
        assert_eq!(
            parse_write_action(
                r#"{"action":"create","kind":"checklist","title":"Groceries","items":["milk","eggs"]}"#,
                &[],
                all_writes(),
            ),
            Some(Create {
                kind: "checklist".into(),
                title: "Groceries".into(),
                content: String::new(),
                items: vec!["milk".into(), "eggs".into()],
            })
        );
        // Unknown kind clamps to text; fences and prose tolerated.
        assert_eq!(
            parse_write_action(
                "```json\n{\"action\":\"create\",\"kind\":\"audio\",\"content\":\"remember this\"}\n```",
                &[],
                all_writes(),
            ),
            Some(Create {
                kind: "text".into(),
                title: String::new(),
                content: "remember this".into(),
                items: vec![],
            })
        );
        // A wholly empty create is rejected.
        assert_eq!(
            parse_write_action(r#"{"action":"create"}"#, &[], all_writes()),
            None
        );
    }

    #[test]
    fn write_action_append_validates_target() {
        use WriteAction::*;
        let ids = ["abc".to_string()];
        assert_eq!(
            parse_write_action(
                r#"{"action":"append","note_id":"abc","items":["bread"]}"#,
                &ids,
                all_writes(),
            ),
            Some(Append {
                note_id: "abc".into(),
                content: String::new(),
                items: vec!["bread".into()],
            })
        );
        // Hallucinated target id -> no write.
        assert_eq!(
            parse_write_action(
                r#"{"action":"append","note_id":"zzz","items":["x"]}"#,
                &ids,
                all_writes(),
            ),
            None
        );
        // Append that adds nothing -> no write.
        assert_eq!(
            parse_write_action(r#"{"action":"append","note_id":"abc"}"#, &ids, all_writes(),),
            None
        );
        assert_eq!(parse_write_action("not json", &ids, all_writes()), None);
        assert_eq!(
            parse_write_action(r#"{"action":"delete"}"#, &ids, all_writes()),
            None
        );
    }

    #[test]
    fn write_action_update_respects_change_permissions() {
        use WriteAction::*;
        let ids = ["abc".to_string()];
        assert_eq!(
            parse_write_action(
                r#"{"action":"update","note_id":"abc","title":"New","pinned":true}"#,
                &ids,
                all_writes(),
            ),
            Some(Update {
                note_id: "abc".into(),
                title: Some("New".into()),
                content: None,
                items: None,
                color: None,
                pinned: Some(true),
                archived: None,
                trashed: None,
                reminder_at: None,
                reminder_repeat: None,
            })
        );
        assert_eq!(
            parse_write_action(
                r#"{"action":"update","note_id":"abc","pinned":true}"#,
                &ids,
                WritePermissions {
                    create: true,
                    edit: true,
                    organize: false,
                },
            ),
            None
        );
    }
}
