import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/workspace.dart';
import '../screens/settings_screen.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import 'settings/managed_note.dart';

/// A workspace's AI switches. Everything runs on the owner's provider, so the
/// owner decides, and everyone else sees what they chose:
///
/// ```text
///   AI in this workspace            [on]   runs on Ada's AI provider
///     Automatic labeling            [on]   ┐
///     Notes chat                    [on]   ├ live only while AI is on
///     AI note editing               [on]   ┘
///   Assistant access (MCP)          [on]   tokens, not the provider
/// ```
class WorkspaceAiSection extends StatelessWidget {
  final Workspace workspace;
  final bool isOwner;

  const WorkspaceAiSection({
    super.key,
    required this.workspace,
    required this.isOwner,
  });

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final ai = workspace.ai;
    final switches = ai.switches;
    final ownerName = workspace.owner?.name ?? 'The owner';

    void set(AiSwitches next) =>
        context.read<NotesStore>().updateWorkspaceAi(workspace.id, next);

    // A feature row is live for the owner while AI is on, unless the server
    // pins it.
    ValueChanged<bool>? feature(
      String managedKey,
      AiSwitches Function(bool value) next,
    ) {
      if (!isOwner || !switches.enabled || settings.isManaged(managedKey)) {
        return null;
      }
      return (value) => set(next(value));
    }

    final String status;
    if (ai.providerReady) {
      status = isOwner
          ? 'Runs on your AI provider, for everyone here'
          : "Runs on $ownerName's AI provider";
    } else {
      status = isOwner
          ? 'Needs your AI provider'
          : "$ownerName hasn't set up an AI provider";
    }

    // A member reads what is in effect; the switches are the owner's.
    final readOnly = !isOwner;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AiRow(
          icon: Icons.auto_awesome_outlined,
          title: 'AI in this workspace',
          subtitle: status,
          readOnly: readOnly,
          value: switches.enabled,
          onChanged: (value) => set(switches.copyWith(enabled: value)),
        ),
        if (isOwner && !ai.providerReady)
          ListTile(
            leading: const SizedBox(width: 24),
            title: const Text('Set up your AI provider'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(SettingsScreen.route(page: SettingsPage.ai)),
          ),
        _AiRow(
          icon: Icons.label_outline,
          title: 'Automatic labeling',
          subtitle: "Apply this workspace's labels to new and edited notes",
          indent: true,
          readOnly: readOnly,
          managed: settings.isManaged('llm_labeling'),
          value: readOnly
              ? switches.allows(AiFeature.labeling)
              : switches.labeling,
          onChanged: feature(
            'llm_labeling',
            (v) => switches.copyWith(labeling: v),
          ),
        ),
        _AiRow(
          icon: Icons.forum_outlined,
          title: 'Notes chat',
          subtitle: settings.semanticSearchCapable
              ? 'Ask questions about these notes'
              : 'Needs semantic search on this server',
          indent: true,
          readOnly: readOnly,
          managed: settings.isManaged('llm_chat'),
          value: readOnly ? switches.allows(AiFeature.chat) : switches.chat,
          onChanged: feature('llm_chat', (v) => switches.copyWith(chat: v)),
        ),
        _AiRow(
          icon: Icons.auto_fix_high_outlined,
          title: 'AI note editing',
          subtitle: "Cleanup and rewrite actions in each note's menu",
          indent: true,
          readOnly: readOnly,
          managed: settings.isManaged('llm_writing'),
          value: readOnly
              ? switches.allows(AiFeature.writing)
              : switches.writing,
          onChanged: feature(
            'llm_writing',
            (v) => switches.copyWith(writing: v),
          ),
        ),
        _AiRow(
          icon: Icons.smart_toy_outlined,
          title: 'Assistant access (MCP)',
          subtitle: "Members' access tokens can read and add to these notes",
          readOnly: readOnly,
          value: switches.assistantAccess,
          onChanged: (value) => set(switches.copyWith(assistantAccess: value)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            isOwner
                ? 'These apply to everyone in this workspace.'
                : 'Only $ownerName can change these.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// One AI switch. The owner gets the switch; anyone else reads whether it is
/// on, since a disabled switch hides that in grey. A feature sits indented
/// under the switch that gates it.
class _AiRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool indent;
  final bool readOnly;
  final bool managed;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _AiRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.indent = false,
    required this.readOnly,
    this.managed = false,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = ManagedToggleSubtitle(
      managed: managed,
      text: this.subtitle,
    );
    final Widget row;
    if (readOnly) {
      row = ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle,
        trailing: Text(
          value ? 'On' : 'Off',
          style: Theme.of(context).textTheme.labelLarge,
        ),
      );
    } else {
      row = SwitchListTile(
        secondary: Icon(icon),
        title: Text(title),
        subtitle: subtitle,
        value: value,
        onChanged: onChanged,
      );
    }
    if (!indent) {
      return row;
    }
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 24),
      child: row,
    );
  }
}
