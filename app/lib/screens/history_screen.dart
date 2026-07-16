import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/snack.dart';

/// The edit-history timeline for a single note: the current state on top,
/// then every past version newest-first, each restorable. Restoring rolls the
/// note's content back; the server checkpoints the current state first, so it
/// is always reversible from this same screen.
class NoteHistoryScreen extends StatefulWidget {
  final String noteId;

  const NoteHistoryScreen({super.key, required this.noteId});

  /// Push the timeline over whatever's on screen (works from the fullscreen
  /// editor and the wide-screen modal alike — it uses the root navigator).
  static Future<void> open(BuildContext context, String noteId) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => NoteHistoryScreen(noteId: noteId)),
    );
  }

  @override
  State<NoteHistoryScreen> createState() => _NoteHistoryScreenState();
}

class _NoteHistoryScreenState extends State<NoteHistoryScreen> {
  late final NotesStore _store;
  late Future<List<NoteVersion>> _future;
  String? _restoringId;

  @override
  void initState() {
    super.initState();
    _store = context.read<NotesStore>();
    _future = _store.noteVersions(widget.noteId);
  }

  void _reload() {
    setState(() => _future = _store.noteVersions(widget.noteId));
  }

  Future<void> _restore(NoteVersion version) async {
    final settings = context.read<SettingsStore>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore this version?'),
        content: Text(
          'The note will roll back to how it was on '
          '${_stamp(settings, version.createdAt)}. The current version is '
          'saved to history first, so you can undo this.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _restoringId = version.id);
    try {
      await _store.restoreNoteVersion(widget.noteId, version.id);
      if (!mounted) return;
      Navigator.of(context).pop();
      showAppSnack('Restored version from ${_stamp(settings, version.createdAt)}');
    } catch (_) {
      if (!mounted) return;
      setState(() => _restoringId = null);
      showAppSnack("Couldn't restore this version");
    }
  }

  String _stamp(SettingsStore settings, DateTime t) =>
      '${settings.formatDate(t, withYear: t.year != DateTime.now().year)} · '
      '${settings.formatClock(t)}';

  @override
  Widget build(BuildContext context) {
    // Watch so a live edit (or the restore itself) refreshes the current card.
    context.watch<NotesStore>();
    final settings = context.watch<SettingsStore>();
    final note = _store.noteById(widget.noteId);
    final canRestore = note != null && !note.trashed;

    return Scaffold(
      appBar: AppBar(title: const Text('Version history')),
      body: FutureBuilder<List<NoteVersion>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _Message(
              icon: Icons.cloud_off_outlined,
              text: "Couldn't load history",
              action: FilledButton.tonal(
                onPressed: _reload,
                child: const Text('Try again'),
              ),
            );
          }
          final versions = snapshot.data ?? const <NoteVersion>[];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              if (note != null)
                _VersionCard(
                  settings: settings,
                  isCurrent: true,
                  kind: note.kind,
                  title: note.title,
                  content: note.content,
                  items: note.items,
                  stamp: _stamp(settings, note.updatedAt),
                  author: null,
                ),
              if (versions.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Text(
                    'No earlier versions yet.\nEdits you make from now on are '
                    'saved here automatically.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              for (final version in versions)
                _VersionCard(
                  settings: settings,
                  isCurrent: false,
                  kind: version.kind,
                  title: version.title,
                  content: version.content,
                  items: version.items,
                  stamp: _stamp(settings, version.createdAt),
                  author: _authorLabel(version),
                  onRestore: canRestore && _restoringId == null
                      ? () => _restore(version)
                      : null,
                  restoring: _restoringId == version.id,
                ),
            ],
          );
        },
      ),
    );
  }

  /// Show the editor's name only when it isn't the signed-in user — on a
  /// personal note every version is "you", which is just noise.
  String? _authorLabel(NoteVersion version) {
    final editor = version.editedBy;
    if (editor == null || editor.id == _store.currentUserId) return null;
    return editor.username;
  }
}

class _VersionCard extends StatelessWidget {
  final SettingsStore settings;
  final bool isCurrent;
  final NoteKind kind;
  final String title;
  final String content;
  final List<ChecklistItem> items;
  final String stamp;
  final String? author;
  final VoidCallback? onRestore;
  final bool restoring;

  const _VersionCard({
    required this.settings,
    required this.isCurrent,
    required this.kind,
    required this.title,
    required this.content,
    required this.items,
    required this.stamp,
    required this.author,
    this.onRestore,
    this.restoring = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          stamp,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                      if (author != null) ...[
                        Text(
                          '  ·  $author',
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
                if (isCurrent)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'Current',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _preview(context),
            if (onRestore != null || restoring) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: restoring
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : TextButton.icon(
                        onPressed: onRestore,
                        icon: const Icon(Icons.restore, size: 18),
                        label: const Text('Restore'),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Compact, read-only rendering of a version's content: the title (if any),
  /// then the body text or the checklist rows, both capped so long notes don't
  /// dominate the timeline.
  Widget _preview(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasTitle = title.trim().isNotEmpty;
    final children = <Widget>[];
    if (hasTitle) {
      children.add(
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
      );
    }
    if (kind == NoteKind.checklist) {
      final shown = items.take(8).toList();
      for (final item in shown) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  item.done
                      ? Icons.check_box_outlined
                      : Icons.check_box_outline_blank,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    item.text.isEmpty ? ' ' : item.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      decoration: item.done ? TextDecoration.lineThrough : null,
                      color: item.done ? scheme.onSurfaceVariant : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
      if (items.length > shown.length) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '+${items.length - shown.length} more',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      }
    } else if (content.trim().isNotEmpty) {
      children.add(
        Padding(
          padding: EdgeInsets.only(top: hasTitle ? 4 : 0),
          child: Text(
            content,
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }
    if (children.isEmpty) {
      children.add(
        Text(
          'Empty note',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontStyle: FontStyle.italic,
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;

  const _Message({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(text, style: Theme.of(context).textTheme.bodyLarge),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}
