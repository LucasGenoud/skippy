use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use async_trait::async_trait;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

/// How long a freshly minted file URL stays valid. The issue time is floored to
/// the hour (see [`signed_file_path`]) so the URL is byte-stable within each
/// clock hour, the browser reuses its cache across the app's frequent note
/// refetches instead of re-downloading every image, while a leaked URL still
/// stops working within this window.
const FILE_URL_TTL_SECS: i64 = 6 * 3600;
const FILE_URL_STEP_SECS: i64 = 3600;

/// HMAC over the attachment id and expiry, hex-encoded. Public so tests can
/// forge/expire signatures; production callers use [`signed_file_path`] and
/// [`verify_file_access`].
pub fn file_signature(secret: &[u8], attachment_id: &str, exp: i64) -> String {
    let mut mac = HmacSha256::new_from_slice(secret).expect("HMAC accepts any key length");
    mac.update(attachment_id.as_bytes());
    mac.update(b"\n");
    mac.update(exp.to_string().as_bytes());
    hex::encode(mac.finalize().into_bytes())
}

/// A signed, time-limited path for [`crate::handlers::serve_file`]. Relative to
/// the server origin so it resolves whether the app is served same-origin or
/// from a separate dev host. Anyone holding this URL can fetch the bytes until
/// it expires, that is the point, it lets plain `<img>`/`<audio>` loads work,
/// but only a note's participants are ever handed one (it is minted into note
/// views, which are access-checked).
pub fn signed_file_path(secret: &[u8], attachment_id: &str) -> String {
    let now = chrono::Utc::now().timestamp();
    let exp = now - now.rem_euclid(FILE_URL_STEP_SECS) + FILE_URL_TTL_SECS;
    let sig = file_signature(secret, attachment_id, exp);
    format!("/api/files/{attachment_id}?exp={exp}&sig={sig}")
}

/// Constant-time check that `sig` is a valid signature for `attachment_id` at
/// `exp`, and that `exp` has not passed. The signature covers `exp`, so a
/// client cannot extend its own access by editing the query string.
pub fn verify_file_access(secret: &[u8], attachment_id: &str, exp: i64, sig: &str) -> bool {
    if exp < chrono::Utc::now().timestamp() {
        return false;
    }
    let Ok(provided) = hex::decode(sig) else {
        return false;
    };
    let mut mac = HmacSha256::new_from_slice(secret).expect("HMAC accepts any key length");
    mac.update(attachment_id.as_bytes());
    mac.update(b"\n");
    mac.update(exp.to_string().as_bytes());
    mac.verify_slice(&provided).is_ok()
}

/// Attachment blob storage. Kept deliberately separate from
/// [`crate::store::Repository`]: object storage is its own swap point, and
/// `main` picks the implementation from `STICKY_NOTES_STORAGE`.
///
/// Attachment ids are globally unique and relational ownership flows through
/// attachment -> note -> workspace. The blob layer needs no second ownership
/// namespace.
#[async_trait]
pub trait FileStore: Send + Sync {
    async fn save(&self, id: &str, bytes: &[u8]) -> anyhow::Result<()>;
    /// `None` for missing blobs; backends log unexpected failures themselves,
    /// since callers can only translate `None` into a 404.
    async fn read(&self, id: &str) -> Option<Vec<u8>>;
    /// Idempotent deletion. Missing blobs count as success; transient storage
    /// failures are returned so the durable cleanup worker can retry them.
    async fn delete(&self, id: &str) -> anyhow::Result<()>;
}

/// Ids are server-generated UUIDs, but never trust a path component.
fn safe_component(id: &str) -> String {
    id.chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
        .collect()
}

/// Attachment blobs on local disk, named by their unguessable id. The default
/// backend; the directory stays flat.
#[derive(Clone)]
pub struct DiskStore {
    dir: PathBuf,
}

impl DiskStore {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    fn path(&self, id: &str) -> PathBuf {
        self.dir.join(safe_component(id))
    }
}

#[async_trait]
impl FileStore for DiskStore {
    async fn save(&self, id: &str, bytes: &[u8]) -> anyhow::Result<()> {
        tokio::fs::create_dir_all(&self.dir).await?;
        tokio::fs::write(self.path(id), bytes).await?;
        Ok(())
    }

    async fn read(&self, id: &str) -> Option<Vec<u8>> {
        tokio::fs::read(self.path(id)).await.ok()
    }

    async fn delete(&self, id: &str) -> anyhow::Result<()> {
        match tokio::fs::remove_file(self.path(id)).await {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.into()),
        }
    }
}

// ---------------------------------------------------------------------------
// S3 backend

/// Connection settings for [`S3Store`], read from `STICKY_NOTES_S3_*` env vars
/// in `main`. Works against any S3-compatible endpoint; the bundled
/// docker-compose wires it to a Garage instance.
pub struct S3Config {
    /// Endpoint origin, e.g. `http://garage:3900`. Requests are path-style
    /// (`{url}/{bucket}/{key}`), which is what Garage and MinIO expect.
    pub url: String,
    pub region: String,
    pub access_key: String,
    pub secret_key: String,
    /// The installation-wide bucket is `{prefix}attachments`.
    pub bucket_prefix: String,
}

