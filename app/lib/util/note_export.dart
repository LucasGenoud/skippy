import 'dart:convert';

import '../models/note.dart';
import '../models/workspace.dart';

/// Serialization targets for a bulk note export.
enum ExportFormat {
  json('JSON', 'json', 'application/json'),
  markdown('Markdown', 'md', 'text/markdown'),
  text('Plain text', 'txt', 'text/plain');

  final String label;
  final String extension;
  final String mime;
  const ExportFormat(this.label, this.extension, this.mime);
}

/// A timestamped, filesystem-safe download name, e.g.
/// `skippy-2026-07-13.md`.
String exportFilename(ExportFormat format, [DateTime? now]) {
  final d = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'skippy-${d.year}-${two(d.month)}-${two(d.day)}.${format.extension}';
}

/// Render [notes] into a single [format] document. [labels] resolves the
/// label ids carried on each note into human names.
String exportNotes(
  List<Note> notes,
  ExportFormat format, {
  List<Label> labels = const [],
  List<Workspace> workspaces = const [],
  DateTime? now,
}) {
  final names = {for (final l in labels) l.id: l.name};
  final workspaceNames = {for (final w in workspaces) w.id: w.name};
  return switch (format) {
    ExportFormat.json => _toJson(
      notes,
      names,
      workspaceNames,
      now ?? DateTime.now(),
    ),
    ExportFormat.markdown => _toMarkdown(
      notes,
      names,
      workspaceNames,
      now ?? DateTime.now(),
    ),
    ExportFormat.text => _toText(notes, names, workspaceNames),
  };
}

List<String> _labelNames(Note n, Map<String, String> names) => [
  for (final id in n.labelIds)
    if (names[id] case final String name) name,
]..sort();

String _toJson(
  List<Note> notes,
  Map<String, String> names,
  Map<String, String> workspaceNames,
  DateTime now,
) {
  final data = {
    'exported_at': now.toUtc().toIso8601String(),
    'version': 1,
    'notes': [
      for (final n in notes)
        {
          'id': n.id,
          if (workspaceNames[n.workspaceId] case final String workspace)
            'workspace': workspace,
          'kind': n.kind.wire,
          'title': n.title,
          'content': n.content,
          'items': [
            for (final i in n.items)
              {
                'text': i.text,
                'done': i.done,
                // Inline rather than a parallel list keyed by item id: this
                // export drops the ids, so a reminder has to travel with the
                // row it belongs to or lose its referent.
                if (n.reminderForItem(i.id) case final reminder?) ...{
                  'reminder_at': reminder.at.toUtc().toIso8601String(),
                  'reminder_repeat': reminder.repeat?.wire,
                },
              },
          ],
          'color': n.color,
          'pinned': n.pinned,
          'archived': n.archived,
          'reminder_at': n.reminderAt?.toUtc().toIso8601String(),
          'reminder_repeat': n.reminderRepeat?.wire,
          'labels': _labelNames(n, names),
          'created_at': n.createdAt.toUtc().toIso8601String(),
          'updated_at': n.updatedAt.toUtc().toIso8601String(),
        },
    ],
  };
  return const JsonEncoder.withIndent('  ').convert(data);
}

String _toMarkdown(
  List<Note> notes,
  Map<String, String> names,
  Map<String, String> workspaceNames,
  DateTime now,
) {
  final buf = StringBuffer('# Skippy export\n\n');
  String two(int v) => v.toString().padLeft(2, '0');
  buf.writeln(
    '_Exported ${now.year}-${two(now.month)}-${two(now.day)} · '
    '${notes.length} ${notes.length == 1 ? 'note' : 'notes'}_\n',
  );
  for (final n in notes) {
    buf.writeln('---\n');
    if (workspaceNames[n.workspaceId] case final String workspace) {
      buf.writeln('**Workspace:** $workspace\n');
    }
    final title = n.title.trim();
    if (title.isNotEmpty) buf.writeln('## $title\n');
    if (n.isChecklist) {
      for (final i in n.items) {
        // Two spaces a level, the usual markdown nesting, so an exported
        // list reads as the outline it was.
        buf.writeln(
          '${' ' * (i.depth * 2)}- [${i.done ? 'x' : ' '}] ${i.text}',
        );
      }
      buf.writeln();
    } else if (n.content.trim().isNotEmpty) {
      // text and markdown notes both round-trip as their raw body.
      buf.writeln('${n.content.trimRight()}\n');
    }
    final labels = _labelNames(n, names);
    if (labels.isNotEmpty) {
      buf.writeln('${labels.map((l) => '`$l`').join(' ')}\n');
    }
  }
  return '${buf.toString().trimRight()}\n';
}

/// One note as plain text: title, then the body, a checklist's rows as
/// `[x] item` lines. This is what "Copy to clipboard" puts on the clipboard
/// and what a text export is built from, so the two never drift apart.
/// [labels] is appended as a trailing line when given (the export does; the
/// clipboard doesn't, you're pasting the note, not its filing).
String noteToPlainText(Note note, {List<String> labels = const []}) {
  final buf = StringBuffer();
  final title = note.title.trim();
  if (title.isNotEmpty) buf.writeln('$title\n');
  if (note.isChecklist) {
    for (final i in note.items) {
      buf.writeln('${' ' * (i.depth * 2)}[${i.done ? 'x' : ' '}] ${i.text}');
    }
    buf.writeln();
  } else if (note.content.trim().isNotEmpty) {
    buf.writeln('${note.content.trimRight()}\n');
  }
  if (labels.isNotEmpty) buf.writeln('Labels: ${labels.join(', ')}\n');
  return buf.toString();
}

String _toText(
  List<Note> notes,
  Map<String, String> names,
  Map<String, String> workspaceNames,
) {
  final buf = StringBuffer();
  for (var idx = 0; idx < notes.length; idx++) {
    if (idx > 0) buf.writeln('${'—' * 40}\n');
    if (workspaceNames[notes[idx].workspaceId] case final String workspace) {
      buf.writeln('Workspace: $workspace\n');
    }
    buf.write(
      noteToPlainText(notes[idx], labels: _labelNames(notes[idx], names)),
    );
  }
  return '${buf.toString().trimRight()}\n';
}
