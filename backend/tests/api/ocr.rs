//! Reading uploaded images for text, and finding them again by it.

use crate::helpers::*;

use std::sync::atomic::Ordering;

/// Fetch the caller's copy of a note.
async fn note_view(app: &Router, token: &str, id: &str) -> Value {
    let (status, body) = send(app, "GET", &format!("/api/notes/{id}"), Some(token), None).await;
    assert_eq!(status, StatusCode::OK, "note view: {body}");
    body
}

fn first_attachment(view: &Value) -> Value {
    view["attachments"].as_array().unwrap()[0].clone()
}

#[tokio::test]
async fn an_uploaded_image_is_read_for_text_and_found_by_it() {
    let (state, reads) = state_with_ocr("PHARMACY RECEIPT ibuprofen 4.20").await;
    let app = build_app(state);
    let (token, _) = register(&app, "ada").await;

    // A note with no words of its own: everything findable about it will come
    // out of the picture.
    let note = create_note(&app, &token, json!({})).await;
    let id = note["id"].as_str().unwrap().to_string();
    let (status, _) = upload(&app, &token, &id, "image/png", b"\x89PNG\r\nfake").await;
    assert_eq!(status, StatusCode::CREATED);
    settle_ocr().await;

    // The recognized text rides along with the attachment.
    let view = note_view(&app, &token, &id).await;
    assert_eq!(
        first_attachment(&view)["ocr_text"],
        json!("PHARMACY RECEIPT ibuprofen 4.20")
    );
    assert_eq!(reads.load(Ordering::Relaxed), 1);

    // And the note is now reachable by words that appear nowhere but in the
    // image, which is the whole point of reading it.
    let (status, hits) = send(&app, "GET", "/api/search?q=ibuprofen", Some(&token), None).await;
    assert_eq!(status, StatusCode::OK);
    let hits = hits.as_array().unwrap();
    assert_eq!(hits.len(), 1, "expected the photographed receipt: {hits:?}");
    assert_eq!(hits[0]["note_id"], json!(id));
}

#[tokio::test]
async fn only_readable_images_are_sent_to_the_engine() {
    let (state, reads) = state_with_ocr("IGNORED").await;
    let app = build_app(state);
    let (token, _) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({"title": "mixed bag"})).await;
    let id = note["id"].as_str().unwrap().to_string();

    // A sound file, a document, and a vector image: none of them is a raster
    // the engine could read.
    upload(&app, &token, &id, "audio/webm", b"clip").await;
    upload(&app, &token, &id, "application/pdf", b"%PDF-1.4").await;
    upload(&app, &token, &id, "image/svg+xml", b"<svg/>").await;
    settle_ocr().await;

    assert_eq!(reads.load(Ordering::Relaxed), 0);
    let view = note_view(&app, &token, &id).await;
    for attachment in view["attachments"].as_array().unwrap() {
        assert_eq!(attachment["ocr_text"], Value::Null, "{attachment}");
    }
}

#[tokio::test]
async fn a_wordless_picture_is_recorded_as_read_and_never_queued_again() {
    let (state, reads) = state_with_ocr("").await;
    let app = build_app(state.clone());
    let (token, _) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({"title": "sunset"})).await;
    let id = note["id"].as_str().unwrap().to_string();
    upload(&app, &token, &id, "image/jpeg", b"jpegbytes").await;
    settle_ocr().await;

    // Empty text is a real answer, not a missing one: the attachment carries
    // it, and the backlog pass leaves the picture alone from now on.
    let view = note_view(&app, &token, &id).await;
    assert_eq!(first_attachment(&view)["ocr_text"], json!(""));
    assert_eq!(state.ocr_backlog(10).await, 0);
    settle_ocr().await;
    assert_eq!(reads.load(Ordering::Relaxed), 1);
}

#[tokio::test]
async fn a_failed_reading_is_retried_by_the_backlog_pass() {
    // The engine is down while the picture is uploaded.
    let state = state_with_search().await.with_ocr(Arc::new(FailOcr));
    let app = build_app(state.clone());
    let (token, _) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({})).await;
    let id = note["id"].as_str().unwrap().to_string();
    upload(&app, &token, &id, "image/png", b"\x89PNG\r\nfake").await;
    settle_ocr().await;

    // Nothing was stored, so the note is not findable by its contents yet.
    let view = note_view(&app, &token, &id).await;
    assert_eq!(first_attachment(&view)["ocr_text"], Value::Null);
    let (_, hits) = send(&app, "GET", "/api/search?q=whiteboard", Some(&token), None).await;
    assert_eq!(hits, json!([]));

    // A later start with a working engine picks the image back up: an
    // unrecognized picture is a backlog entry, not a permanent loss.
    let (engine, reads) = FakeOcr::new("whiteboard sprint plan");
    let recovered = state.clone().with_ocr(engine);
    assert_eq!(recovered.ocr_backlog(10).await, 1);
    settle_ocr().await;
    assert_eq!(reads.load(Ordering::Relaxed), 1);

    let view = note_view(&app, &token, &id).await;
    assert_eq!(
        first_attachment(&view)["ocr_text"],
        json!("whiteboard sprint plan")
    );
    let (_, hits) = send(&app, "GET", "/api/search?q=whiteboard", Some(&token), None).await;
    assert_eq!(hits.as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn images_uploaded_before_ocr_was_enabled_are_caught_up() {
    // No OCR wired at all: the upload succeeds and stores nothing.
    let plain = state_with_search().await;
    let app = build_app(plain.clone());
    let (token, _) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({})).await;
    let id = note["id"].as_str().unwrap().to_string();
    upload(&app, &token, &id, "image/png", b"\x89PNG\r\nfake").await;
    settle_ocr().await;
    assert_eq!(
        first_attachment(&note_view(&app, &token, &id).await)["ocr_text"],
        Value::Null
    );
    // With OCR off, the backlog pass is a no-op rather than an error.
    assert_eq!(plain.ocr_backlog(10).await, 0);

    let (engine, _) = FakeOcr::new("garage door code 4417");
    let enabled = plain.clone().with_ocr(engine);
    assert_eq!(enabled.ocr_backlog(10).await, 1);
    settle_ocr().await;

    assert_eq!(
        first_attachment(&note_view(&app, &token, &id).await)["ocr_text"],
        json!("garage door code 4417")
    );
}

#[tokio::test]
async fn deleting_an_attachment_forgets_what_was_read_from_it() {
    let (state, _) = state_with_ocr("bank statement").await;
    let app = build_app(state.clone());
    let (token, _) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({})).await;
    let id = note["id"].as_str().unwrap().to_string();
    let (_, attachment) = upload(&app, &token, &id, "image/png", b"\x89PNG\r\nfake").await;
    let attachment_id = attachment["id"].as_str().unwrap().to_string();
    settle_ocr().await;

    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/attachments/{attachment_id}"),
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    settle_ocr().await;

    // The recognized text goes with the picture: it is neither searchable nor
    // waiting in the backlog.
    let (_, hits) = send(&app, "GET", "/api/search?q=statement", Some(&token), None).await;
    assert_eq!(hits, json!([]));
    assert_eq!(state.ocr_backlog(10).await, 0);
}
