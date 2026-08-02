//! Capabilities endpoint and audio transcription.

use crate::helpers::*;

#[tokio::test]
async fn capabilities_reflect_wired_services() {
    // Nothing wired: both optional features report off (unauthenticated).
    let app = app().await;
    let (status, caps) = send(&app, "GET", "/api/capabilities", None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(caps["semantic_search"], json!(false));
    assert_eq!(caps["audio_transcription"], json!(false));

    let app = build_app(state_with_search().await);
    let (_, caps) = send(&app, "GET", "/api/capabilities", None, None).await;
    assert_eq!(caps["semantic_search"], json!(true));
    assert_eq!(caps["audio_transcription"], json!(false));

    let app = build_app(state_with_transcription().await);
    let (_, caps) = send(&app, "GET", "/api/capabilities", None, None).await;
    assert_eq!(caps["semantic_search"], json!(false));
    assert_eq!(caps["audio_transcription"], json!(true));
}

#[tokio::test]
async fn audio_note_upload_triggers_transcription() {
    let app = build_app(state_with_transcription().await);
    let (token, _) = register(&app, "ada").await;

    // A fresh audio note carries no transcript yet.
    let note = create_note(&app, &token, json!({"kind": "audio"})).await;
    let id = note["id"].as_str().unwrap().to_string();
    assert_eq!(note["kind"], json!("audio"));
    assert_eq!(note["transcript_status"], json!("none"));

    // Uploading the clip runs Whisper and stores the transcript as content.
    let (status, _) = upload(&app, &token, &id, "audio/webm", b"fake-audio-bytes").await;
    assert_eq!(status, StatusCode::CREATED);
    settle_index().await;

    let refreshed = &list_notes(&app, &token).await[0];
    assert_eq!(refreshed["transcript_status"], json!("done"));
    assert_eq!(refreshed["content"], json!("transcript of 16 bytes"));
}

#[tokio::test]
async fn audio_note_upload_remains_usable_without_transcription() {
    let app = app().await; // no transcription service wired
    let (token, _) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({"kind": "audio"})).await;
    let id = note["id"].as_str().unwrap().to_string();

    let (status, _) = upload(&app, &token, &id, "audio/webm", b"audio-only").await;
    assert_eq!(status, StatusCode::CREATED);

    let refreshed = &list_notes(&app, &token).await[0];
    assert_eq!(refreshed["transcript_status"], json!("none"));
    assert_eq!(refreshed["content"], json!(""));
    assert_eq!(refreshed["attachments"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn retry_transcription_validates_and_reruns() {
    let app = build_app(state_with_transcription().await);
    let (token, _) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({"kind": "audio"})).await;
    let id = note["id"].as_str().unwrap().to_string();

    // Nothing to transcribe yet.
    let (status, _) =
        send(&app, "POST", &format!("/api/notes/{id}/transcribe"), Some(&token), None).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // With a clip attached, an explicit retry re-runs and lands the transcript.
    upload(&app, &token, &id, "audio/webm", b"hello").await;
    settle_index().await;
    let (status, _) =
        send(&app, "POST", &format!("/api/notes/{id}/transcribe"), Some(&token), None).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    settle_index().await;
    let refreshed = &list_notes(&app, &token).await[0];
    assert_eq!(refreshed["transcript_status"], json!("done"));
    assert_eq!(refreshed["content"], json!("transcript of 5 bytes"));
}

#[tokio::test]
async fn non_audio_upload_leaves_transcript_untouched() {
    let app = build_app(state_with_transcription().await);
    let (token, _) = register(&app, "ada").await;
    // A text note with an image attachment is never transcribed.
    let note = create_note(&app, &token, json!({"title": "hi"})).await;
    let id = note["id"].as_str().unwrap().to_string();
    upload(&app, &token, &id, "image/png", b"\x89PNG\r\n").await;
    settle_index().await;
    let refreshed = &list_notes(&app, &token).await[0];
    assert_eq!(refreshed["transcript_status"], json!("none"));
    assert_eq!(refreshed["content"], json!(""));
}

#[tokio::test]
async fn transcribe_reports_unavailable_when_disabled() {
    let app = app().await; // no transcription service wired
    let (token, _) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({"kind": "audio"})).await;
    let id = note["id"].as_str().unwrap().to_string();
    let (status, _) =
        send(&app, "POST", &format!("/api/notes/{id}/transcribe"), Some(&token), None).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
}
