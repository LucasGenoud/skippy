//! S3Store against an in-process fake S3 server: exercises the real signed
//! HTTP pipeline (reqwest + SigV4 headers) and the lazy per-user bucket
//! creation, without needing a running Garage. The signature VALUES are
//! covered by the AWS test vector in `files::tests`; here we assert shape and
//! behavior.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use axum::Router;
use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::routing::put;

use sticky_notes_server::files::{FileStore, S3Config, S3Store};

#[derive(Default)]
struct FakeS3 {
    buckets: Mutex<HashSet<String>>,
    objects: Mutex<HashMap<(String, String), Vec<u8>>>,
    /// Every CreateBucket call, so tests can assert the ensured-cache works.
    bucket_creates: Mutex<Vec<String>>,
    last_authorization: Mutex<Option<String>>,
}

impl FakeS3 {
    fn record_auth(&self, headers: &HeaderMap) {
        let auth = headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .map(String::from);
        *self.last_authorization.lock().unwrap() = auth;
    }
}

async fn create_bucket(
    State(s3): State<Arc<FakeS3>>,
    Path(bucket): Path<String>,
    headers: HeaderMap,
) -> StatusCode {
    s3.record_auth(&headers);
    s3.bucket_creates.lock().unwrap().push(bucket.clone());
    if s3.buckets.lock().unwrap().insert(bucket) {
        StatusCode::OK
    } else {
        StatusCode::CONFLICT
    }
}

async fn put_object(
    State(s3): State<Arc<FakeS3>>,
    Path((bucket, key)): Path<(String, String)>,
    headers: HeaderMap,
    body: Bytes,
) -> StatusCode {
    s3.record_auth(&headers);
    if !s3.buckets.lock().unwrap().contains(&bucket) {
        return StatusCode::NOT_FOUND;
    }
    s3.objects
        .lock()
        .unwrap()
        .insert((bucket, key), body.to_vec());
    StatusCode::OK
}

async fn get_object(
    State(s3): State<Arc<FakeS3>>,
    Path((bucket, key)): Path<(String, String)>,
) -> (StatusCode, Vec<u8>) {
    match s3.objects.lock().unwrap().get(&(bucket, key)) {
        Some(bytes) => (StatusCode::OK, bytes.clone()),
        None => (StatusCode::NOT_FOUND, Vec::new()),
    }
}

async fn delete_object(
    State(s3): State<Arc<FakeS3>>,
    Path((bucket, key)): Path<(String, String)>,
) -> StatusCode {
    s3.objects.lock().unwrap().remove(&(bucket, key));
    StatusCode::NO_CONTENT
}

async fn spawn_fake_s3() -> (Arc<FakeS3>, String) {
    let s3 = Arc::new(FakeS3::default());
    let router = Router::new()
        .route("/{bucket}", put(create_bucket))
        .route(
            "/{bucket}/{key}",
            put(put_object).get(get_object).delete(delete_object),
        )
        .with_state(s3.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    (s3, format!("http://{addr}"))
}

fn store(url: &str) -> S3Store {
    S3Store::new(S3Config {
        url: url.to_string(),
        region: "garage".to_string(),
        access_key: "GKtestkey".to_string(),
        secret_key: "testsecret".to_string(),
        bucket_prefix: "test-".to_string(),
    })
    .unwrap()
}

#[tokio::test]
async fn save_read_delete_roundtrip_with_lazy_bucket() {
    let (s3, url) = spawn_fake_s3().await;
    let store = store(&url);

    store.save("att-1", b"hello").await.unwrap();
    store.save("att-2", b"world").await.unwrap();

    // The installation-wide attachment bucket is created only once.
    assert_eq!(
        *s3.bucket_creates.lock().unwrap(),
        vec!["test-attachments".to_string()]
    );
    assert!(
        s3.objects
            .lock()
            .unwrap()
            .contains_key(&("test-attachments".to_string(), "att-1".to_string()))
    );

    assert_eq!(store.read("att-1").await, Some(b"hello".to_vec()));
    assert_eq!(store.read("missing").await, None);

    store.delete("att-1").await.unwrap();
    assert_eq!(store.read("att-1").await, None);
    assert_eq!(store.read("att-2").await, Some(b"world".to_vec()));

    let auth = s3
        .last_authorization
        .lock()
        .unwrap()
        .clone()
        .expect("requests are signed");
    assert!(
        auth.starts_with("AWS4-HMAC-SHA256 Credential=GKtestkey/"),
        "{auth}"
    );
    assert!(auth.contains("/garage/s3/aws4_request"), "{auth}");
    assert!(
        auth.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date"),
        "{auth}"
    );
}

#[tokio::test]
async fn existing_bucket_is_tolerated() {
    let (s3, url) = spawn_fake_s3().await;
    s3.buckets
        .lock()
        .unwrap()
        .insert("test-attachments".to_string());

    // A fresh process (empty ensured-cache) meets the existing bucket: the
    // CreateBucket 409 must be treated as "already there", not an error.
    let store = store(&url);
    store.save("att", b"bytes").await.unwrap();
    assert_eq!(store.read("att").await, Some(b"bytes".to_vec()));
}
