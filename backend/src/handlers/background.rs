//! Fire-and-forget work hung off [`AppState`]: change notifications, signed
//! attachment URLs, and the background indexing / transcription / labeling
//! tasks that must never sit in a request's latency path.

use crate::AppState;
use crate::models::*;

use super::CHANGED_MSG;

impl AppState {
    /// Push a change event to everyone who can see the note.
    pub(super) async fn notify_note(&self, note_id: &str) {
        if let Ok(ids) = self.repo.participant_ids(note_id).await {
            self.hub.notify(&ids, CHANGED_MSG);
        }
    }

    pub(super) fn notify_user(&self, user_id: &str) {
        self.hub.notify(std::slice::from_ref(&user_id.to_string()), CHANGED_MSG);
    }

    /// Stamp each attachment with a signed, time-limited fetch URL. Applied to
    /// every note view and upload response we serve, so clients load images and
    /// audio with a plain URL while [`serve_file`] stays behind the signature.
    ///
    /// [`serve_file`]: super::serve_file
    pub(super) fn sign_attachment(&self, attachment: &mut Attachment) {
        attachment.url = Some(crate::files::signed_file_path(&self.file_secret, &attachment.id));
    }

    pub(super) fn sign_view(&self, view: &mut NoteView) {
        for attachment in view.attachments.iter_mut() {
            self.sign_attachment(attachment);
        }
    }

    pub(super) fn sign_views(&self, views: &mut [NoteView]) {
        for view in views.iter_mut() {
            self.sign_view(view);
        }
    }

    /// Re-embed and index a note in the background (fire and forget); request
    /// latency never waits on the embedder.
    pub fn index_note_later(&self, note_id: &str) {
        let Some(search) = self.search.clone() else { return };
        let repo = self.repo.clone();
        let note_id = note_id.to_string();
        tokio::spawn(async move {
            let Ok(Some(record)) = repo.note_record(&note_id).await else { return };
            let participants = repo.participant_ids(&note_id).await.unwrap_or_default();
            if let Err(e) = search.index_note(&record, participants).await {
                eprintln!("semantic index failed for {note_id}: {e:#}");
            }
        });
    }

    pub fn unindex_note_later(&self, note_id: &str) {
        let Some(search) = self.search.clone() else { return };
        let note_id = note_id.to_string();
        tokio::spawn(async move {
            let _ = search.remove_note(&note_id).await;
        });
    }

    /// Transcribe an audio attachment in the background (fire and forget).
    /// The caller is expected to have already marked the note `pending`; this
    /// only runs Whisper, then stores the transcript (`done`) or marks
    /// `failed`, re-indexing for search on success. No-op when transcription
    /// is disabled.
    pub fn transcribe_later(
        &self,
        note_id: &str,
        owner_id: &str,
        attachment_id: &str,
        filename: &str,
        user_id: &str,
    ) {
        let Some(transcriber) = self.transcribe.clone() else { return };
        let state = self.clone();
        let note_id = note_id.to_string();
        let owner_id = owner_id.to_string();
        let attachment_id = attachment_id.to_string();
        let filename = filename.to_string();
        let user_id = user_id.to_string();
        tokio::spawn(async move {
            let status_and_content = match state.files.read(&owner_id, &attachment_id).await {
                Some(bytes) => match transcriber.transcribe(bytes, &filename).await {
                    Ok(text) => (TRANSCRIPT_DONE, Some(text)),
                    Err(e) => {
                        eprintln!("transcription failed for {note_id}: {e:#}");
                        (TRANSCRIPT_FAILED, None)
                    }
                },
                None => (TRANSCRIPT_FAILED, None),
            };
            let (status, content) = status_and_content;
            let _ = state.repo.set_transcript(&note_id, status, content.as_deref()).await;
            if status == TRANSCRIPT_DONE {
                state.index_note_later(&note_id);
                state.label_note_later(&note_id, &user_id);
            }
            state.notify_note(&note_id).await;
        });
    }

    /// Auto-label a note in the background (fire and forget): ask the user's
    /// configured LLM which of their EXISTING labels apply and add those —
    /// add-only, never removes, never creates labels. No-op unless the user
    /// has an LLM configured with labeling enabled.
    ///
    /// Debounced per note via a generation counter: each trigger bumps the
    /// note's generation and the spawned task sleeps `label_delay` before
    /// checking it's still the latest — so a burst of debounced autosaves
    /// costs one LLM call. Keyed by note id alone: if two collaborators edit
    /// within one window, only the last editor's task runs (with their own
    /// labels), which is fine — the next edit re-triggers.
    pub fn label_note_later(&self, note_id: &str, user_id: &str) {
        let state = self.clone();
        let note_id = note_id.to_string();
        let user_id = user_id.to_string();
        let generation = {
            let mut map = state.label_generations.lock().unwrap();
            let entry = map.entry(note_id.clone()).or_insert(0);
            *entry += 1;
            *entry
        };
        tokio::spawn(async move {
            tokio::time::sleep(state.label_delay).await;
            // Superseded by a newer edit: that trigger's task takes over.
            if state.label_generations.lock().unwrap().get(&note_id) != Some(&generation) {
                return;
            }
            state.run_auto_labeling(&note_id, &user_id).await;
            // Bound map growth: clear the entry unless a newer trigger owns it.
            let mut map = state.label_generations.lock().unwrap();
            if map.get(&note_id) == Some(&generation) {
                map.remove(&note_id);
            }
        });
    }

    async fn run_auto_labeling(&self, note_id: &str, user_id: &str) {
        let settings = match self.repo.settings_for_user(user_id).await {
            Ok(s) => s,
            Err(_) => return,
        };
        let effective = self.managed.overlay(settings.as_deref());
        let llm_settings = crate::assist::parse_llm_settings_value(&effective);
        let Some(cfg) = llm_settings.config else { return };
        if !llm_settings.labeling {
            return;
        }
        let Ok(Some(record)) = self.repo.note_record(note_id).await else { return };
        if record.trashed {
            return;
        }
        let text = crate::search::SearchService::note_text(&record);
        if text.is_empty() {
            return;
        }
        let Ok(labels) = self.repo.labels_for_user(user_id).await else { return };
        if labels.is_empty() {
            return;
        }
        let current = match self.repo.note_view(note_id, user_id).await {
            Ok(Some(view)) => view.label_ids,
            _ => return,
        };
        let names: Vec<String> = labels.iter().map(|l| l.name.clone()).collect();
        let messages = crate::assist::labeling_messages(&names, &text);
        let reply = match self.llm.complete(&cfg, messages).await {
            Ok(reply) => reply,
            Err(e) => {
                eprintln!("auto-labeling failed for {note_id}: {e:#}");
                return;
            }
        };
        let chosen =
            crate::assist::map_label_names(&crate::assist::parse_label_reply(&reply), &labels);
        // Add-only union; skip the write (and the change nudge) when nothing new.
        let mut union = current.clone();
        for id in chosen {
            if !union.contains(&id) {
                union.push(id);
            }
        }
        if union.len() == current.len() {
            return;
        }
        if self.repo.set_note_labels(note_id, user_id, &union).await.is_ok() {
            self.notify_note(note_id).await;
        }
    }
}
