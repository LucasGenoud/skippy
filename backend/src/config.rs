//! Server-managed settings: parameters a self-hoster can pin through Docker
//! env vars. When an env var is set, its value **overrides** the per-user copy
//! in the (otherwise client-owned) settings document, and the frontend locks
//! the field so it can't be edited. Secret values (API keys, tokens) are never
//! exposed to the frontend — [`ManagedSettings::public_view`] redacts them.
//!
//! The set of manageable keys is a static registry ([`MANAGED_KEYS`]); adding
//! one — e.g. a notification token — is a single entry here plus overlaying the
//! user document at that feature's read sites (the way the LLM read sites do).

use std::collections::HashMap;

use serde_json::Value;

/// Kind of value an env var carries, so we parse it into the right JSON shape
/// (the settings document stores `llm_labeling`/`llm_chat` as booleans).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Kind {
    Text,
    Bool,
}

/// One manageable setting: the env var that sets it, the settings-document key
/// it overrides, whether it's a secret (redacted from the frontend), and its
/// value kind.
pub struct ManagedKey {
    pub env: &'static str,
    pub key: &'static str,
    pub secret: bool,
    pub kind: Kind,
}

/// The registry. Keep the `key` strings in sync with the settings-document
/// contract shared with the app's `SettingsStore` (see [`crate::assist`]).
pub const MANAGED_KEYS: &[ManagedKey] = &[
    ManagedKey { env: "STICKY_NOTES_LLM_BASE_URL", key: "llm_base_url", secret: false, kind: Kind::Text },
    ManagedKey { env: "STICKY_NOTES_LLM_API_KEY", key: "llm_api_key", secret: true, kind: Kind::Text },
    ManagedKey { env: "STICKY_NOTES_LLM_MODEL", key: "llm_model", secret: false, kind: Kind::Text },
    ManagedKey { env: "STICKY_NOTES_LLM_LABELING", key: "llm_labeling", secret: false, kind: Kind::Bool },
    ManagedKey { env: "STICKY_NOTES_LLM_CHAT", key: "llm_chat", secret: false, kind: Kind::Bool },
    ManagedKey { env: "STICKY_NOTES_LLM_WRITING", key: "llm_writing", secret: false, kind: Kind::Bool },
];

/// A resolved managed value plus whether it should be hidden from the frontend.
#[derive(Debug, Clone, PartialEq)]
struct ManagedEntry {
    value: Value,
    secret: bool,
}

/// Env-managed settings resolved at startup. Empty by default (the tests and
/// `AppState::new` get this), which means nothing is managed and behavior is
/// unchanged.
#[derive(Debug, Clone, Default)]
pub struct ManagedSettings {
    values: HashMap<String, ManagedEntry>,
}

/// Parse an env string for a [`Kind::Bool`] key. Anything unrecognized (or
/// empty) yields `None`, so a typo'd value doesn't silently manage the key.
fn parse_bool(raw: &str) -> Option<bool> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "true" | "1" | "on" | "yes" => Some(true),
        "false" | "0" | "off" | "no" => Some(false),
        _ => None,
    }
}

impl ManagedSettings {
    /// Build from a lookup closure (env var name -> value). Text keys are
    /// included only when non-empty after trimming; Bool keys only when they
    /// parse. Keeps process-env access out of the pure logic so tests can
    /// supply a fixed map.
    pub fn from_lookup(lookup: impl Fn(&str) -> Option<String>) -> Self {
        let mut values = HashMap::new();
        for spec in MANAGED_KEYS {
            let Some(raw) = lookup(spec.env) else { continue };
            let value = match spec.kind {
                Kind::Text => {
                    let trimmed = raw.trim();
                    if trimmed.is_empty() {
                        continue;
                    }
                    Value::String(trimmed.to_string())
                }
                Kind::Bool => match parse_bool(&raw) {
                    Some(b) => Value::Bool(b),
                    None => continue,
                },
            };
            values.insert(spec.key.to_string(), ManagedEntry { value, secret: spec.secret });
        }
        Self { values }
    }

