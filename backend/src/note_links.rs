//! Links between notes, written into note text as `[[id|Title]]`.
//!
//! The client owns the syntax (`app/lib/state/note_links.dart`); the server
//! only reads it, to show links as their titles to the embedder and the LLM,
//! and to point copied notes at each other.

use std::collections::HashMap;

const UUID_LEN: usize = 36;

pub struct NoteLink<'a> {
    /// Byte bounds of the whole token.
    pub start: usize,
    pub end: usize,
    pub note_id: &'a str,
    pub title: &'a str,
}

/// Every link in `text`, in order.
pub fn find(text: &str) -> Vec<NoteLink<'_>> {
    let mut links = Vec::new();
    let mut from = 0;
    while let Some(offset) = text[from..].find("[[") {
        let start = from + offset;
        match parse_at(text, start) {
            Some(link) => {
                from = link.end;
                links.push(link);
            }
            None => from = start + 1,
        }
    }
    links
}

/// The link starting at `start`, which holds `[[`, if it is one.
fn parse_at(text: &str, start: usize) -> Option<NoteLink<'_>> {
    let id_start = start + 2;
    let id_end = id_start + UUID_LEN;
    let note_id = text.get(id_start..id_end)?;
    if !note_id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
        return None;
    }
    let rest = text.get(id_end..)?.strip_prefix('|')?;
    let title_len = rest.find(['[', ']', '\n'])?;
    if !rest[title_len..].starts_with("]]") {
        return None;
    }
    let title_start = id_end + 1;
    Some(NoteLink {
        start,
        end: title_start + title_len + 2,
        note_id,
        title: &rest[..title_len],
    })
}

/// Rebuilds `text` with each link replaced by `replace(link)`.
fn rewrite(text: &str, replace: impl Fn(&NoteLink) -> String) -> String {
    let mut out = String::with_capacity(text.len());
    let mut cursor = 0;
    for link in find(text) {
        out.push_str(&text[cursor..link.start]);
        out.push_str(&replace(&link));
        cursor = link.end;
    }
    out.push_str(&text[cursor..]);
    out
}

/// `text` as a reader sees it: each link is its title.
pub fn plain_text(text: &str) -> String {
    rewrite(text, |link| link.title.to_string())
}

/// `text` with links to a key of `ids` pointing at its value instead, so
/// copied notes link to each other rather than back to their sources.
pub fn remap(text: &str, ids: &HashMap<String, String>) -> String {
    rewrite(text, |link| match ids.get(link.note_id) {
        Some(target) => format!("[[{target}|{}]]", link.title),
        None => text[link.start..link.end].to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "11111111-1111-4111-8111-111111111111";
    const B: &str = "22222222-2222-4222-8222-222222222222";

    #[test]
    fn finds_links_and_skips_lookalikes() {
        let text = format!("[[{A}|Groceries]] [[Plain]] [[{B}|x\n]] é [[{B}|Trip]]");
        let links = find(&text);

        assert_eq!(links.len(), 2);
        assert_eq!((links[0].note_id, links[0].title), (A, "Groceries"));
        assert_eq!((links[1].note_id, links[1].title), (B, "Trip"));
    }

    #[test]
    fn plain_text_shows_titles() {
        assert_eq!(
            plain_text(&format!("see [[{A}|Groceries]].")),
            "see Groceries."
        );
    }

    #[test]
    fn remap_follows_copies_only() {
        let ids = HashMap::from([(A.to_string(), B.to_string())]);
        let text = format!("[[{A}|A]] [[{B}|B]]");

        assert_eq!(remap(&text, &ids), format!("[[{B}|A]] [[{B}|B]]"));
    }
}
