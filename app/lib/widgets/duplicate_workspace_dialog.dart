import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/api_client.dart';
import '../models/workspace.dart';
import '../state/notes_store.dart';
import '../theme.dart';
import 'form_dialog.dart';

class DuplicateWorkspaceDialog extends StatefulWidget {
  final Workspace workspace;
  const DuplicateWorkspaceDialog({super.key, required this.workspace});
  static Future<void> show(BuildContext context, Workspace workspace) =>
      showFormDialog<void>(
        context,
        builder: (_) => DuplicateWorkspaceDialog(workspace: workspace),
      );
  @override
  State<DuplicateWorkspaceDialog> createState() =>
      _DuplicateWorkspaceDialogState();
}

class _DuplicateWorkspaceDialogState extends State<DuplicateWorkspaceDialog> {
  late final _name = TextEditingController(
    text: '${widget.workspace.name.characters.take(55)} copy',
  );
  WorkspaceCopyContent _content = WorkspaceCopyContent.structure;
  bool _reminders = false;
  bool _busy = false;
  String? _error;
  String? _nameError;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _nameError = 'Enter a name');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<NotesStore>().duplicateWorkspace(
        widget.workspace.id,
        _name.text.trim(),
        _content,
        reminders: _reminders,
      );
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error =
              'Could not duplicate workspace. Check your connection and try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: FormDialog(
      title: const Text('Duplicate workspace'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _name,
            enabled: !_busy,
            maxLength: 60,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Name',
              errorText: _nameError,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_nameError != null) {
                setState(() => _nameError = null);
              }
            },
            onSubmitted: (_) {
              if (!_busy) {
                _copy();
              }
            },
          ),
          const SizedBox(height: 16),
          Text(
            'Include',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: kSpaceSm),
          RadioGroup<WorkspaceCopyContent>(
            groupValue: _content,
            onChanged: (value) {
              if (!_busy && value != null) {
                setState(() => _content = value);
              }
            },
            child: Column(
              children: [
                RadioListTile<WorkspaceCopyContent>(
                  value: WorkspaceCopyContent.structure,
                  enabled: !_busy,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Structure only'),
                  subtitle: const Text(
                    'Collections, layouts, columns, labels and saved filters.',
                  ),
                ),
                RadioListTile<WorkspaceCopyContent>(
                  value: WorkspaceCopyContent.notes,
                  enabled: !_busy,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Structure and notes'),
                  subtitle: const Text(
                    'Also includes archived notes and attachments.',
                  ),
                ),
              ],
            ),
          ),
          if (_content == WorkspaceCopyContent.notes)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Copy reminders'),
              subtitle: const Text(
                'Keep scheduled reminders in the copied notes.',
              ),
              value: _reminders,
              onChanged: _busy ? null : (v) => setState(() => _reminders = v),
            ),
          const Divider(height: 32),
          Text(
            'You own the copy. Sharing, trash and version history stay in the original workspace.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 20),
              child: LinearProgressIndicator(),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _copy,
          child: Text(_busy ? 'Duplicating…' : 'Duplicate'),
        ),
      ],
    ),
  );
}
