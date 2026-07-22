use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use tokio::sync::broadcast;

/// In-process fan-out of change events to connected clients, keyed by user.
/// A user may have several live connections (tabs, phone + web).
#[derive(Clone, Default)]
pub struct Hub {
    inner: Arc<Mutex<HashMap<String, broadcast::Sender<String>>>>,
}

impl Hub {
    pub fn subscribe(&self, user_id: &str) -> broadcast::Receiver<String> {
        let mut map = self.inner.lock().unwrap();
        map.entry(user_id.to_string())
            .or_insert_with(|| broadcast::channel(64).0)
            .subscribe()
    }

    pub fn notify(&self, user_ids: &[String], message: &str) {
        let mut map = self.inner.lock().unwrap();
        for user_id in user_ids {
            if let Some(sender) = map.get(user_id)
                && sender.send(message.to_string()).is_err()
            {
                // No live receivers left for this user.
                map.remove(user_id);
            }
        }
    }
}
