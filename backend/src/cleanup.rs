//! Durable reconciliation of state that lives outside relational SQLite.
//!
//! Destructive repository transactions enqueue idempotent jobs before they
//! commit. This worker attempts them immediately and periodically retries any
//! transient object-store or vector-index failure after process restarts.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use crate::AppState;
use crate::store::{CleanupJob, CleanupKind};

const BATCH_SIZE: u32 = 100;
const WORKER_INTERVAL: Duration = Duration::from_secs(30);
const MAX_RETRY_SECS: i64 = 60 * 60;

struct RunningGuard(Arc<AtomicBool>);

impl Drop for RunningGuard {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

impl AppState {
    /// Attempt every currently due cleanup job. Only one drain runs per
    /// process; jobs remain durable when another caller is already working.
    pub async fn drain_cleanup_jobs(&self) {
        if self
            .cleanup_running
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return;
        }
        let _guard = RunningGuard(self.cleanup_running.clone());

        loop {
            let jobs = match self
                .repo
                .due_cleanup_jobs(chrono::Utc::now().timestamp(), BATCH_SIZE)
                .await
            {
                Ok(jobs) => jobs,
                Err(error) => {
                    self.report_background_failure("cleanup_queue_read", &format!("{error:?}"));
                    return;
                }
            };
            if jobs.is_empty() {
                return;
            }

            let mut completed_any = false;
            for job in jobs {
                // Vector jobs are intentionally deferred while semantic search
                // is disabled. They become runnable on a later start with the
                // service configured, without being mislabeled as failures.
                if matches!(
                    job.kind,
                    CleanupKind::NoteVector | CleanupKind::WorkspaceVectors
                ) && self.search.is_none()
                {
                    continue;
                }
                match self.execute_cleanup(&job).await {
                    Ok(()) => {
                        completed_any = true;
                        if let Err(error) = self.repo.complete_cleanup_job(job.id).await {
                            self.report_background_failure(
                                "cleanup_completion",
                                &format!("{error:?}"),
                            );
                            return;
                        }
                    }
                    Err(error) => {
                        let shift = job.attempts.min(9);
                        let delay = (5_i64 * (1_i64 << shift)).min(MAX_RETRY_SECS);
                        let next = chrono::Utc::now().timestamp() + delay;
                        let message = format!("{error:#}");
                        if let Err(repo_error) =
                            self.repo.retry_cleanup_job(job.id, &message, next).await
                        {
                            self.report_background_failure(
                                "cleanup_retry_persist",
                                &format!("{repo_error:?}"),
                            );
                            return;
                        }
                        self.report_background_failure(
                            job.kind.as_str(),
                            &format!("retrying in {delay}s: {message}"),
                        );
                    }
                }
            }

            // A batch containing only deferred vector jobs would otherwise
            // spin forever while search is deliberately disabled.
            if !completed_any {
                return;
            }
        }
    }

    async fn execute_cleanup(&self, job: &CleanupJob) -> anyhow::Result<()> {
        match job.kind {
            CleanupKind::AttachmentBlob => self.files.delete(&job.target_id).await,
            CleanupKind::NoteVector => {
                let search = self
                    .search
                    .as_ref()
                    .ok_or_else(|| anyhow::anyhow!("semantic index unavailable"))?;
                search.remove_note(&job.target_id).await
            }
            CleanupKind::WorkspaceVectors => {
                let search = self
                    .search
                    .as_ref()
                    .ok_or_else(|| anyhow::anyhow!("semantic index unavailable"))?;
                search.remove_workspace(&job.target_id).await
            }
        }
    }
}

/// Run once at startup, then periodically. Request handlers also trigger an
/// immediate drain after destructive transactions so the common path remains
/// prompt while this loop supplies crash recovery.
pub fn spawn_cleanup_worker(state: AppState) {
    tokio::spawn(async move {
        state.drain_cleanup_jobs().await;
        let mut interval = tokio::time::interval(WORKER_INTERVAL);
        interval.tick().await;
        loop {
            interval.tick().await;
            state.drain_cleanup_jobs().await;
        }
    });
}
