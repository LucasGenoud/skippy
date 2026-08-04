//! Small in-process attempt limiter for expensive unauthenticated auth paths.
//!
//! SQLite deployments run one server process, so a bounded memory window is
//! sufficient here. The limiter deliberately keys login attempts by normalized
//! email: it protects each account without trusting proxy-supplied IP headers.

use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const MAX_TRACKED_KEYS: usize = 4096;
const MAX_IDLE: Duration = Duration::from_secs(5 * 60);

#[derive(Default)]
pub struct AttemptLimiter {
    attempts: Mutex<HashMap<String, VecDeque<Instant>>>,
}

impl AttemptLimiter {
    /// Record an attempt or return the number of seconds until the oldest
    /// attempt leaves the window.
    pub fn check(&self, key: &str, maximum: usize, window: Duration) -> Result<(), u64> {
        let now = Instant::now();
        let mut attempts = self.attempts.lock().unwrap();
        attempts.retain(|_, entries| {
            entries
                .back()
                .is_some_and(|instant| now.duration_since(*instant) < MAX_IDLE)
        });
        if !attempts.contains_key(key) && attempts.len() >= MAX_TRACKED_KEYS {
            let oldest = attempts
                .iter()
                .filter_map(|(key, entries)| entries.back().map(|instant| (key.clone(), *instant)))
                .min_by_key(|(_, instant)| *instant)
                .map(|(key, _)| key);
            if let Some(oldest) = oldest {
                attempts.remove(&oldest);
            }
        }
        let entries = attempts.entry(key.to_string()).or_default();
        while entries
            .front()
            .is_some_and(|instant| now.duration_since(*instant) >= window)
        {
            entries.pop_front();
        }
        if entries.len() >= maximum {
            let elapsed = now.duration_since(*entries.front().expect("non-empty at limit"));
            return Err(window.saturating_sub(elapsed).as_secs().max(1));
        }
        entries.push_back(now);
        Ok(())
    }

    pub fn reset(&self, key: &str) {
        self.attempts.lock().unwrap().remove(key);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attempts_are_bounded_per_key() {
        let limiter = AttemptLimiter::default();
        let window = Duration::from_secs(60);
        assert!(limiter.check("a", 2, window).is_ok());
        assert!(limiter.check("a", 2, window).is_ok());
        assert!(limiter.check("a", 2, window).is_err());
        assert!(limiter.check("b", 2, window).is_ok());
        limiter.reset("a");
        assert!(limiter.check("a", 2, window).is_ok());
    }
}
