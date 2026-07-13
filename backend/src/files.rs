use std::path::PathBuf;

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
