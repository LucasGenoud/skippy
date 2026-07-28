//! Semantic search.

use crate::helpers::*;

#[tokio::test]
async fn semantic_search_ranks_scopes_and_tracks_lifecycle() {
    let app_state = state_with_search().await;
    let app = build_app(app_state.clone());
    let (ada, _) = register(&app, "ada").await;
    let (bob, bob_id) = register(&app, "bob").await;

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
    let (status, hits) = send(&app, "GET", "/api/search?q=milk%20bread", Some(&ada), None).await;
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
        Some(json!({"email": "bob@example.test"})),
    )
    .await;
    settle_index().await;
    let (_, bob_hits) = send(&app, "GET", "/api/search?q=milk", Some(&bob), None).await;
    assert_eq!(bob_hits.as_array().unwrap().len(), 1);

    // Simulate the eventual-consistency window after access is revoked: remove
    // the primary ACL directly, leaving Bob's vector row deliberately stale.
    assert!(
        app_state
            .repo
            .remove_collaborator(gid, &bob_id)
            .await
            .unwrap()
    );
    let stale = app_state
        .search
        .as_ref()
        .unwrap()
        .search(&bob_id, "milk", 20)
        .await
        .unwrap();
    assert!(stale.iter().any(|(id, _)| id == gid));
    let (_, bob_hits) = send(&app, "GET", "/api/search?q=milk", Some(&bob), None).await;
    assert_eq!(
        bob_hits,
        json!([]),
        "stale vector rows must not grant search visibility"
    );

    // Deletion removes the note from the index.
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/api/notes/{gid}"),
        Some(&ada),
        None,
    )
    .await;
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

#[tokio::test]
async fn search_stats_report_model_and_per_user_coverage() {
    let app = build_app(state_with_search().await);
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;

    create_note(&app, &ada, json!({"title": "Milk", "content": "buy milk"})).await;
    create_note(&app, &ada, json!({"title": "Eggs", "content": "buy eggs"})).await;
    // A note with no embeddable text (e.g. an image-only note) is never indexed,
    // so it must not count toward ada's total either.
    create_note(&app, &ada, json!({"title": "", "content": ""})).await;
    create_note(&app, &bob, json!({"title": "Bob note", "content": "hello"})).await;
    settle_index().await;

    let (status, stats) = send(&app, "GET", "/api/search/stats", Some(&ada), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(stats["enabled"], json!(true));
    assert_eq!(stats["model"], json!("hash-test"));
    assert_eq!(stats["dimensions"], json!(HASH_EMBED_DIMS));
    // Coverage is per-user: ada sees only her two text notes (not the text-less
    // one, and not bob's).
    assert_eq!(stats["total_notes"], json!(2));
    assert_eq!(stats["indexed_notes"], json!(2));
}

#[tokio::test]
async fn search_stats_report_disabled_when_search_is_off() {
    let app = app().await; // no search service wired
    let (ada, _) = register(&app, "ada").await;
    let (status, stats) = send(&app, "GET", "/api/search/stats", Some(&ada), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(stats, json!({ "enabled": false }));
}

#[tokio::test]
async fn reindex_reports_total_and_tracks_progress() {
    let app = build_app(state_with_search().await);
    let (ada, _) = register(&app, "ada").await;
    create_note(&app, &ada, json!({"title": "One", "content": "first"})).await;
    create_note(&app, &ada, json!({"title": "Two", "content": "second"})).await;

    let (status, body) = send(&app, "POST", "/api/search/reindex", Some(&ada), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["total"], json!(2));

    // The worker runs in the background; give it a beat, then the status
    // endpoint reports it finished (done == total, no longer running).
    settle_index().await;
    let (status, prog) = send(&app, "GET", "/api/search/reindex/status", Some(&ada), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(prog["total"], json!(2));
    assert_eq!(prog["done"], json!(2));
    assert_eq!(prog["running"], json!(false));
}

#[tokio::test]
async fn reindex_status_is_idle_before_any_run() {
    let app = build_app(state_with_search().await);
    let (ada, _) = register(&app, "ada").await;
    let (status, prog) = send(&app, "GET", "/api/search/reindex/status", Some(&ada), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(prog, json!({ "running": false, "done": 0, "total": 0 }));
}

#[tokio::test]
async fn reindex_reports_unavailable_when_disabled() {
    let app = app().await; // no search service wired
    let (ada, _) = register(&app, "ada").await;
    let (status, _) = send(&app, "POST", "/api/search/reindex", Some(&ada), None).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
}
