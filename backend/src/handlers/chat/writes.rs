//! The chat write path: a planned create, append or update applied through
//! the same pipelines as an ordinary edit, and the frames that confirm it.

use super::*;

/// A write a turn applied: which kind, the note as it now stands, the sentence
/// that confirms it, and the patch that would undo it.
pub(super) struct AppliedWrite {
    action: &'static str,
    view: NoteView,
    confirmation: String,
    undo: serde_json::Value,
}

/// The chat write path: ask the model to turn the user's create/append request
/// into one structured edit ([`assist::write_plan_messages`]) and apply it
/// through the shared create/update pipeline, so it gets indexing,
/// auto-labeling, version history, and the WS refresh nudge.
///
/// `Ok(None)` means the plan was unusable (timeout, unparseable, or a
/// hallucinated target) and the caller should answer over the retrieved notes
/// instead of writing something the user didn't ask for. An `Err` is a write
/// that was planned and failed.
pub(super) async fn write_from_plan(
    state: &AppState,
    turn: &TurnContext<'_>,
    candidates: &[PromptNote],
    history: &[(String, String)],
    message: &str,
    place: &str,
) -> Result<Option<AppliedWrite>, TurnError> {
    let planner =
        assist::write_plan_messages(candidates, history, message, turn.permissions, turn.prompt);
    let planner = extend_system(planner, place);
    let planning = state.llm.complete(turn.cfg, planner);
    let Ok(Ok(reply)) = tokio::time::timeout(PLANNING_TIMEOUT, planning).await else {
        return Ok(None);
    };
    let candidate_ids: Vec<String> = candidates.iter().map(|note| note.id.clone()).collect();
    let Some(action) = assist::parse_write_action(&reply, &candidate_ids, turn.permissions) else {
        return Ok(None);
    };

    match action {
        WriteAction::Create {
            kind,
            title,
            content,
            items,
            labels,
            collection,
        } => {
            let filing = Filing { labels, collection };
            create_from_plan(state, turn, kind, title, content, items, filing)
                .await
                .map(Some)
        }
        WriteAction::Append {
            note_id,
            content,
            items,
        } => append_from_plan(state, turn, &note_id, content, items).await,
        WriteAction::Update {
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
            add_labels,
            remove_labels,
            collection,
        } => {
            let refile = Refile {
                add_labels,
                remove_labels,
                collection,
            };
            let patch = UpdateNote {
                title,
                content,
                color,
                pinned,
                archived,
                trashed,
                reminder_at,
                reminder_repeat,
                ..Default::default()
            };
            update_from_plan(state, turn, &note_id, items, refile, patch).await
        }
    }
}

/// Where a planned note goes: label names and a collection by name or id.
struct Filing {
    labels: Vec<String>,
    collection: Option<String>,
}

/// A planned change of labels or collection on an existing note.
struct Refile {
    add_labels: Vec<String>,
    remove_labels: Vec<String>,
    collection: Option<String>,
}

