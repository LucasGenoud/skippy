//! Pure helpers for the LLM features (auto-labeling and notes chat): parsing
//! the per-user LLM settings out of the opaque settings document, building
//! prompts, and interpreting model replies. Kept free of I/O so the handlers
//! stay thin and everything here is unit-testable.

use crate::llm::{ChatMessage, LlmConfig};
use crate::models::{Label, NoteRecord};

/// Max note text sent in a labeling prompt.
const LABELING_NOTE_CHARS: usize = 4_000;
/// Max history turns forwarded to the model.
const CHAT_HISTORY_TURNS: usize = 12;
/// Max chars per history entry and per user message.
const CHAT_MESSAGE_CHARS: usize = 4_000;
/// How many retrieved notes make it into the chat prompt. This is the only
/// bound on the notes side: a retrieved note is sent whole, here and in the
/// write planner, because any cut still reads as a *complete* note and the
/// model then answers confidently about a list whose tail it never saw.
/// Long notes are the user's own, and one truthful answer beats a cheap one.
pub const CHAT_CONTEXT_NOTES: usize = 8;
/// How many recent user turns (including the new message) feed retrieval.
const RETRIEVAL_QUERY_TURNS: usize = 3;
/// Max chars each turn contributes to the retrieval query.
const RETRIEVAL_TURN_CHARS: usize = 300;
/// How many history entries the routing call sees (it only needs enough to
/// resolve references like "and the plants?").
const ROUTE_HISTORY_TURNS: usize = 6;
/// Max chars per history entry in the routing prompt.
const ROUTE_MESSAGE_CHARS: usize = 500;

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
    /// Note cleanup and grammar-correction toggle; defaults off because these
    /// actions directly change note content.
    pub writing: bool,
}

/// Read `llm_base_url` / `llm_api_key` / `llm_model` / `llm_labeling` /
/// `llm_chat` / `llm_writing` from a settings JSON document (as stored by
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
        writing: value["llm_writing"] == true,
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

/// What the routing call decided about a chat turn.
#[derive(Debug, PartialEq)]
pub enum RouteDecision {
    /// Look notes up with the model's own standalone query.
    Search(String),
    /// The turn needs no notes (thanks, greetings, follow-ups on what was
    /// already said), answer from the conversation alone.
    Direct,
    /// The user asked to create a new note or add to an existing one. The
    /// string is a short topic query used to retrieve candidate notes to
    /// append to (and it also grounds the create). Actually building the
    /// note is a second, structured call ([`write_plan_messages`]).
    Write(String),
}

/// Prompt asking the model to route a chat turn: decide whether answering
/// needs the user's notes and, if so, write the search query itself. The
/// model resolves conversational references ("and the plants?"), so the
/// query works even when the message alone carries no subject. Kept as a
/// plain JSON-reply prompt (like labeling) rather than native tool calls so
/// it works on any OpenAI-compatible server and model.
pub fn route_messages(history: &[(String, String)], message: &str) -> Vec<ChatMessage> {
    let mut conversation = String::new();
    let skip = history.len().saturating_sub(ROUTE_HISTORY_TURNS);
    for (role, content) in &history[skip..] {
        let who = match role.as_str() {
            "user" => "User",
            "assistant" => "Assistant",
            _ => continue,
        };
        conversation.push_str(&format!("{who}: {}\n", cap(content, ROUTE_MESSAGE_CHARS)));
    }
    conversation.push_str(&format!("User: {}", cap(message, ROUTE_MESSAGE_CHARS)));
    vec![
        ChatMessage::system(
            "You route messages for an assistant over the user's personal \
             sticky notes. Decide what the LAST user message needs. Reply with \
             ONLY a JSON object, no other text:\n\
             {\"search\": \"<query>\"}, when answering needs their notes; \
             write a short standalone search query for what to look up, \
             resolving any references from the conversation.\n\
             {\"search\": null}, when the message needs no lookup (greetings, \
             thanks, chit-chat, or questions already answered in the \
             conversation).\n\
             {\"write\": \"<topic>\"}, when the user asks to CREATE a new note \
             or ADD something to a note (\"make a list\", \"add milk to my \
             groceries\", \"save this as a note\", \"note down …\"); set topic \
             to a few words describing the note's subject so an existing note \
             to add to can be found.",
        ),
        ChatMessage::user(conversation),
    ]
}

