use std::path::PathBuf;

use hmac::{Hmac, Mac};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

/// How long a freshly minted file URL stays valid. The issue time is floored to
/// the hour (see [`signed_file_path`]) so the URL is byte-stable within each
/// clock hour — the browser reuses its cache across the app's frequent note
/// refetches instead of re-downloading every image — while a leaked URL still
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
/// it expires — that is the point, it lets plain `<img>`/`<audio>` loads work —
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

/// Attachment blobs on local disk, named by their unguessable id. Kept
/// deliberately separate from [`crate::store::Repository`]: object storage is
/// its own swap point.
#[derive(Clone)]
pub struct FileStore {
    dir: PathBuf,
}

impl FileStore {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    fn path(&self, id: &str) -> PathBuf {
        // Ids are server-generated UUIDs, but never trust a path component.
        let safe: String = id.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').collect();
        self.dir.join(safe)
    }

    pub async fn save(&self, id: &str, bytes: &[u8]) -> anyhow::Result<()> {
        tokio::fs::create_dir_all(&self.dir).await?;
        tokio::fs::write(self.path(id), bytes).await?;
        Ok(())
    }

    pub async fn read(&self, id: &str) -> Option<Vec<u8>> {
        tokio::fs::read(self.path(id)).await.ok()
    }

    pub async fn delete(&self, id: &str) {
        let _ = tokio::fs::remove_file(self.path(id)).await;
    }
}
