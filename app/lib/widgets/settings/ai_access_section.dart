import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/api_token.dart';
import '../../state/notes_store.dart';
import '../../state/settings_store.dart';
import '../../util/motion.dart';
import '../../util/snack.dart';
import '../animated_reveal.dart';
import '../form_dialog.dart';
import '../state_cross_fade.dart';

const _maxNameLength = 80;

/// Personal access tokens, which let an AI assistant reach these notes over
/// MCP. Each one is created here, shown once, and revocable here.
class AiAccessSection extends StatefulWidget {
  const AiAccessSection({super.key});

  @override
  State<AiAccessSection> createState() => _AiAccessSectionState();
}

class _AiAccessSectionState extends State<AiAccessSection> {
  List<ApiToken>? _tokens;
  String? _error;
  bool _loading = true;

  /// Revoked since the last load. Their rows stay mounted long enough to
  /// collapse instead of vanishing from the middle of the list.
  final Set<String> _revoked = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<NotesStore>().api;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tokens = await api.fetchApiTokens();
      if (!mounted) return;
      setState(() {
        _tokens = tokens;
        _revoked.clear();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Can't reach the server right now";
      });
    }
  }

  Future<void> _create() async {
    final api = context.read<NotesStore>().api;
    final request = await showFormDialog<(String, TokenScope)>(
      context,
      builder: (_) => const _NewTokenDialog(),
    );
    if (request == null || !mounted) return;

    final CreatedApiToken created;
    try {
      created = await api.createApiToken(request.$1, request.$2);
    } catch (_) {
      showAppSnack(
        "Couldn't create the token",
        icon: Icons.error_outline,
        kind: SnackKind.danger,
      );
      return;
    }
    if (!mounted) return;
    setState(() => _tokens = [...?_tokens, created.token]);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _TokenCreatedDialog(created: created, baseUrl: api.baseUrl),
    );
  }

  Future<void> _revoke(ApiToken token) async {
    final api = context.read<NotesStore>().api;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: Text('Revoke "${token.name}"?'),
        content: const Text(
          'Any assistant using this token loses access to your notes '
          'immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api.deleteApiToken(token.id);
      if (!mounted) return;
      setState(() => _revoked.add(token.id));
      showAppSnack('Token revoked', icon: Icons.key_off_outlined);
    } catch (_) {
      showAppSnack(
        "Couldn't revoke the token",
        icon: Icons.error_outline,
        kind: SnackKind.danger,
      );
    }
  }

  List<ApiToken> get _live => [
    for (final token in _tokens ?? const <ApiToken>[])
      if (!_revoked.contains(token.id)) token,
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: Motion.reduced(context) ? Duration.zero : Motion.base,
      curve: Motion.emphasized,
      alignment: Alignment.topCenter,
      child: StateCrossFade(
        alignment: Alignment.topCenter,
        state: (_loading, _error != null),
        child: _content(context),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const ListTile(
        leading: Icon(Icons.smart_toy_outlined),
        title: Text('Assistant access (MCP)'),
        subtitle: Text('Loading…'),
      );
    }
    if (_error != null) {
      return ListTile(
        leading: Icon(Icons.smart_toy_outlined, color: scheme.error),
        title: const Text('Assistant access (MCP)'),
        subtitle: Text(_error!),
        trailing: IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Try again',
          onPressed: _load,
        ),
      );
    }

    final live = _live.length;
    final settings = context.watch<SettingsStore>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.smart_toy_outlined),
          title: const Text('Assistant access (MCP)'),
          subtitle: Text(
            live == 0
                ? 'Let an AI assistant such as Claude search and read your '
                      'notes, and add to them if you allow it.'
                : '$live ${live == 1 ? 'token' : 'tokens'} can reach your '
                      'notes',
          ),
          trailing: TextButton.icon(
            key: const Key('new-api-token'),
            icon: const Icon(Icons.add),
            label: const Text('New token'),
            onPressed: _create,
          ),
        ),
        for (final token in _tokens ?? const <ApiToken>[])
          AnimatedReveal(
            key: ValueKey(token.id),
            child: _revoked.contains(token.id)
                ? null
                : _tokenTile(token, settings),
          ),
      ],
    );
  }

  Widget _tokenTile(ApiToken token, SettingsStore settings) {
    final used = token.lastUsedAt;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 32, right: 8),
      leading: Icon(
        token.scope == TokenScope.write
            ? Icons.edit_note_outlined
            : Icons.visibility_outlined,
        size: 20,
      ),
      title: Text(token.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${token.scope.label} · '
        '${used == null ? 'never used' : 'last used ${settings.formatDate(used)}'}',
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.key_off_outlined, size: 18),
        tooltip: 'Revoke token',
        onPressed: () => _revoke(token),
      ),
    );
  }
}

/// Names a token and picks what it may do.
class _NewTokenDialog extends StatefulWidget {
  const _NewTokenDialog();

  @override
  State<_NewTokenDialog> createState() => _NewTokenDialogState();
}

class _NewTokenDialogState extends State<_NewTokenDialog> {
  final _name = TextEditingController();
  TokenScope _scope = TokenScope.read;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      return;
    }
    Navigator.pop(context, (name, _scope));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FormDialog(
      title: const Text('New assistant token'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('api-token-name'),
            controller: _name,
            autofocus: true,
            maxLength: _maxNameLength,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'Claude on my laptop',
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          const FormSectionLabel('What it may do'),
          SegmentedButton<TokenScope>(
            showSelectedIcon: false,
            segments: [
              for (final scope in TokenScope.values)
                ButtonSegment(value: scope, label: Text(scope.label)),
            ],
            selected: {_scope},
            onSelectionChanged: (selection) =>
                setState(() => _scope = selection.single),
          ),
          const SizedBox(height: 8),
          Text(
            _scope == TokenScope.read
                ? 'Search, list and read notes in every workspace you belong '
                      'to.'
                : 'Also create notes and add to existing ones. It cannot '
                      'delete, move or share anything.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('create-api-token'),
          onPressed: _name.text.trim().isEmpty ? null : _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// The token's secret, shown this once, with what to paste where.
class _TokenCreatedDialog extends StatelessWidget {
  final CreatedApiToken created;
  final String baseUrl;

  const _TokenCreatedDialog({required this.created, required this.baseUrl});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppDialog(
      title: const Text('Token created'),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Copy the token now. It is not shown again; if it is lost, '
              'revoke it and create another.',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 16),
            _CopyField(label: 'Token', value: created.secret),
            _CopyField(label: 'Server URL', value: mcpUrl(baseUrl)),
            _CopyField(
              label: 'Claude Code',
              value: claudeCodeCommand(baseUrl, created.secret),
            ),
            const SizedBox(height: 4),
            Text(
              'Other MCP clients: add a Streamable HTTP server at the URL '
              'above, with the header Authorization: Bearer followed by the '
              'token.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          key: const Key('api-token-done'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _CopyField extends StatelessWidget {
  final String label;
  final String value;

  const _CopyField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormSectionLabel(label),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  value,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.content_copy, size: 18),
                tooltip: 'Copy ${label.toLowerCase()}',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: value));
                  showAppSnack('$label copied', icon: Icons.content_copy);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
