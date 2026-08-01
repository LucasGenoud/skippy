import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../state/notes_store.dart';
import '../util/home_widgets.dart';
import '../util/widget_payload.dart';

/// Picks the note a newly added Android widget will show.
///
/// The launcher opens the app for this and waits: until
/// [HomeWidgets.bindWidgetToNote] runs, the widget it created is provisional
/// and gets discarded if the user backs out. That is why there is no cancel
/// action here beyond system back, and why the list is the whole screen.
///
/// iOS never reaches this: WidgetKit configures a widget through its own edit
/// sheet, driven by the same published index.
class WidgetConfigScreen extends StatefulWidget {
  const WidgetConfigScreen({
    super.key,
    required this.widgetId,
    required this.widgets,
  });

  final int widgetId;
  final HomeWidgets widgets;

  @override
  State<WidgetConfigScreen> createState() => _WidgetConfigScreenState();
}

class _WidgetConfigScreenState extends State<WidgetConfigScreen> {
  String _query = '';
  bool _binding = false;

  /// The note the user pinned from, when they came via "Add to Home Screen".
  String? _preselected;

  @override
  void initState() {
    super.initState();
    widget.widgets.takePreselectedNote().then((id) {
      if (mounted) setState(() => _preselected = id);
    });
  }

  Future<void> _choose(Note note) async {
    if (_binding) return;
    setState(() => _binding = true);
    await widget.widgets.bindWidgetToNote(widget.widgetId, note.id);
    // The launcher finishes this activity itself once the flow completes, so
    // there is deliberately nothing to pop here.
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final query = _query.trim().toLowerCase();
    final notes = [
      for (final note in store.notesForWidgets)
        if (!note.trashed &&
            (query.isEmpty ||
                widgetDisplayTitle(note).toLowerCase().contains(query)))
          note,
    ]..sort((a, b) {
      // The note they pinned from goes first; everything else newest first.
      if (a.id == _preselected) return -1;
      if (b.id == _preselected) return 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose a note'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              autofocus: false,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search your notes',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
        ),
      ),
      body: store.loading
          ? const Center(child: CircularProgressIndicator())
          : notes.isEmpty
          ? const Center(child: Text('No notes to show yet.'))
          : ListView.builder(
              itemCount: notes.length,
              itemBuilder: (context, index) {
                final note = notes[index];
                return _NoteRow(
                  note: note,
                  highlighted: note.id == _preselected,
                  enabled: !_binding,
                  onTap: () => _choose(note),
                );
              },
            ),
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.note,
    required this.highlighted,
    required this.enabled,
    required this.onTap,
  });

  final Note note;
  final bool highlighted;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = note.items.where((i) => !i.done).length;
    final subtitle = note.kind == NoteKind.checklist && note.items.isNotEmpty
        ? (pending == 0
              ? 'All ${note.items.length} done'
              : '$pending of ${note.items.length} left')
        : null;
    return ListTile(
      enabled: enabled,
      selected: highlighted,
      leading: Icon(switch (note.kind) {
        NoteKind.checklist => Icons.checklist,
        NoteKind.markdown => Icons.data_object,
        NoteKind.audio => Icons.graphic_eq,
        NoteKind.text => Icons.notes_outlined,
      }),
      title: Text(
        widgetDisplayTitle(note),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: theme.textTheme.bodySmall),
      onTap: onTap,
    );
  }
}
