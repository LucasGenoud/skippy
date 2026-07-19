//! Attachment upload/serve/delete and signed file URLs.

use crate::helpers::*;

#[tokio::test]
async fn attachment_upload_serve_delete() {
    let app = app().await;
    let (token, _) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({"title": "with pic"})).await;
    let note_id = note["id"].as_str().unwrap();

    let payload = b"fake-png-bytes".as_slice();
    let (status, attachment) = upload(&app, &token, note_id, "image/png", payload).await;
    assert_eq!(status, StatusCode::CREATED, "{attachment}");
    let att_id = attachment["id"].as_str().unwrap().to_string();
    // The upload response already carries a signed, ready-to-load URL.
    let signed_url = attachment["url"].as_str().expect("signed url in upload response").to_string();

    // Attachment appears on the note view, also with a signed URL.
    let (_, view) = send(&app, "GET", &format!("/api/notes/{note_id}"), Some(&token), None).await;
    assert_eq!(view["attachments"][0]["id"], json!(att_id));
    assert!(view["attachments"][0]["url"].as_str().unwrap().contains("sig="));

    // The signed URL serves the bytes with the right content type.
    let request = Request::builder().uri(&signed_url).body(Body::empty()).unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()[header::CONTENT_TYPE], "image/png");
    assert_eq!(response.headers()[header::CACHE_CONTROL], "private, max-age=3600");
    let served = response.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(served.as_ref(), payload);

    // The bare id (no signature) is rejected — the hole this fix closes.
    let request = Request::builder().uri(format!("/api/files/{att_id}")).body(Body::empty()).unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

    // Delete removes row and file; the still-valid signed URL now 404s.
    let (status, _) =
        send(&app, "DELETE", &format!("/api/attachments/{att_id}"), Some(&token), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let request = Request::builder().uri(&signed_url).body(Body::empty()).unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

/// Audio (and any media) must be range-servable so iOS AVPlayer / `just_audio`
/// can stream and seek it — the plain-200 server used to make mobile playback
/// fail. Verify `Accept-Ranges`, a `206` slice, inline disposition, and `416`.
#[tokio::test]
async fn audio_files_serve_byte_ranges() {
    let app = app().await;
    let (token, _) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({"kind": "audio"})).await;
    let note_id = note["id"].as_str().unwrap();

    let payload = b"0123456789".as_slice();
    let (status, attachment) = upload(&app, &token, note_id, "audio/mp4", payload).await;
    assert_eq!(status, StatusCode::CREATED, "{attachment}");
    let signed_url = attachment["url"].as_str().unwrap().to_string();

    // A full GET advertises range support and renders inline (not download).
    let request = Request::builder().uri(&signed_url).body(Body::empty()).unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()[header::ACCEPT_RANGES], "bytes");
    assert_eq!(response.headers()[header::CONTENT_DISPOSITION], "inline");

    // A byte range returns 206 with just those bytes and a Content-Range.
    let request = Request::builder()
        .uri(&signed_url)
        .header(header::RANGE, "bytes=2-5")
        .body(Body::empty())
        .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(response.headers()[header::CONTENT_RANGE], "bytes 2-5/10");
    let served = response.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(served.as_ref(), b"2345");

    // An open-ended range clamps to the end of the file.
    let request = Request::builder()
        .uri(&signed_url)
        .header(header::RANGE, "bytes=7-")
        .body(Body::empty())
        .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
    let served = response.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(served.as_ref(), b"789");

    // A range past the end is unsatisfiable.
    let request = Request::builder()
        .uri(&signed_url)
        .header(header::RANGE, "bytes=100-200")
        .body(Body::empty())
        .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::RANGE_NOT_SATISFIABLE);
    assert_eq!(response.headers()[header::CONTENT_RANGE], "bytes */10");
}

/// The signature is the whole access-control story for files, so exercise the
/// ways it can be wrong: absent, tampered, expired, or bound to another id.
#[tokio::test]
async fn file_urls_require_valid_signature() {
    use sticky_notes_server::files::file_signature;
    let app = app().await;
    let (token, _) = register(&app, "ada").await;
    let note = create_note(&app, &token, json!({"title": "n"})).await;
    let note_id = note["id"].as_str().unwrap();
    let (_, attachment) = upload(&app, &token, note_id, "image/png", b"bytes").await;
    let att_id = attachment["id"].as_str().unwrap().to_string();

    async fn status_of(app: &Router, uri: String) -> StatusCode {
        let request = Request::builder().uri(uri).body(Body::empty()).unwrap();
        app.clone().oneshot(request).await.unwrap().status()
    }

    // No signature.
    assert_eq!(status_of(&app, format!("/api/files/{att_id}")).await, StatusCode::UNAUTHORIZED);

    // Valid signature, future expiry -> served.
    let future = chrono::Utc::now().timestamp() + 3600;
    let good = file_signature(TEST_FILE_SECRET, &att_id, future);
    assert_eq!(
        status_of(&app, format!("/api/files/{att_id}?exp={future}&sig={good}")).await,
        StatusCode::OK
    );

    // Extending the expiry breaks the signature (it covers exp).
    assert_eq!(
        status_of(&app, format!("/api/files/{att_id}?exp={}&sig={good}", future + 999_999)).await,
        StatusCode::UNAUTHORIZED
    );

    // Correctly signed but expired.
    let past = chrono::Utc::now().timestamp() - 10;
    let expired = file_signature(TEST_FILE_SECRET, &att_id, past);
    assert_eq!(
        status_of(&app, format!("/api/files/{att_id}?exp={past}&sig={expired}")).await,
        StatusCode::UNAUTHORIZED
    );

    // A signature minted for a different id doesn't transfer.
    let other = file_signature(TEST_FILE_SECRET, "another-id", future);
    assert_eq!(
        status_of(&app, format!("/api/files/{att_id}?exp={future}&sig={other}")).await,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn attachment_rules() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let note = create_note(&app, &ada, json!({"title": "n"})).await;
    let note_id = note["id"].as_str().unwrap();

    // Any file type is stored, but non-images are forced to download with
    // their filename — never rendered in the app's origin.
    let (status, attachment) =
        upload(&app, &ada, note_id, "text/html", b"<script>alert(1)</script>").await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(attachment["filename"], "pic");
    assert_eq!(attachment["size"], 25);
    let signed_url = attachment["url"].as_str().unwrap();
    let request = Request::builder().uri(signed_url).body(Body::empty()).unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let disposition = response.headers()[header::CONTENT_DISPOSITION].to_str().unwrap();
    assert!(disposition.starts_with("attachment"), "{disposition}");
    assert_eq!(response.headers()["x-content-type-options"], "nosniff");

    // Strangers can't upload to a note they can't see.
    let (status, _) = upload(&app, &bob, note_id, "image/png", b"x").await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // Collaborators can.
    send(
        &app,
        "POST",
        &format!("/api/notes/{note_id}/collaborators"),
        Some(&ada),
        Some(json!({"username": "bob"})),
    )
    .await;
    let (status, _) = upload(&app, &bob, note_id, "image/png", b"x").await;
    assert_eq!(status, StatusCode::CREATED);
}