    /// Read the managed keys from the process environment.
    pub fn from_env() -> Self {
        Self::from_lookup(|k| std::env::var(k).ok())
    }

    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
    }

    /// The managed value for a settings key, if any — includes secrets, so this
    /// is backend-internal (never serialize it toward a client).
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.values.get(key).map(|e| &e.value)
    }

    /// A managed value as `&str`, for Text keys (convenience for overlaying a
    /// request body). Returns `None` for absent or non-string keys.
    pub fn text(&self, key: &str) -> Option<&str> {
        self.values.get(key).and_then(|e| e.value.as_str())
    }

    /// The effective settings document: the user's document with every managed
    /// key overlaid on top. A missing/invalid user document is treated as `{}`.
    pub fn overlay(&self, user: Option<&str>) -> Value {
        let mut doc = user
            .and_then(|s| serde_json::from_str::<Value>(s).ok())
            .filter(Value::is_object)
            .unwrap_or_else(|| Value::Object(Default::default()));
        // Safe: we just guaranteed `doc` is an object.
        let map = doc.as_object_mut().expect("object");
        for (key, entry) in &self.values {
            map.insert(key.clone(), entry.value.clone());
        }
        doc
    }

    /// Frontend-facing descriptor: which keys are managed, with secret values
    /// redacted. Shape: `{ "<key>": { "secret": bool, "value": <v>|null } }`.
    pub fn public_view(&self) -> Value {
        let mut out = serde_json::Map::new();
        for (key, entry) in &self.values {
            let value = if entry.secret { Value::Null } else { entry.value.clone() };
            out.insert(
                key.clone(),
                serde_json::json!({ "secret": entry.secret, "value": value }),
            );
        }
        Value::Object(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn managed(pairs: &[(&str, &str)]) -> ManagedSettings {
        let map: HashMap<String, String> =
            pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        ManagedSettings::from_lookup(|k| map.get(k).cloned())
    }

    #[test]
    fn from_lookup_inclusion_and_bool_parsing() {
        let m = managed(&[
            ("STICKY_NOTES_LLM_BASE_URL", "  http://x/v1  "),
            ("STICKY_NOTES_LLM_MODEL", ""), // empty -> skipped
            ("STICKY_NOTES_LLM_API_KEY", "sk-secret"),
            ("STICKY_NOTES_LLM_LABELING", "off"),
            ("STICKY_NOTES_LLM_CHAT", "maybe"), // unparseable -> skipped
        ]);
        assert_eq!(m.text("llm_base_url"), Some("http://x/v1")); // trimmed
        assert_eq!(m.get("llm_model"), None);
        assert_eq!(m.get("llm_labeling"), Some(&Value::Bool(false)));
        assert_eq!(m.get("llm_chat"), None);
        assert!(!m.is_empty());
        assert!(ManagedSettings::default().is_empty());
    }

    #[test]
    fn overlay_overrides_user_keys_and_keeps_others() {
        let m = managed(&[
            ("STICKY_NOTES_LLM_BASE_URL", "http://managed/v1"),
            ("STICKY_NOTES_LLM_API_KEY", "sk-managed"),
        ]);
        let user = r#"{"llm_base_url":"http://user/v1","llm_model":"m","theme":"dark"}"#;
        let eff = m.overlay(Some(user));
        assert_eq!(eff["llm_base_url"], "http://managed/v1"); // overridden
        assert_eq!(eff["llm_api_key"], "sk-managed"); // added
        assert_eq!(eff["llm_model"], "m"); // untouched user key
        assert_eq!(eff["theme"], "dark"); // unrelated key preserved
    }

    #[test]
    fn overlay_handles_missing_and_garbage_documents() {
        let m = managed(&[("STICKY_NOTES_LLM_MODEL", "m")]);
        assert_eq!(m.overlay(None)["llm_model"], "m");
        assert_eq!(m.overlay(Some("not json"))["llm_model"], "m");
        // Empty managed set + no user doc is a bare object, not null.
        assert!(ManagedSettings::default().overlay(None).is_object());
    }

    #[test]
    fn public_view_redacts_secrets_and_echoes_the_rest() {
        let m = managed(&[
            ("STICKY_NOTES_LLM_BASE_URL", "http://x/v1"),
            ("STICKY_NOTES_LLM_API_KEY", "sk-secret"),
            ("STICKY_NOTES_LLM_LABELING", "true"),
        ]);
        let view = m.public_view();
        assert_eq!(view["llm_base_url"], serde_json::json!({"secret": false, "value": "http://x/v1"}));
        assert_eq!(view["llm_labeling"], serde_json::json!({"secret": false, "value": true}));
        // Secret: present (so the field locks) but value never leaks.
        assert_eq!(view["llm_api_key"], serde_json::json!({"secret": true, "value": null}));
        let s = view.to_string();
        assert!(!s.contains("sk-secret"), "secret value leaked: {s}");
    }
}
