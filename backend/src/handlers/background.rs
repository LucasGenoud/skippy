//! Fire-and-forget work hung off [`AppState`]: change notifications, signed
//! attachment URLs, and the background indexing / transcription / labeling
//! tasks that must never sit in a request's latency path.

use crate::AppState;
use crate::models::*;

use super::CHANGED_MSG;

impl AppState {
    /// Push a change event to everyone who can see the note.
    pub(crate) async fn notify_note(&self, note_id: &str) {
        match self.repo.participant_ids(note_id).await {
            Ok(ids) => self.hub.notify(&ids, CHANGED_MSG),
            Err(error) => {
                self.report_background_failure("participant_notification", &format!("{error:?}"));
            }
        }
    }

    pub(super) fn notify_user(&self, user_id: &str) {
        self.hub
            .notify(std::slice::from_ref(&user_id.to_string()), CHANGED_MSG);
    }

    /// Stamp each attachment with a signed, time-limited fetch URL. Applied to
    /// every note view and upload response we serve, so clients load images and
    /// audio with a plain URL while [`serve_file`] stays behind the signature.
    ///
    /// [`serve_file`]: super::serve_file
    pub(super) fn sign_attachment(&self, attachment: &mut Attachment) {
        attachment.url = Some(crate::files::signed_file_path(
            &self.file_secret,
            &attachment.id,
        ));
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
        let Some(search) = self.search.clone() else {
            return;
        };
        let state = self.clone();
        let note_id = note_id.to_string();
        tokio::spawn(async move {
            let record = match state.repo.note_record(&note_id).await {
                Ok(Some(record)) => record,
                Ok(None) => return,
                Err(error) => {
                    state.report_background_failure("semantic_index_load", &format!("{error:?}"));
                    return;
                }
            };
            let ocr_texts = state.note_ocr_text(&note_id).await;
            if let Err(e) = search.index_note(&record, &ocr_texts).await {
                state.report_background_failure("semantic_index", &e);
            }
        });
    }

    /// Text read out of a note's images, or nothing at all if the lookup
    /// fails: a note is still worth indexing on its own words when the OCR
    /// cache is unavailable.
    pub(crate) async fn note_ocr_text(&self, note_id: &str) -> Vec<String> {
        match self.repo.note_ocr_text(note_id).await {
            Ok(texts) => texts,
            Err(error) => {
                self.report_background_failure("ocr_text_load", &format!("{error:?}"));
                Vec::new()
            }
        }
    }

    /// Read an image attachment for text in the background (fire and forget),
    /// then re-index its note so the words inside the picture are searchable.
    /// No-op when OCR is disabled or the format holds no raster to read.
    ///
    /// A failure deliberately stores nothing: the attachment stays in the
    /// backlog [`ocr_backlog`](Self::ocr_backlog) works through at startup, so
    /// an OCR service that was down or restarting gets another chance.
    /// `labeled_for` is the user whose LLM may re-label the note once the text
    /// lands, absent for backlog work so a restart cannot fire a burst of
    /// labeling calls.
    pub fn ocr_later(
        &self,
        attachment_id: &str,
        note_id: &str,
        mime: &str,
        filename: &str,
        labeled_for: Option<&str>,
    ) {
        let Some(engine) = self.ocr.clone() else {
            return;
        };
        if !crate::ocr::is_ocr_candidate(mime) {
            return;
        }
        let state = self.clone();
        let attachment_id = attachment_id.to_string();
        let note_id = note_id.to_string();
        let filename = filename.to_string();
        let labeled_for = labeled_for.map(str::to_string);
        tokio::spawn(async move {
            // Bounded concurrency: a backlog pass must not hand a small
            // self-hosted container every picture at once.
            let Ok(_slot) = state.ocr_slots.clone().acquire_owned().await else {
                return;
            };
            let Some(bytes) = state.files.read(&attachment_id).await else {
                state.report_background_failure("ocr_blob_read", &"attachment blob unavailable");
                return;
            };
            let text = match engine.recognize(bytes, &filename).await {
                Ok(text) => text,
                Err(e) => {
                    state.report_background_failure("ocr", &e);
                    return;
                }
            };
            if let Err(error) = state.repo.set_attachment_ocr(&attachment_id, &text).await {
                state.report_background_failure("ocr_persist", &format!("{error:?}"));
                return;
            }
            // A picture with no words in it is recorded (so it leaves the
            // backlog) but changes nothing anyone can see or search.
            if text.is_empty() {
                return;
            }
            state.index_note_later(&note_id);
            if let Some(user_id) = labeled_for {
                state.label_note_later(&note_id, &user_id);
            }
            state.notify_note(&note_id).await;
        });
    }

