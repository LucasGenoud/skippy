import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'form_dialog.dart';

/// The app's keyboard shortcut reference. This dialog is the in-app source of
/// truth for the bindings declared in home_screen.dart (plus the editor's and
/// quick-add's own keys); the README's "Keyboard shortcuts" section mirrors it.
/// Opened with "?" on the notes screen or from Settings → Help.
Future<void> showShortcutHelp(BuildContext context) =>
    showFormDialog<void>(context, builder: (_) => const ShortcutHelpDialog());

class ShortcutHelpDialog extends StatelessWidget {
  const ShortcutHelpDialog({super.key});

  @override
  Widget build(BuildContext context) {
    // The web build reports the host OS, so Mac users see their key. Words,
    // not ⌘/⇧ glyphs: the bundled fonts don't cover those and render tofu.
    final mod = switch (defaultTargetPlatform) {
      TargetPlatform.macOS || TargetPlatform.iOS => 'Cmd',
      _ => 'Ctrl',
    };

    final sections = <(String, List<(List<String>, String)>)>[
      (
        'Notes screen',
        [
          (['C', 'N'], 'New note'),
          (['L'], 'New checklist'),
          (['M'], 'New markdown note'),
          (['/', '$mod K'], 'Search'),
          (['Esc'], 'Exit selection / clear search'),
          (['$mod G'], 'Toggle grid / list'),
          (['?'], 'Show this help'),
        ],
      ),
      (
        'Editor',
        [
          (['$mod Z'], 'Undo'),
          (['Shift $mod Z'], 'Redo'),
          (['Esc'], 'Close and save'),
        ],
      ),
      (
        'Quick add',
        [
          (['Esc'], 'Save and close'),
        ],
      ),
    ];

    return FormDialog(
      title: const Text('Keyboard shortcuts'),
      width: 360,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (title, rows) in sections) ...[
            _SectionLabel(title),
            for (final (keys, description) in rows)
              _ShortcutRow(keys: keys, description: description),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String title;

  const _SectionLabel(this.title);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  /// Alternative key(cap)s that trigger the action, e.g. `['C', 'N']`.
  final List<String> keys;
  final String description;

  const _ShortcutRow({required this.keys, required this.description});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final (i, key) in keys.indexed) ...[
                  if (i > 0)
                    Text(
                      'or',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  _KeyCap(key),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(description),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyCap extends StatelessWidget {
  final String label;

  const _KeyCap(this.label);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
