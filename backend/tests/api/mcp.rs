use crate::helpers::*;

/// Creates a personal access token and returns its secret.
async fn api_token(app: &Router, session: &str, scope: &str) -> String {
    let (status, body) = send(
        app,
        "POST",
        "/api/tokens",
        Some(session),
        Some(json!({"name":"Claude","scope":scope})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    body["secret"].as_str().unwrap().to_string()
}

async fn rpc(app: &Router, token: &str, method: &str, params: Value) -> (StatusCode, Value) {
    send(
        app,
        "POST",
        "/api/mcp",
        Some(token),
        Some(json!({"jsonrpc":"2.0","id":7,"method":method,"params":params})),
    )
    .await
}

/// Calls a tool and returns its result: `structuredContent` plus `isError`.
async fn call(app: &Router, token: &str, name: &str, arguments: Value) -> Value {
    let (status, body) = rpc(
        app,
        token,
        "tools/call",
        json!({"name":name,"arguments":arguments}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["id"], 7);
    body["result"].clone()
}

fn tool_names(list: &Value) -> Vec<String> {
    list["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tool| tool["name"].as_str().unwrap().to_string())
        .collect()
}

#[tokio::test]
async fn tokens_are_shown_once_and_revocable_by_their_owner_only() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;

    let secret = api_token(&app, &ada, "read").await;
    assert!(secret.starts_with("skp_"));

    let (status, list) = send(&app, "GET", "/api/tokens", Some(&ada), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(list[0]["name"], "Claude");
    assert_eq!(list[0]["scope"], "read");
    assert!(list[0].get("secret").is_none());
    assert!(!list.to_string().contains(&secret));
    let id = list[0]["id"].as_str().unwrap();

    let (status, _) = send(&app, "GET", "/api/tokens", Some(&bob), None).await;
    assert_eq!(status, StatusCode::OK);
    let path = format!("/api/tokens/{id}");
    let (status, _) = send(&app, "DELETE", &path, Some(&bob), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = rpc(&app, &secret, "ping", json!({})).await;
    assert_eq!(status, StatusCode::OK);

    let (status, _) = send(&app, "DELETE", &path, Some(&ada), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _) = rpc(&app, &secret, "ping", json!({})).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn tokens_and_sessions_do_not_open_each_others_doors() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let secret = api_token(&app, &ada, "write").await;

    let (status, _) = rpc(&app, &ada, "ping", json!({})).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _) = send(&app, "GET", "/api/notes", Some(&secret), None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    // A token cannot mint more tokens.
    let (status, _) = send(
        &app,
        "POST",
        "/api/tokens",
        Some(&secret),
        Some(json!({"name":"x","scope":"write"})),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn token_requests_are_validated() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    for body in [
        json!({"name":" ","scope":"read"}),
        json!({"name":"x","scope":"admin"}),
    ] {
        let (status, _) = send(&app, "POST", "/api/tokens", Some(&ada), Some(body)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
}

#[tokio::test]
async fn mcp_handshake_negotiates_and_accepts_notifications() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let secret = api_token(&app, &ada, "read").await;

    let (status, body) = rpc(
        &app,
        &secret,
        "initialize",
        json!({"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["jsonrpc"], "2.0");
    assert_eq!(body["result"]["protocolVersion"], "2025-06-18");
    assert_eq!(body["result"]["serverInfo"]["name"], "skippy");
    assert!(body["result"]["capabilities"]["tools"].is_object());

    let (status, body) = rpc(
        &app,
        &secret,
        "initialize",
        json!({"protocolVersion":"1999-01-01","capabilities":{}}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_ne!(body["result"]["protocolVersion"], "1999-01-01");

    let (status, body) = send(
        &app,
        "POST",
        "/api/mcp",
        Some(&secret),
        Some(json!({"jsonrpc":"2.0","method":"notifications/initialized"})),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(body, Value::Null);

    let (status, body) = rpc(&app, &secret, "resources/list", json!({})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["error"]["code"], -32601);

    let (status, _) = send(&app, "GET", "/api/mcp", Some(&secret), None).await;
    assert_eq!(status, StatusCode::METHOD_NOT_ALLOWED);
}

#[tokio::test]
async fn read_tokens_are_offered_and_allowed_only_read_tools() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let read = api_token(&app, &ada, "read").await;
    let write = api_token(&app, &ada, "write").await;

    let (_, list) = rpc(&app, &read, "tools/list", json!({})).await;
    let read_tools = tool_names(&list);
    assert!(read_tools.contains(&"search_notes".to_string()));
    assert!(!read_tools.contains(&"create_note".to_string()));
    let (_, list) = rpc(&app, &write, "tools/list", json!({})).await;
    assert!(tool_names(&list).contains(&"create_note".to_string()));

    let result = call(&app, &read, "create_note", json!({"title":"Nope"})).await;
    assert_eq!(result["isError"], true);
    let (_, notes) = send(&app, "GET", "/api/notes", Some(&ada), None).await;
    assert_eq!(notes, json!([]));
}

#[tokio::test]
async fn read_tools_see_what_the_account_sees() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let secret = api_token(&app, &ada, "read").await;
    let target = create_note(&app, &ada, json!({"title":"Groceries"})).await;
    let target_id = target["id"].as_str().unwrap();
    let plan = create_note(
        &app,
        &ada,
        json!({"title":"Plan","content":format!("buy the [[{target_id}|Groceries]] on friday")}),
    )
    .await;
    let hidden = create_note(&app, &bob, json!({"title":"Bob's friday"})).await;

    let found = call(&app, &secret, "search_notes", json!({"query":"FRIDAY"})).await;
    assert_eq!(found["isError"], false, "{found}");
    let hits = found["structuredContent"]["notes"].as_array().unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0]["id"], plan["id"]);

    let note = call(&app, &secret, "get_note", json!({"id":plan["id"]})).await;
    let note = &note["structuredContent"];
    assert_eq!(note["title"], "Plan");
    assert_eq!(note["text"], "buy the Groceries on friday");
    assert_eq!(note["links"][0]["id"], target_id);
    assert_eq!(note["workspace"], "My notes");

    let denied = call(&app, &secret, "get_note", json!({"id":hidden["id"]})).await;
    assert_eq!(denied["isError"], true);

    let listed = call(&app, &secret, "list_notes", json!({})).await;
    assert_eq!(
        listed["structuredContent"]["notes"]
            .as_array()
            .unwrap()
            .len(),
        2
    );

    let workspaces = call(&app, &secret, "list_workspaces", json!({})).await;
    let workspaces = workspaces["structuredContent"]["workspaces"].clone();
    assert_eq!(workspaces[0]["name"], "My notes");
    assert_eq!(workspaces[0]["collections"][0]["name"], "General");
}

#[tokio::test]
async fn write_tools_create_and_append_through_the_note_pipeline() {
    let app = app().await;
    let (ada, _) = register(&app, "ada").await;
    let secret = api_token(&app, &ada, "write").await;
    let (_, labels) = send(
        &app,
        "POST",
        "/api/labels",
        Some(&ada),
        Some(json!({"name":"Home"})),
    )
    .await;

    let created = call(
        &app,
        &secret,
        "create_note",
        json!({"title":"Shopping","kind":"checklist","items":["Milk"],"labels":["home","Nope"]}),
    )
    .await;
    assert_eq!(created["isError"], false, "{created}");
    let id = created["structuredContent"]["id"]
        .as_str()
        .unwrap()
        .to_string();
    assert_eq!(
        created["structuredContent"]["unknown_labels"],
        json!(["Nope"])
    );

    let appended = call(
        &app,
        &secret,
        "append_to_note",
        json!({"id":id,"items":["Eggs"]}),
    )
    .await;
    assert_eq!(appended["isError"], false, "{appended}");

    let (_, note) = send(&app, "GET", &format!("/api/notes/{id}"), Some(&ada), None).await;
    let items: Vec<&str> = note["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["text"].as_str().unwrap())
        .collect();
    assert_eq!(items, ["Milk", "Eggs"]);
    assert_eq!(note["label_ids"], json!([labels["id"]]));

    let text = call(&app, &secret, "create_note", json!({"content":"hello"})).await;
    let text_id = text["structuredContent"]["id"].as_str().unwrap();
    call(
        &app,
        &secret,
        "append_to_note",
        json!({"id":text_id,"text":"world"}),
    )
    .await;
    let (_, note) = send(
        &app,
        "GET",
        &format!("/api/notes/{text_id}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(note["content"], "hello\nworld");
}

#[tokio::test]
async fn semantic_search_ranks_by_meaning_within_what_the_account_sees() {
    let app = build_app(state_with_search().await);
    let (ada, _) = register(&app, "ada").await;
    let (bob, _) = register(&app, "bob").await;
    let secret = api_token(&app, &ada, "read").await;
    let groceries = create_note(
        &app,
        &ada,
        json!({"title":"Groceries","content":"buy milk eggs and bread at the market"}),
    )
    .await;
    create_note(
        &app,
        &ada,
        json!({"title":"Report","content":"finish the business slides"}),
    )
    .await;
    create_note(
        &app,
        &bob,
        json!({"title":"Bob","content":"milk bread milk bread"}),
    )
    .await;
    settle_index().await;

    let found = call(&app, &secret, "search_notes", json!({"query":"milk bread"})).await;
    let hits = found["structuredContent"]["notes"].as_array().unwrap();

    assert_eq!(hits[0]["id"], groceries["id"]);
    assert!(hits.iter().all(|h| h["title"] != "Bob"));
}
