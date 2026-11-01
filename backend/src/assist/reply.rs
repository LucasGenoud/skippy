//! Reading what a model sends back. Asked for bare JSON, models still wrap it:
//! in their reasoning, in a code fence, between sentences of prose. Every
//! reply parser starts here, so each tolerates the same wrappings.
//!
//! ```text
//! <think>…</think>          reasoning, dropped
//! Sure, here it is:         prose, skipped
//! ```json                   fence, skipped
//! {"title": "…"}            the first value that parses is the answer
//! ```
//! ```

use serde_json::{Map, Value};

/// The tags reasoning models wrap their thinking in.
const REASONING_TAGS: [(&str, &str); 2] = [("<think>", "</think>"), ("<thinking>", "</thinking>")];

/// How many opening brackets a reply may have before the answer starts. Bounds
/// the work a long, bracket-heavy reply costs.
const MAX_JSON_STARTS: usize = 64;

/// The model's answer without the reasoning some models put first. Some
/// servers drop the opening tag and send only the closing one, so the answer
/// is whatever follows the last closing tag. A reply that opens a reasoning
/// block and never closes it was cut off while thinking: it has no answer.
pub fn model_answer(reply: &str) -> &str {
    let reply = reply.trim();
    for (open, close) in REASONING_TAGS {
        if let Some(end) = reply.rfind(close) {
            return reply[end + close.len()..].trim();
        }
        if reply.starts_with(open) {
            return "";
        }
    }
    reply
}

/// The first JSON object in a reply, wherever the model put it.
pub fn json_object(reply: &str) -> Option<Map<String, Value>> {
    match first_json(reply, '{', Value::is_object)? {
        Value::Object(object) => Some(object),
        _ => None,
    }
}

/// The first JSON array in a reply, wherever the model put it.
pub fn json_array(reply: &str) -> Option<Vec<Value>> {
    match first_json(reply, '[', Value::is_array)? {
        Value::Array(values) => Some(values),
        _ => None,
    }
}

/// Tries each `open` bracket in turn and keeps the first complete value of the
/// wanted shape; whatever follows it is ignored.
fn first_json(reply: &str, open: char, wanted: fn(&Value) -> bool) -> Option<Value> {
    let answer = model_answer(reply);
    answer
        .match_indices(open)
        .take(MAX_JSON_STARTS)
        .find_map(|(start, _)| {
            let mut values = serde_json::Deserializer::from_str(&answer[start..]).into_iter();
            values.next()?.ok().filter(wanted)
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reasoning_is_not_part_of_the_answer() {
        assert_eq!(
            model_answer("<think>hmm {x}</think>\n\nThe answer."),
            "The answer."
        );
        assert_eq!(
            model_answer("<thinking>a</thinking>The answer."),
            "The answer."
        );
        // Opening tag dropped by the server.
        assert_eq!(model_answer("hmm, so…</think>The answer."), "The answer.");
        // Cut off mid-thought.
        assert_eq!(model_answer("<think>still going"), "");
        assert_eq!(model_answer("  Plain answer.  "), "Plain answer.");
    }

    #[test]
    fn an_object_is_found_however_it_is_wrapped() {
        let wrapped = [
            r#"{"a": 1}"#,
            "```json\n{\"a\": 1}\n```",
            "```JSON\n{\"a\": 1}\n```",
            "Sure! Here it is:\n{\"a\": 1}\nAnything else? {}",
            "<think>{\"a\": 2} maybe</think>{\"a\": 1}",
            "Note: {not json} but {\"a\": 1}",
        ];
        for reply in wrapped {
            assert_eq!(json_object(reply).unwrap()["a"], 1, "{reply}");
        }
        assert_eq!(json_object("no json here"), None);
        assert_eq!(json_object(r#"{"a": 1"#), None);
    }

    #[test]
    fn an_array_is_found_however_it_is_wrapped() {
        assert_eq!(json_array(r#"Labels: ["a", "b"]."#).unwrap().len(), 2);
        assert_eq!(json_array("<think>[x]</think>[\"a\"]").unwrap().len(), 1);
        assert_eq!(json_array("[broken"), None);
    }
}