    /// Queue recognition for images that carry no recognized text yet, so
    /// turning OCR on makes an existing library searchable and an interrupted
    /// or failed reading is retried. Bounded per call; a large library catches
    /// up over successive starts rather than in one burst.
    pub async fn ocr_backlog(&self, limit: u32) -> usize {
        if self.ocr.is_none() {
            return 0;
        }
        let jobs = match self.repo.attachments_awaiting_ocr(limit).await {
            Ok(jobs) => jobs,
            Err(error) => {
                self.report_background_failure("ocr_backlog", &format!("{error:?}"));
                return 0;
            }
        };
        let mut queued = 0;
        for job in jobs {
            if !crate::ocr::is_ocr_candidate(&job.mime) {
                continue;
            }
            self.ocr_later(
                &job.attachment_id,
                &job.note_id,
                &job.mime,
                &job.filename,
                None,
            );
            queued += 1;
        }
        queued
    }

    /// Transcribe an audio attachment in the background (fire and forget).
    /// The caller is expected to have already marked the note `pending`; this
    /// only runs Whisper, then stores the transcript (`done`) or marks
    /// `failed`, re-indexing for search on success. No-op when transcription
    /// is disabled.
    pub fn transcribe_later(
        &self,
        note_id: &str,
        attachment_id: &str,
        filename: &str,
        user_id: &str,
    ) {
        let Some(transcriber) = self.transcribe.clone() else {
            return;
        };
        let state = self.clone();
        let note_id = note_id.to_string();
        let attachment_id = attachment_id.to_string();
        let filename = filename.to_string();
        let user_id = user_id.to_string();
        tokio::spawn(async move {
            let status_and_content = match state.files.read(&attachment_id).await {
                Some(bytes) => match transcriber.transcribe(bytes, &filename).await {
                    Ok(text) => (TRANSCRIPT_DONE, Some(text)),
                    Err(e) => {
                        state.report_background_failure("transcription", &e);
                        (TRANSCRIPT_FAILED, None)
                    }
                },
                None => {
                    state.report_background_failure(
                        "transcription_blob_read",
                        &"attachment blob unavailable",
                    );
                    (TRANSCRIPT_FAILED, None)
                }
            };
            let (status, content) = status_and_content;
            if let Err(error) = state
                .repo
                .set_transcript(&note_id, status, content.as_deref())
                .await
            {
                state.report_background_failure("transcription_persist", &format!("{error:?}"));
                return;
            }
            if status == TRANSCRIPT_DONE {
                state.index_note_later(&note_id);
                state.label_note_later(&note_id, &user_id);
            }
            state.notify_note(&note_id).await;
        });
    }

    /// Auto-label a note in the background (fire and forget): ask the user's
    /// configured LLM which of their EXISTING labels apply and add those,
    /// add-only, never removes, never creates labels. No-op unless the user
    /// has an LLM configured with labeling enabled.
    ///
    /// Debounced per note via a generation counter: each trigger bumps the
    /// note's generation and the spawned task sleeps `label_delay` before
    /// checking it's still the latest, so a burst of debounced autosaves
    /// costs one LLM call. Keyed by note id alone: if two collaborators edit
    /// within one window, only the last editor's task runs (with their own
    /// labels), which is fine, the next edit re-triggers.
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
            Err(error) => {
                self.report_background_failure("auto_label_settings", &format!("{error:?}"));
                return;
            }
        };
        let effective = self.managed.overlay(settings.as_deref());
        let llm_settings = crate::assist::parse_llm_settings_value(&effective);
        let Some(cfg) = llm_settings.config else {
            return;
        };
        if !llm_settings.labeling {
            return;
        }
        let record = match self.repo.note_record(note_id).await {
            Ok(Some(record)) => record,
            Ok(None) => return,
            Err(error) => {
                self.report_background_failure("auto_label_note", &format!("{error:?}"));
                return;
            }
        };
        if record.trashed {
            return;
        }
        // The same text the embedder sees, so a note whose only content is a
        // photograph can still be labeled from the words in it.
        let ocr_texts = self.note_ocr_text(note_id).await;
        let text = crate::search::SearchService::note_text_with_ocr(&record, &ocr_texts);
        if text.is_empty() {
            return;
        }
        let labels = match self.repo.labels_for_user(user_id).await {
            Ok(labels) => labels,
            Err(error) => {
                self.report_background_failure("auto_label_taxonomy", &format!("{error:?}"));
                return;
            }
        };
        // Only the taxonomy of the note's own workspace is on offer, a label
        // from another workspace could not be attached anyway.
        let labels: Vec<Label> = labels
            .into_iter()
            .filter(|l| l.workspace_id == record.workspace_id)
            .collect();
        if labels.is_empty() {
            return;
        }
        let current = match self.repo.note_view(note_id, user_id).await {
            Ok(Some(view)) => view.label_ids,
            Ok(None) => return,
            Err(error) => {
                self.report_background_failure("auto_label_view", &format!("{error:?}"));
                return;
            }
        };
        let names: Vec<String> = labels.iter().map(|l| l.name.clone()).collect();
        let messages = crate::assist::labeling_messages(&names, &text);
        let reply = match self.llm.complete(&cfg, messages).await {
            Ok(reply) => reply,
            Err(e) => {
                self.report_background_failure("auto_label_completion", &e);
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
        match self.repo.set_note_labels(note_id, &union).await {
            Ok(()) => self.notify_note(note_id).await,
            Err(error) => {
                self.report_background_failure("auto_label_persist", &format!("{error:?}"));
            }
        }
    }
}