/// Attachment blobs in one S3-compatible object-store bucket. Relational
/// ownership remains in SQLite; globally unique attachment ids are object keys.
///
/// Requests are signed with a hand-rolled AWS Signature V4 rather than an AWS
/// SDK: the app only ever needs four calls (put/get/delete object, create
/// bucket) on ASCII-safe paths with no query strings, and `hmac`/`sha2`/
/// `reqwest` are already in the tree, matching how the LLM, Whisper and
/// notification clients are plain reqwest too.
pub struct S3Store {
    client: reqwest::Client,
    base: reqwest::Url,
    /// Exactly the Host header reqwest will send (port elided when it is the
    /// scheme default), SigV4 signs it, so the two must agree.
    host: String,
    /// Path prefix of the endpoint URL, for endpoints served under a subpath
    /// behind a reverse proxy. Empty for a root endpoint like Garage's.
    path_prefix: String,
    cfg: S3Config,
    /// Buckets confirmed to exist, so only the first upload per process
    /// pays the CreateBucket round-trip. Never held across an await.
    ensured: Mutex<HashSet<String>>,
}

impl S3Store {
    pub fn new(cfg: S3Config) -> anyhow::Result<Self> {
        let base = reqwest::Url::parse(&cfg.url)
            .map_err(|e| anyhow::anyhow!("invalid S3 endpoint {}: {e}", cfg.url))?;
        let host = base
            .host_str()
            .ok_or_else(|| anyhow::anyhow!("S3 endpoint {} has no host", cfg.url))?
            .to_string();
        let host = match base.port() {
            Some(port) => format!("{host}:{port}"),
            None => host,
        };
        let path_prefix = base.path().trim_end_matches('/').to_string();
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(60))
            .build()?;
        Ok(Self {
            client,
            base,
            host,
            path_prefix,
            cfg,
            ensured: Mutex::new(HashSet::new()),
        })
    }

    fn attachment_bucket(&self) -> String {
        format!("{}attachments", self.cfg.bucket_prefix)
    }

    /// One signed S3 request. `path` is the canonical path (`/bucket` or
    /// `/bucket/key`), components already sanitized, so no percent-encoding
    /// is ever needed and the signed path always matches the sent path.
    async fn request(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Vec<u8>,
    ) -> anyhow::Result<reqwest::Response> {
        let path = format!("{}{path}", self.path_prefix);
        let amz_date = chrono::Utc::now().format("%Y%m%dT%H%M%SZ").to_string();
        let payload_hash = sha256_hex(&body);
        // SigV4 wants signed headers in sorted order; these three stay sorted.
        let headers = [
            ("host", self.host.as_str()),
            ("x-amz-content-sha256", &payload_hash),
            ("x-amz-date", &amz_date),
        ];
        let authorization = sigv4_authorization(
            &self.cfg.access_key,
            &self.cfg.secret_key,
            &self.cfg.region,
            method.as_str(),
            &path,
            &headers,
            &payload_hash,
            &amz_date,
        );
        let mut url = self.base.clone();
        url.set_path(&path);
        let resp = self
            .client
            .request(method, url)
            .header("x-amz-content-sha256", &payload_hash)
            .header("x-amz-date", &amz_date)
            .header(reqwest::header::AUTHORIZATION, authorization)
            .body(body)
            .send()
            .await?;
        Ok(resp)
    }

    /// Create the bucket if this process hasn't confirmed it exists yet.
    /// 409 counts as success: the bucket already exists (Garage returns it
    /// when the alias is taken), and if it belongs to someone else the
    /// following PutObject fails with the real error anyway.
    async fn ensure_bucket(&self, bucket: &str) -> anyhow::Result<()> {
        if self.ensured.lock().unwrap().contains(bucket) {
            return Ok(());
        }
        let resp = self
            .request(reqwest::Method::PUT, &format!("/{bucket}"), Vec::new())
            .await?;
        let status = resp.status();
        if !status.is_success() && status != reqwest::StatusCode::CONFLICT {
            anyhow::bail!(
                "creating bucket {bucket} failed: {status} {}",
                resp.text().await.unwrap_or_default()
            );
        }
        self.ensured.lock().unwrap().insert(bucket.to_string());
        Ok(())
    }

    fn object_path(&self, id: &str) -> String {
        format!("/{}/{}", self.attachment_bucket(), safe_component(id))
    }
}

#[async_trait]
impl FileStore for S3Store {
    async fn save(&self, id: &str, bytes: &[u8]) -> anyhow::Result<()> {
        let bucket = self.attachment_bucket();
        self.ensure_bucket(&bucket).await?;
        let path = self.object_path(id);
        let resp = self
            .request(reqwest::Method::PUT, &path, bytes.to_vec())
            .await?;
        let status = resp.status();
        if !status.is_success() {
            anyhow::bail!(
                "s3 upload of {id} failed: {status} {}",
                resp.text().await.unwrap_or_default()
            );
        }
        Ok(())
    }