async fn create_from_plan(
    state: &AppState,
    turn: &TurnContext<'_>,
    kind: String,
    title: String,
    content: String,
    items: Vec<String>,
    filing: Filing,
) -> Result<AppliedWrite, TurnError> {
    let is_checklist = kind == KIND_CHECKLIST;
    let (content, item_structs) = if is_checklist {
        let structs: Vec<ChecklistItem> = items
            .iter()
            .map(|text| ChecklistItem {
                id: new_id(),
                text: text.clone(),
                done: false,
                // The assistant writes a flat list; nesting is the reader's
                // to add.
                depth: 0,
            })
            .collect();
        (content, structs)
    } else {
        // A text note can't render checklist rows, so fold any items the
        // model produced into the body, nothing is lost.
        let mut body = content;
        for item in &items {
            if !body.is_empty() {
                body.push('\n');
            }
            body.push_str(item);
        }
        (body, Vec::new())
    };
    let n = item_structs.len();
    // Labels and a named collection resolve only inside the open workspace;
    // without one, the note keeps the create pipeline's defaults.
    let (collection_id, label_ids) = match turn.workspace_id {
        Some(w) => {
            let named = filing
                .collection
                .as_deref()
                .and_then(|c| turn.taxonomy.collection_id(w, c));
            let labels = turn.taxonomy.label_ids(w, &filing.labels);
            (
                named.or(turn.collection_id.map(str::to_owned)),
                (!labels.is_empty()).then_some(labels),
            )
        }
        None => (None, None),
    };
    let body = CreateNote {
        kind: Some(kind),
        title,
        content,
        items: (!item_structs.is_empty()).then_some(item_structs),
        // The note belongs where the user is looking; absent, the create
        // pipeline falls back to their default workspace.
        workspace_id: turn.workspace_id.map(str::to_owned),
        collection_id,
        label_ids,
        ..Default::default()
    };
    let view = create_note_for_user(state, turn.user_id, body)
        .await
        .map_err(|_| "could not create the note")?;
    let confirmation = if is_checklist {
        format!(
            "Created a checklist{} with {n} item{}.",
            titled(&view.note.title),
            plural(n)
        )
    } else {
        format!("Created a note{}.", titled(&view.note.title))
    };
    let undo = if view.owner.id == turn.user_id {
        serde_json::json!({"trashed": true, "pinned": false})
    } else {
        // Workspace members may create and archive notes, but only the
        // workspace owner controls trash.
        serde_json::json!({"archived": true, "pinned": false})
    };
    Ok(AppliedWrite {
        action: "create",
        view,
        confirmation,
        undo,
    })
}

/// `None` when the note vanished since retrieval, or the plan adds nothing.
async fn append_from_plan(
    state: &AppState,
    turn: &TurnContext<'_>,
    note_id: &str,
    content: String,
    items: Vec<String>,
) -> Result<Option<AppliedWrite>, TurnError> {
    let Ok(Some(record)) = state.repo.note_record_for_user(note_id, turn.user_id).await else {
        return Ok(None);
    };
    if holds_data(&record.kind) {
        return Ok(None);
    }
    let is_checklist = record.kind == KIND_CHECKLIST;
    let mut body = UpdateNote::default();
    let mut added = 0usize;
    if is_checklist && !items.is_empty() {
        let mut merged = record.items.clone();
        for text in &items {
            merged.push(ChecklistItem {
                id: new_id(),
                text: text.clone(),
                done: false,
                depth: 0,
            });
        }
        added = items.len();
        body.items = Some(merged);
    }

    // New prose (and, on a text note, any items) append to the body.
    let mut extra = content;
    if !is_checklist {
        for text in &items {
            if !extra.is_empty() {
                extra.push('\n');
            }
            extra.push_str(text);
            added += 1;
        }
    }
    if !extra.trim().is_empty() {
        let mut merged = record.content.clone();
        if !merged.is_empty() {
            merged.push('\n');
        }
        merged.push_str(&extra);
        body.content = Some(merged);
    }
    if body.items.is_none() && body.content.is_none() {
        return Ok(None);
    }

    let undo = serde_json::json!({
        "kind": record.kind,
        "title": record.title,
        "content": record.content,
        "items": record.items,
    });
    let view = apply_note_update(state, turn.user_id, note_id, body)
        .await
        .map_err(|_| "could not update the note")?;
    let confirmation = if added > 0 {
        format!(
            "Added {added} item{} to{}.",
            plural(added),
            titled(&view.note.title)
        )
    } else {
        format!("Updated{}.", titled(&view.note.title))
    };
    Ok(Some(AppliedWrite {
        action: "append",
        view,
        confirmation,
        undo,
    }))
}