/// Lenient parse of the routing reply: tolerates code fences and prose around
/// the JSON object. `None` means unparseable, the caller should fall back to
/// plain retrieval rather than trust the model had no need for notes. A
/// non-empty `write` string routes to the write path; otherwise the `search`
/// key must be PRESENT (a wrong-shape object is not a decision), with `null`
/// or a blank query meaning no lookup.
pub fn parse_route_reply(reply: &str) -> Option<RouteDecision> {
    let start = reply.find('{')?;
    let end = reply.rfind('}').filter(|&e| e > start)?;
    let value: serde_json::Value = serde_json::from_str(&reply[start..=end]).ok()?;
    let object = value.as_object()?;
    // A write intent wins: the user asked to change their notes, not just read.
    if let Some(serde_json::Value::String(topic)) = object.get("write")
        && !topic.trim().is_empty()
    {
        return Some(RouteDecision::Write(topic.trim().to_string()));
    }
    Some(match object.get("search")? {
        serde_json::Value::Null => RouteDecision::Direct,
        serde_json::Value::String(query) => match query.trim() {
            "" => RouteDecision::Direct,
            query => RouteDecision::Search(query.to_string()),
        },
        _ => return None,
    })
}

/// The text embedded for retrieval on a chat turn. Low-content follow-ups
/// ("nice", "why?") carry none of the conversation's subject, so embedding
/// them alone surfaces junk, and the junk then replaces the notes the
/// previous answer was grounded in, confusing the model. Blend the last few
/// user turns (oldest first, new message last) so the topic sticks.
/// Used as the fallback when the routing call fails or is unparseable.
pub fn retrieval_query(history: &[(String, String)], message: &str) -> String {
    let mut turns: Vec<&str> = history
        .iter()
        .rev()
        .filter(|(role, _)| role == "user")
        .take(RETRIEVAL_QUERY_TURNS - 1)
        .map(|(_, content)| content.as_str())
        .collect();
    turns.reverse();
    turns.push(message);
    turns
        .into_iter()
        .map(|t| cap(t.trim(), RETRIEVAL_TURN_CHARS))
        .filter(|t| !t.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

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
    Create { kind: String, title: String, content: String, items: Vec<String> },
    /// Add to an existing note; `note_id` is one of the retrieved candidates.
    Append { note_id: String, content: String, items: Vec<String> },
}

/// Prompt asking the model to turn a create/append request into one structured
/// edit. It sees the retrieved candidate notes (with ids) so it can choose to
/// add to one of them, and the conversation so references resolve. Kept as a
/// lenient JSON-reply prompt (like routing and labeling) so it needs no native
/// tool-calling support.
pub fn write_plan_messages(
    candidates: &[(String, String, String)], // (id, title, text)
    history: &[(String, String)],
    message: &str,
) -> Vec<ChatMessage> {
    let mut context = String::from(
        "You turn the user's request into a single change to their sticky \
         notes. Reply with ONLY one JSON object, no other text.\n\
         To create a new note:\n\
         {\"action\":\"create\",\"kind\":\"text\"|\"checklist\",\"title\":\"…\",\
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
         Existing notes you may add to:",
    );
    if candidates.is_empty() {
        context.push_str("\n(none)");
    }
    for (id, title, text) in candidates {
        let title = if title.trim().is_empty() { "Untitled" } else { title.trim() };
        context.push_str(&format!("\n\n[id={id}] {title}\n{text}"));
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
pub fn parse_write_action(reply: &str, valid_ids: &[String]) -> Option<WriteAction> {
    let start = reply.find('{')?;
    let end = reply.rfind('}').filter(|&e| e > start)?;
    let value: serde_json::Value = serde_json::from_str(&reply[start..=end]).ok()?;
    let content = value["content"].as_str().map(str::trim).unwrap_or_default().to_string();
    let items = string_list(&value, "items");
    match value["action"].as_str()?.trim() {
        "create" => {
            let kind = match value["kind"].as_str().map(str::trim) {
                Some("checklist") => "checklist",
                _ => "text",
            }
            .to_string();
            let title =
                value["title"].as_str().map(str::trim).unwrap_or_default().to_string();
            // A checklist with no items but some content is fine; a wholly
            // empty create is not worth a note.
            if title.is_empty() && content.is_empty() && items.is_empty() {
                return None;
            }
            Some(WriteAction::Create { kind, title, content, items })
        }
        "append" => {
            let note_id = value["note_id"].as_str()?.trim().to_string();
            if !valid_ids.iter().any(|id| id == &note_id) {
                return None; // hallucinated target, don't touch a random note
            }
            if content.is_empty() && items.is_empty() {
                return None;
            }
            Some(WriteAction::Append { note_id, content, items })
        }
        _ => None,
    }
}

/// Render a note's body for the chat prompt (the title is printed by
/// [`chat_messages`]). Unlike the embedding text ([`SearchService::note_text`]
/// flattens item texts), checklist items keep their checked state, the model
/// must be able to tell what's done from what's still pending, or it reads a
/// half-finished grocery list as all still to buy.
///
/// [`SearchService::note_text`]: crate::search::SearchService::note_text
pub fn note_prompt_text(record: &NoteRecord) -> String {
    let mut parts: Vec<String> = Vec::new();
    let content = record.content.trim();
    if !content.is_empty() {
        parts.push(content.to_string());
    }
    for item in &record.items {
        parts.push(format!("- [{}] {}", if item.done { "x" } else { " " }, item.text));
    }
    parts.join("\n")
}

/// Build the RAG conversation: a system prompt embedding the retrieved notes,
/// then the (capped) history and the new user message. History roles other
/// than user/assistant are dropped.
pub fn chat_messages(
    notes: &[(String, String)], // (title, text)
    history: &[(String, String)], // (role, content)
    message: &str,
) -> Vec<ChatMessage> {
    // The notes are looked up per turn against that turn's query, so they
    // must read as *possible* context, never as the whole collection,
    // otherwise a turn whose lookup surfaced different notes makes the model
    // disavow its own previous (correctly grounded) answer.
    let mut context = String::from(
        "You are an assistant for the user's personal sticky notes app. Below \
         is a selection of their notes looked up as possible context for the \
         latest message; it is not their whole collection, and some notes may \
         be irrelevant, silently ignore those. Checklist items are marked \
         '- [x]' when checked off (done, already bought/handled) and '- [ ]' \
         when still pending; treat only pending items as open tasks. Each note \
         is shown in full, so a list you can see the end of is the whole list. \
         Answer using the relevant notes and the conversation so far. Never \
         claim an \
         earlier answer was wrong merely because the notes shown this turn \
         don't repeat it. If neither the notes nor the conversation covers \
         the question, say so plainly. Be concise.\n\nNotes:",
    );
    if notes.is_empty() {
        context.push_str("\n(none found)");
    }
    for (n, (title, text)) in notes.iter().enumerate() {
        let title = if title.trim().is_empty() { "Untitled" } else { title.trim() };
        context.push_str(&format!("\n\n[{}] {}\n{}", n + 1, title, text));
    }
    with_conversation(vec![ChatMessage::system(context)], history, message)
}

/// The no-lookup variant: the routing call decided this turn needs no notes,
/// so the model answers from the conversation alone (and must not pretend it
/// consulted anything).
pub fn chat_messages_direct(history: &[(String, String)], message: &str) -> Vec<ChatMessage> {
    with_conversation(
        vec![ChatMessage::system(
            "You are an assistant for the user's personal sticky notes app. \
             This turn needs no note lookup: answer from the conversation so \
             far. Anything you told the user earlier remains valid. Be \
             concise.",
        )],
        history,
        message,
    )
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
    messages.push(ChatMessage::user(cap(message, CHAT_MESSAGE_CHARS).to_string()));
    messages
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
    fn note_prompt_text_keeps_checklist_state() {
        use crate::models::ChecklistItem;
        let record = NoteRecord {
            workspace_id: "w1".to_string(),
            id: "n1".into(),
            created_by: Some("u1".into()),
            kind: "checklist".into(),
            title: "Groceries".into(),
            content: String::new(),
            items: vec![
                ChecklistItem { id: "i1".into(), text: "bread".into(), done: true, depth: 0 },
                ChecklistItem { id: "i2".into(), text: "milk".into(), done: false, depth: 0 },
            ],
            color: "default".into(),
            pinned: false,
            archived: false,
            trashed: false,
            position: 0.0,
            reminder_at: None,
            reminder_repeat: None,
            reminder_fired_at: None,
            transcript_status: "none".into(),
            created_at: String::new(),
            updated_at: String::new(),
            last_editor_id: None,
            stage_id: None,
            stage_position: 0.0,
        };
        // Checked stays visibly checked, the model must not re-list it as
        // still to buy.
        assert_eq!(note_prompt_text(&record), "- [x] bread\n- [ ] milk");

        let text_note = NoteRecord {
            kind: "text".into(),
            content: "  hello  ".into(),
            items: Vec::new(),
            ..record
        };
        assert_eq!(note_prompt_text(&text_note), "hello");
    }

    #[test]
    fn long_checklists_survive_the_chat_prompt() {
        // 200 items is well past the old 1_500-char cap and still lands whole.
        let list: Vec<String> = (0..200).map(|n| format!("- [ ] item {n}")).collect();
        let text = list.join("\n");
        let messages = chat_messages(&[("Groceries".into(), text.clone())], &[], "what's left?");
        let prompt = &messages[0].content;
        // The notes are the tail of the system prompt, so an intact list ends
        // it, anything dropped would have left the truncation marker here.
        assert!(prompt.trim_end().ends_with("- [ ] item 199"), "tail of the list was cut");
    }

    #[test]
    fn route_messages_shape() {
        let history = [
            ("user".to_string(), "what should I buy?".to_string()),
            ("assistant".to_string(), "Bread and milk.".to_string()),
            ("system".to_string(), "dropped".to_string()),
        ];
        let messages = route_messages(&history, "and the plants?");
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].role, "system");
        assert!(messages[0].content.contains(r#"{"search":"#));
        let convo = &messages[1].content;
        assert!(convo.contains("User: what should I buy?"), "{convo}");
        assert!(convo.contains("Assistant: Bread and milk."), "{convo}");
        assert!(!convo.contains("dropped"), "{convo}");
        assert!(convo.ends_with("User: and the plants?"), "{convo}");
    }

    #[test]
    fn route_reply_variants() {
        use RouteDecision::*;
        assert_eq!(
            parse_route_reply(r#"{"search": "grocery list"}"#),
            Some(Search("grocery list".into()))
        );
        assert_eq!(parse_route_reply(r#"{"search": null}"#), Some(Direct));
        // Blank query means nothing to look up.
        assert_eq!(parse_route_reply(r#"{"search": "  "}"#), Some(Direct));
        // Fences and prose around the JSON are tolerated.
        assert_eq!(
            parse_route_reply("```json\n{\"search\": \"plants\"}\n```"),
            Some(Search("plants".into()))
        );
        assert_eq!(
            parse_route_reply("Sure! {\"search\": null}, no lookup needed."),
            Some(Direct)
        );
        // Unparseable replies must NOT read as Direct: the caller falls back
        // to plain retrieval instead of skipping notes on a hunch.
        assert_eq!(parse_route_reply("I think we should search"), None);
        assert_eq!(parse_route_reply("{\"query\": \"wrong shape\"}"), None);
        assert_eq!(parse_route_reply("{broken json"), None);
    }

    #[test]
    fn route_reply_write_variant() {
        use RouteDecision::*;
        assert_eq!(
            parse_route_reply(r#"{"write": "groceries"}"#),
            Some(Write("groceries".into()))
        );
        // A write intent wins even if a search key is also present.
        assert_eq!(
            parse_route_reply(r#"{"search": "x", "write": "shopping list"}"#),
            Some(Write("shopping list".into()))
        );
        // A blank write falls through to the search decision.
        assert_eq!(parse_route_reply(r#"{"write": "  ", "search": null}"#), Some(Direct));
    }

    #[test]
    fn write_plan_messages_list_candidates_and_conversation() {
        let candidates = [("abc".into(), "Groceries".into(), "- [ ] milk".into())];
        let history = [("user".to_string(), "hi".to_string())];
        let messages = write_plan_messages(&candidates, &history, "add bread");
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
            ),
            Some(Create {
                kind: "text".into(),
                title: String::new(),
                content: "remember this".into(),
                items: vec![],
            })
        );
        // A wholly empty create is rejected.
        assert_eq!(parse_write_action(r#"{"action":"create"}"#, &[]), None);
    }

    #[test]
    fn write_action_append_validates_target() {
        use WriteAction::*;
        let ids = ["abc".to_string()];
        assert_eq!(
            parse_write_action(
                r#"{"action":"append","note_id":"abc","items":["bread"]}"#,
                &ids,
            ),
            Some(Append {
                note_id: "abc".into(),
                content: String::new(),
                items: vec!["bread".into()],
            })
        );
        // Hallucinated target id -> no write.
        assert_eq!(
            parse_write_action(r#"{"action":"append","note_id":"zzz","items":["x"]}"#, &ids),
            None
        );
        // Append that adds nothing -> no write.
        assert_eq!(
            parse_write_action(r#"{"action":"append","note_id":"abc"}"#, &ids),
            None
        );
        assert_eq!(parse_write_action("not json", &ids), None);
        assert_eq!(parse_write_action(r#"{"action":"delete"}"#, &ids), None);
    }

    #[test]
    fn direct_chat_messages_have_no_notes_section() {
        let history = [("user".to_string(), "hi".to_string())];
        let messages = chat_messages_direct(&history, "thanks!");
        assert_eq!(messages.len(), 3);
        assert!(!messages[0].content.contains("Notes:"));
        assert_eq!(messages[2].content, "thanks!");
    }

    #[test]
    fn retrieval_query_blends_recent_user_turns() {
        let history = [
            ("user".to_string(), "what should I buy?".to_string()),
            ("assistant".to_string(), "Bread and milk.".to_string()),
        ];
        // The follow-up alone would embed to junk; the prior question rides
        // along, oldest first.
        assert_eq!(retrieval_query(&history, "nice"), "what should I buy?\nnice");
    }

    #[test]
    fn retrieval_query_takes_only_the_last_user_turns() {
        let history: Vec<(String, String)> = (0..5)
            .flat_map(|i| {
                [
                    ("user".to_string(), format!("q{i}")),
                    ("assistant".to_string(), format!("a{i}")),
                ]
            })
            .collect();
        // 3 turns total: the two most recent history questions + the message.
        assert_eq!(retrieval_query(&history, "q5"), "q3\nq4\nq5");
    }

    #[test]
    fn retrieval_query_caps_and_skips_empty() {
        assert_eq!(retrieval_query(&[], "  hi  "), "hi");
        let history = [("user".to_string(), "x".repeat(1_000))];
        let query = retrieval_query(&history, "q");
        assert_eq!(query.len(), 300 + 1 + 1); // capped turn + newline + "q"
        assert_eq!(retrieval_query(&[("user".into(), "  ".into())], "q"), "q");
    }

    #[test]
    fn chat_messages_shape() {
        let long = "x".repeat(20_000);
        let notes = [("Groceries".into(), "milk\neggs".into()), ("".into(), long.clone())];
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
        // However long the note, it reaches the model whole.
        assert!(messages[0].content.contains(&long));
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
