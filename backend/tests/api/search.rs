//! Semantic search.

use crate::helpers::*;

#[tokio::test]
async fn semantic_search_ranks_scopes_and_tracks_lifecycle() {
    let app = build_app(state_with_search().await);
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;

    let groceries = create_note(
        &app,
        &ada,
        json!({"title": "Groceries", "content": "buy milk eggs and bread at the market"}),
    )
    .await;
    create_note(
        &app,
        &ada,
        json!({"title": "Quarterly report", "content": "finish the business slides for friday"}),
    )
    .await;
    settle_index().await;

    // Ranked by similarity: the milk note wins for a milk-ish query.
    let (status, hits) =
        send(&app, "GET", "/api/search?q=milk%20bread", Some(&ada), None).await;
    assert_eq!(status, StatusCode::OK);
    let hits = hits.as_array().unwrap().clone();
    assert!(!hits.is_empty());
    assert_eq!(hits[0]["note_id"], groceries["id"]);

    // Scoped: bob has no access, so no results.
    let (_, bob_hits) = send(&app, "GET", "/api/search?q=milk", Some(&bob), None).await;
    assert_eq!(bob_hits, json!([]));

    // Sharing grants search visibility.
    let gid = groceries["id"].as_str().unwrap();
    send(
        &app,
        "POST",
        &format!("/api/notes/{gid}/collaborators"),
        Some(&ada),
        Some(json!({"username": "bob"})),
    )
    .await;
    settle_index().await;
    let (_, bob_hits) = send(&app, "GET", "/api/search?q=milk", Some(&bob), None).await;
    assert_eq!(bob_hits.as_array().unwrap().len(), 1);

    // Deletion removes the note from the index.
    let (status, _) = send(&app, "DELETE", &format!("/api/notes/{gid}"), Some(&ada), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    settle_index().await;
    let (_, hits) = send(&app, "GET", "/api/search?q=milk", Some(&ada), None).await;
    for hit in hits.as_array().unwrap() {
        assert_ne!(hit["note_id"], json!(gid));
    }

    // Auth required; empty query is an empty result, not an error.
    let (status, _) = send(&app, "GET", "/api/search?q=milk", None, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (_, empty) = send(&app, "GET", "/api/search?q=%20", Some(&ada), None).await;
    assert_eq!(empty, json!([]));
}

#[tokio::test]
async fn semantic_search_reports_unavailable_when_disabled() {
    let app = app().await; // no search service wired
    let (ada, _) = register(&app, "ada").await;
    let (status, _) = send(&app, "GET", "/api/search?q=milk", Some(&ada), None).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
}