/// `None` when the note vanished since retrieval.
async fn update_from_plan(
    state: &AppState,
    turn: &TurnContext<'_>,
    note_id: &str,
    items: Option<Vec<String>>,
    refile: Refile,
    mut patch: UpdateNote,
) -> Result<Option<AppliedWrite>, TurnError> {
    let Ok(Some(view)) = state.repo.note_view(note_id, turn.user_id).await else {
        return Ok(None);
    };
    let Ok(Some(record)) = state.repo.note_record_for_user(note_id, turn.user_id).await else {
        return Ok(None);
    };
    // Names resolve in the note's own workspace, which an unscoped turn may
    // not have open.
    let taxonomy = turn.taxonomy;
    patch.collection_id = refile
        .collection
        .as_deref()
        .and_then(|c| taxonomy.collection_id(&record.workspace_id, c))
        .filter(|id| record.collection_id.as_deref() != Some(id));
    if !refile.add_labels.is_empty() || !refile.remove_labels.is_empty() {
        let removed = taxonomy.label_ids(&record.workspace_id, &refile.remove_labels);
        let mut labels: Vec<String> = view
            .label_ids
            .iter()
            .filter(|id| !removed.contains(id))
            .cloned()
            .collect();
        for id in taxonomy.label_ids(&record.workspace_id, &refile.add_labels) {
            if !labels.contains(&id) {
                labels.push(id);
            }
        }
        if labels != view.label_ids {
            patch.label_ids = Some(labels);
        }
    }
    // Rows keep their ids, ticks and nesting by position, so a rewrite of the
    // list reads as an edit rather than a new list.
    patch.items = items.map(|texts| {
        texts
            .into_iter()
            .enumerate()
            .map(|(index, text)| match record.items.get(index) {
                Some(item) => ChecklistItem {
                    id: item.id.clone(),
                    text,
                    done: item.done,
                    depth: item.depth,
                },
                None => ChecklistItem {
                    id: new_id(),
                    text,
                    done: false,
                    depth: 0,
                },
            })
            .collect()
    });
    let mut undo = serde_json::json!({
        "title": record.title,
        "content": record.content,
        "items": record.items,
        "color": record.color,
        "pinned": record.pinned,
        "archived": record.archived,
        "trashed": record.trashed,
        "reminder_at": record.reminder_at,
        "reminder_repeat": record.reminder_repeat,
    });
    if patch.label_ids.is_some() {
        undo["label_ids"] = serde_json::json!(view.label_ids);
    }
    // A move clears the board column, so undo puts both back.
    if patch.collection_id.is_some() {
        undo["collection_id"] = serde_json::json!(record.collection_id);
        undo["stage_id"] = serde_json::json!(record.stage_id);
    }
    let view = apply_note_update(state, turn.user_id, note_id, patch)
        .await
        .map_err(|_| "could not update the note")?;
    Ok(Some(AppliedWrite {
        action: "update",
        view,
        confirmation: "Updated the note.".to_string(),
        undo,
    }))
}

/// A `created` frame carries the note so the client can offer a chip that
/// opens it; the confirmation streams as ordinary delta text. Unknown frame
/// types are ignored by older clients, so this is backwards-compatible. A
/// client that leaves part way still had its turn handled.
pub(super) async fn confirm_write(sink: &mut ChatSink, applied: &AppliedWrite) {
    let created = ChatFrame::Created {
        action: applied.action,
        note: NoteRef {
            id: &applied.view.note.id,
            title: &applied.view.note.title,
        },
        undo: &applied.undo,
    };
    if !send(sink, created).await {
        return;
    }
    let delta = ChatFrame::Delta {
        text: &applied.confirmation,
    };
    if !send(sink, delta).await {
        return;
    }
    send(sink, ChatFrame::Done).await;
}

/// " \"Groceries\"" or "" for a blank title, folded into a sentence.
fn titled(title: &str) -> String {
    let t = title.trim();
    if t.is_empty() {
        String::new()
    } else {
        format!(" \"{t}\"")
    }
}

fn plural(n: usize) -> &'static str {
    if n == 1 { "" } else { "s" }
}