    async fn read(&self, id: &str) -> Option<Vec<u8>> {
        let path = self.object_path(id);
        let resp = match self.request(reqwest::Method::GET, &path, Vec::new()).await {
            Ok(resp) => resp,
            Err(e) => {
                eprintln!("s3 read of {id} failed: {e:#}");
                return None;
            }
        };
        let status = resp.status();
        if status.is_success() {
            return resp.bytes().await.ok().map(|b| b.to_vec());
        }
        if status != reqwest::StatusCode::NOT_FOUND {
            eprintln!("s3 read of {id} failed: {status}");
        }
        None
    }

    async fn delete(&self, id: &str) -> anyhow::Result<()> {
        let path = self.object_path(id);
        let resp = self
            .request(reqwest::Method::DELETE, &path, Vec::new())
            .await?;
        let status = resp.status();
        if status.is_success() || status == reqwest::StatusCode::NOT_FOUND {
            return Ok(());
        }
        anyhow::bail!(
            "s3 delete of {id} failed: {status} {}",
            resp.text().await.unwrap_or_default()
        )
    }
}

fn sha256_hex(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}

fn hmac_sha256(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

/// AWS Signature Version 4 `Authorization` header for an S3 request with no
/// query string. `headers` are the signed headers: lowercase names, sorted,
/// values trimmed, the caller sends exactly these. Pure so tests can check it
/// against AWS's documented example signature.
#[allow(clippy::too_many_arguments)]
fn sigv4_authorization(
    access_key: &str,
    secret_key: &str,
    region: &str,
    method: &str,
    path: &str,
    headers: &[(&str, &str)],
    payload_hash: &str,
    amz_date: &str,
) -> String {
    let date = &amz_date[..8];
    let mut canonical_headers = String::new();
    for (name, value) in headers {
        canonical_headers.push_str(name);
        canonical_headers.push(':');
        canonical_headers.push_str(value);
        canonical_headers.push('\n');
    }
    let signed_headers = headers
        .iter()
        .map(|(name, _)| *name)
        .collect::<Vec<_>>()
        .join(";");
    // The empty line after `path` is the (empty) canonical query string.
    let canonical_request =
        format!("{method}\n{path}\n\n{canonical_headers}\n{signed_headers}\n{payload_hash}");
    let scope = format!("{date}/{region}/s3/aws4_request");
    let string_to_sign = format!(
        "AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{}",
        sha256_hex(canonical_request.as_bytes())
    );
    let mut key = hmac_sha256(format!("AWS4{secret_key}").as_bytes(), date.as_bytes());
    for part in [region, "s3", "aws4_request"] {
        key = hmac_sha256(&key, part.as_bytes());
    }
    let signature = hex::encode(hmac_sha256(&key, string_to_sign.as_bytes()));
    format!(
        "AWS4-HMAC-SHA256 Credential={access_key}/{scope}, SignedHeaders={signed_headers}, Signature={signature}"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The worked "GET Object" example from AWS's SigV4 documentation, the
    /// one fixed vector every SigV4 implementation is checked against.
    #[test]
    fn sigv4_matches_aws_documented_example() {
        const EMPTY_SHA256: &str =
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
        let auth = sigv4_authorization(
            "AKIAIOSFODNN7EXAMPLE",
            "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "us-east-1",
            "GET",
            "/test.txt",
            &[
                ("host", "examplebucket.s3.amazonaws.com"),
                ("range", "bytes=0-9"),
                ("x-amz-content-sha256", EMPTY_SHA256),
                ("x-amz-date", "20130524T000000Z"),
            ],
            EMPTY_SHA256,
            "20130524T000000Z",
        );
        assert_eq!(
            auth,
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, \
             SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, \
             Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        );
    }

    #[test]
    fn attachment_bucket_is_installation_scoped() {
        let store = S3Store::new(S3Config {
            url: "http://garage:3900".to_string(),
            region: "garage".to_string(),
            access_key: "GK".to_string(),
            secret_key: "sk".to_string(),
            bucket_prefix: "sticky-notes-".to_string(),
        })
        .unwrap();
        assert_eq!(store.attachment_bucket(), "sticky-notes-attachments");
        assert_eq!(
            store.object_path("att/../2"),
            "/sticky-notes-attachments/att2"
        );
    }

    #[test]
    fn endpoint_host_keeps_explicit_port() {
        let store = |url: &str| {
            S3Store::new(S3Config {
                url: url.to_string(),
                region: "garage".to_string(),
                access_key: "GK".to_string(),
                secret_key: "sk".to_string(),
                bucket_prefix: "b-".to_string(),
            })
            .unwrap()
        };
        assert_eq!(store("http://garage:3900").host, "garage:3900");
        // Scheme-default ports are elided, matching what reqwest sends.
        assert_eq!(store("https://s3.example.com").host, "s3.example.com");
        assert_eq!(
            store("https://s3.example.com/subpath/").path_prefix,
            "/subpath"
        );
    }
}
