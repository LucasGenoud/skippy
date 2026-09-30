//! The AI a workspace runs on. Every AI feature acting on a workspace's notes
//! resolves through here, whoever triggered it, so all its members get the
//! same AI there:
//!
//! ```text
//! note / chat turn / token call
//!            │ workspace_id
//!            ▼
//! workspaces row ─── switches ◄── a server-pinned toggle wins
//!            │ owner_id
//!            ▼
//! owner's settings ── provider, instructions, rewrite tasks
//! ```

use std::collections::HashMap;

use serde_json::Value;

use crate::AppState;
use crate::assist::{LlmSettings, RewriteTask, parse_llm_settings_value, rewrite_tasks};
use crate::config::ManagedSettings;
use crate::error::ApiResult;
use crate::llm::LlmConfig;
use crate::models::{AiSwitches, RewriteTaskName, WorkspaceAiView, WorkspaceView};

#[derive(Clone, Copy)]
pub(super) enum AiFeature {
    Labeling,
    Chat,
    Writing,
}

pub(super) struct WorkspaceAi {
    switches: AiSwitches,
    settings: LlmSettings,
    tasks: Vec<RewriteTask>,
}

impl WorkspaceAi {
    /// The provider `feature` runs on, when the workspace allows it and its
    /// owner has one.
    pub(super) fn config(&self, feature: AiFeature) -> Option<&LlmConfig> {
        self.settings
            .config
            .as_ref()
            .filter(|_| self.allows(feature))
    }

    /// Whether the workspace's switches let `feature` near its notes, whoever
    /// provides the model.
    pub(super) fn allows(&self, feature: AiFeature) -> bool {
        let on = match feature {
            AiFeature::Labeling => self.switches.labeling,
            AiFeature::Chat => self.switches.chat,
            AiFeature::Writing => self.switches.writing,
        };
        self.switches.enabled && on
    }

    /// The owner's instructions and behavior choices.
    pub(super) fn settings(&self) -> &LlmSettings {
        &self.settings
    }

    /// The owner's instruction for rewrite task `id`.
    pub(super) fn task_prompt(&self, id: &str) -> Option<&str> {
        self.tasks
            .iter()
            .find(|task| task.id == id)
            .map(|task| task.prompt.as_str())
    }
}

/// The AI of `workspace_id`, or None when there is no such workspace.
pub(super) async fn workspace_ai(
    state: &AppState,
    workspace_id: &str,
) -> ApiResult<Option<WorkspaceAi>> {
    let Some(workspace) = state.repo.workspace(workspace_id).await? else {
        return Ok(None);
    };
    let owner = owner_settings(state, &workspace.owner_id).await?;
    Ok(Some(WorkspaceAi {
        switches: effective(&state.managed, workspace.ai),
        settings: parse_llm_settings_value(&owner),
        tasks: rewrite_tasks(&owner),
    }))
}

/// Fill in what each view's members need to know about its AI, reading each
/// owner's settings once.
pub(super) async fn resolve_views(
    state: &AppState,
    mut views: Vec<WorkspaceView>,
) -> ApiResult<Vec<WorkspaceView>> {
    let mut owners: HashMap<String, (bool, Vec<RewriteTaskName>)> = HashMap::new();
    for view in &mut views {
        if !owners.contains_key(&view.owner.id) {
            owners.insert(
                view.owner.id.clone(),
                owner_view(state, &view.owner.id).await?,
            );
        }
        let (provider_ready, rewrite_tasks) = owners[&view.owner.id].clone();
        view.ai = WorkspaceAiView {
            switches: effective(&state.managed, view.ai.switches),
            provider_ready,
            rewrite_tasks,
        };
    }
    Ok(views)
}

/// Whether the owner has a provider, and their task names: everything about
/// an owner's AI that a member's client is shown.
pub(super) async fn owner_view(
    state: &AppState,
    owner_id: &str,
) -> ApiResult<(bool, Vec<RewriteTaskName>)> {
    let owner = owner_settings(state, owner_id).await?;
    let names = rewrite_tasks(&owner)
        .into_iter()
        .map(|task| RewriteTaskName {
            id: task.id,
            name: task.name,
        })
        .collect();
    Ok((parse_llm_settings_value(&owner).config.is_some(), names))
}

async fn owner_settings(state: &AppState, owner_id: &str) -> ApiResult<Value> {
    let doc = state.repo.settings_for_user(owner_id).await?;
    Ok(state.managed.overlay(doc.as_deref()))
}

/// A feature toggle the server pins overrides the owner's switch.
fn effective(managed: &ManagedSettings, stored: AiSwitches) -> AiSwitches {
    let pinned = |key: &str, own: bool| managed.get(key).and_then(Value::as_bool).unwrap_or(own);
    AiSwitches {
        labeling: pinned("llm_labeling", stored.labeling),
        chat: pinned("llm_chat", stored.chat),
        writing: pinned("llm_writing", stored.writing),
        ..stored
    }
}
