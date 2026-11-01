//! Notes chat: route a turn, build its retrieval query, and write the
//! prompts that answer over the retrieved notes or the conversation alone.

use super::{PromptNote, cap, custom_prompt, json_object, with_conversation};
use crate::llm::ChatMessage;
use crate::models::NoteRecord;

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
pub fn route_messages(
    history: &[(String, String)],
    message: &str,
    prompt: &str,
) -> Vec<ChatMessage> {
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
        ChatMessage::system(format!(
            "You route messages for an assistant over the user's personal \
             sticky notes. Decide what the LAST user message needs. Reply with \
             ONLY a JSON object, no other text:\n\
             {{\"search\": \"<query>\"}}, when answering needs their notes; \
             write a short standalone search query for what to look up, \
             resolving any references from the conversation.\n\
             {{\"search\": null}}, when the message needs no lookup (greetings, \
             thanks, chit-chat, or questions already answered in the \
             conversation).\n\
             {{\"write\": \"<topic>\"}}, when the user asks to CHANGE notes: \
             create, edit, append, pin, archive, trash, color, or schedule one \
             (\"make a list\", \"add milk\", \"pin my grocery list\"); set topic \
             to a few words describing the note's subject so an existing note \
             to change can be found.{}",
            custom_prompt(prompt)
        )),
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
    let object = json_object(reply)?;
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
        parts.push(format!(
            "- [{}] {}",
            if item.done { "x" } else { " " },
            item.text
        ));
    }
    parts.join("\n")
}

/// Build the RAG conversation: a system prompt embedding the retrieved notes,
/// then the (capped) history and the new user message. History roles other
/// than user/assistant are dropped.
pub fn chat_messages(
    notes: &[PromptNote],
    history: &[(String, String)], // (role, content)
    message: &str,
    prompt: &str,
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
    for (n, note) in notes.iter().enumerate() {
        let title = if note.title.trim().is_empty() {
            "Untitled"
        } else {
            note.title.trim()
        };
        context.push_str(&format!("\n\n[{}] {}\n{}", n + 1, title, note.text));
    }
    context.push_str(&custom_prompt(prompt));
    with_conversation(vec![ChatMessage::system(context)], history, message)
}

/// The no-lookup variant: the routing call decided this turn needs no notes,
/// so the model answers from the conversation alone (and must not pretend it
/// consulted anything).
pub fn chat_messages_direct(
    history: &[(String, String)],
    message: &str,
    prompt: &str,
) -> Vec<ChatMessage> {
    with_conversation(
        vec![ChatMessage::system(format!(
            "You are an assistant for the user's personal sticky notes app. \
             This turn needs no note lookup: answer from the conversation so \
             far. Anything you told the user earlier remains valid. Be \
             concise.{}",
            custom_prompt(prompt)
        ))],
        history,
        message,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(id: &str, title: &str, text: &str) -> PromptNote {
        PromptNote {
            id: id.into(),
            title: title.into(),
            text: text.into(),
        }
    }

    #[test]
    fn note_prompt_text_keeps_checklist_state() {
        use crate::models::ChecklistItem;
        let record = NoteRecord {
            collection_id: None,
            workspace_id: "w1".to_string(),
            id: "n1".into(),
            created_by: Some("u1".into()),
            kind: "checklist".into(),
            title: "Groceries".into(),
            content: String::new(),
            items: vec![
                ChecklistItem {
                    id: "i1".into(),
                    text: "bread".into(),
                    done: true,
                    depth: 0,
                },
                ChecklistItem {
                    id: "i2".into(),
                    text: "milk".into(),
                    done: false,
                    depth: 0,
                },
            ],
            color: "default".into(),
            pinned: false,
            archived: false,
            trashed: false,
            position: 0.0,
            grid_span: 1,
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
        let messages = chat_messages(&[note("n1", "Groceries", &text)], &[], "what's left?", "");
        let prompt = &messages[0].content;
        // The notes are the tail of the system prompt, so an intact list ends
        // it, anything dropped would have left the truncation marker here.
        assert!(
            prompt.trim_end().ends_with("- [ ] item 199"),
            "tail of the list was cut"
        );
    }

    #[test]
    fn route_messages_shape() {
        let history = [
            ("user".to_string(), "what should I buy?".to_string()),
            ("assistant".to_string(), "Bread and milk.".to_string()),
            ("system".to_string(), "dropped".to_string()),
        ];
        let messages = route_messages(&history, "and the plants?", "");
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
        assert_eq!(
            parse_route_reply(r#"{"write": "  ", "search": null}"#),
            Some(Direct)
        );
    }

    #[test]
    fn direct_chat_messages_have_no_notes_section() {
        let history = [("user".to_string(), "hi".to_string())];
        let messages = chat_messages_direct(&history, "thanks!", "");
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
        assert_eq!(
            retrieval_query(&history, "nice"),
            "what should I buy?\nnice"
        );
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
        let notes = [note("n1", "Groceries", "milk\neggs"), note("n2", "", &long)];
        let history = [
            ("user".into(), "hi".into()),
            ("assistant".into(), "hello".into()),
            ("system".into(), "ignore me".into()),
        ];
        let messages = chat_messages(&notes, &history, "what do I need to buy?", "");
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
        let history: Vec<(String, String)> = (0..30)
            .map(|i| ("user".to_string(), format!("m{i}")))
            .collect();
        let messages = chat_messages(&[], &history, "q", "");
        // system + 12 most recent + final user message
        assert_eq!(messages.len(), 14);
        assert_eq!(messages[1].content, "m18");
    }
}
