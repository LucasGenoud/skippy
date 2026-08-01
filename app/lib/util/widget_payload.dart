/// Pure rules for the document the app publishes into shared storage for the
/// home-screen widgets to render, and for reading back the ticks those widgets
/// made while the app was closed.
///
/// Kept free of `home_widget` and of Flutter itself so the decisions that shape
/// what a widget can show (which notes, which items, how many) are unit-testable
/// without a platform channel. The platform boundary is [home_widgets.dart];
/// the glue that drives both is [HomeWidgetBridge].
library;

import '../models/note.dart';

/// Keys in the shared store (App Group on iOS, `HomeWidgetPreferences` on
/// Android). Native widget code reads these by the same literal names, so they
/// are a wire contract: changing one means changing the Swift and Kotlin too.
const String kWidgetNotesKey = 'skippy_widget_notes';
const String kWidgetIndexKey = 'skippy_widget_index';
const String kWidgetSessionKey = 'skippy_widget_session';
const String kWidgetOpsKey = 'skippy_widget_ops';
const String kWidgetWantedKey = 'skippy_widget_wanted';
const String kWidgetPreselectKey = 'skippy_widget_preselect';

/// Which note one Android widget instance shows. Read by `SkippyWidgetStore`
/// under the same name, so the two must agree.
String widgetNoteKey(int appWidgetId) => 'skippy_widget_${appWidgetId}_note';

/// Bumped if the payload shape ever changes incompatibly, so a widget built
/// against an older app version can tell rather than mis-render.
const int kWidgetPayloadVersion = 1;

/// How many notes get a full payload. The user picks a widget's note from
/// [buildWidgetIndex], so publishing well beyond what any one widget needs is
/// what makes that pick work immediately, without a round trip through the app.
/// Sixty trimmed notes is a few tens of KB, which both stores hold comfortably.
const int kMaxWidgetNotes = 60;

/// Items published per note. A widget can only ever show a screenful; this cap
/// exists so one enormous checklist can't crowd out every other note's payload.
const int kMaxWidgetItems = 40;

/// Characters of body text published for a non-checklist note.
const int kWidgetContentChars = 400;

/// Light/dark background for a note's colour, as `#AARRGGBB` strings, or nulls
/// for the default (uncoloured) note. Supplied by the caller because resolving
/// a colour key needs the user's custom palette, which lives in `SettingsStore`.
typedef WidgetNoteColors = ({String? light, String? dark});

/// Resolves a note's colour key (`Note.color`) into publishable hex.
typedef WidgetColorResolver = WidgetNoteColors Function(String colorKey);

/// What a note is called on a home screen. Notes are frequently untitled, and a
/// widget with a blank header is unpickable, so this falls back through the
/// note's own content the way a person would read it.
String widgetDisplayTitle(Note note) {
  final title = note.title.trim();
  if (title.isNotEmpty) return title;
  for (final line in note.content.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return _cap(trimmed, 60);
  }
  for (final item in note.items) {
    final trimmed = item.text.trim();
    if (trimmed.isNotEmpty) return _cap(trimmed, 60);
  }
  return 'Untitled note';
}

String _cap(String value, int max) {
  final runes = value.runes;
  if (runes.length <= max) return value;
  return '${String.fromCharCodes(runes.take(max))}…';
}

/// Pending items first, then completed, each group keeping its own order.
///
/// Matches how the editor's checklist presents a note (active rows, then a
/// "Completed" section), and it is what makes the cap safe: on iOS only the
/// first few items are visible at all, and they must be the ones still to do.
/// A partition rather than a sort, because `List.sort` is not stable.
List<ChecklistItem> orderedWidgetItems(List<ChecklistItem> items) {
  final pending = <ChecklistItem>[];
  final done = <ChecklistItem>[];
  for (final item in items) {
    (item.done ? done : pending).add(item);
  }
  return [...pending, ...done];
}

/// Notes eligible for a widget, most recently edited first.
///
/// Trashed notes are excluded (a widget must not resurrect one), archived notes
/// are kept: archiving hides a note from the grid, but a widget the user
/// deliberately pinned should not silently go blank.
List<Note> _publishable(Iterable<Note> notes) {
  final eligible = [
    for (final note in notes)
      if (!note.trashed) note,
  ];
  // Id as a tiebreaker so the same set always produces the same document, which
  // keeps the bridge's "did anything change?" comparison meaningful.
  eligible.sort((a, b) {
    final byTime = b.updatedAt.compareTo(a.updatedAt);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  });
  return eligible;
}

/// One note, trimmed to what a widget can render.
Map<String, dynamic> buildWidgetNote(
  Note note, {
  required WidgetColorResolver resolveColor,
  int maxItems = kMaxWidgetItems,
}) {
  final ordered = orderedWidgetItems(note.items);
  final colors = resolveColor(note.color);
  return {
    'id': note.id,
    'title': widgetDisplayTitle(note),
    'kind': note.kind.wire,
    if (colors.light != null) 'colorLight': colors.light,
    if (colors.dark != null) 'colorDark': colors.dark,
    'items': [
      for (final item in ordered.take(maxItems))
        {'id': item.id, 'text': item.text, 'done': item.done},
    ],
    // Totals describe the whole note, not the published slice, so a widget can
    // say "+3 more" honestly even past [maxItems].
    'itemCount': note.items.length,
    'pendingCount': note.items.where((i) => !i.done).length,
    'content': _cap(note.content.trim(), kWidgetContentChars),
    'updatedAt': note.updatedAt.toUtc().toIso8601String(),
  };
}

/// The full document of renderable notes, keyed by note id.
///
/// [keep] holds ids some widget asked for that fell outside the cap (see
/// [kWidgetWantedKey]); they are published regardless of how stale they are, so
/// a widget on a long-untouched note keeps working.
Map<String, dynamic> buildWidgetNotesDoc(
  Iterable<Note> notes, {
  required WidgetColorResolver resolveColor,
  Set<String> keep = const {},
  int maxNotes = kMaxWidgetNotes,
  int maxItems = kMaxWidgetItems,
}) {
  final eligible = _publishable(notes);
  final chosen = <Note>[];
  for (final note in eligible) {
    if (chosen.length >= maxNotes && !keep.contains(note.id)) continue;
    chosen.add(note);
  }
  return {
    'version': kWidgetPayloadVersion,
    'notes': {
      for (final note in chosen)
        note.id: buildWidgetNote(
          note,
          resolveColor: resolveColor,
          maxItems: maxItems,
        ),
    },
  };
}

/// The picker list: every eligible note, cheap enough to hold them all.
///
/// Drives the iOS widget's note chooser (an `AppEntity` query) and the Android
/// configuration screen, so it carries only what a picker row shows.
List<Map<String, dynamic>> buildWidgetIndex(
  Iterable<Note> notes, {
  int maxNotes = kMaxWidgetNotes,
}) => [
  for (final note in _publishable(notes).take(maxNotes))
    {
      'id': note.id,
      'title': widgetDisplayTitle(note),
      'kind': note.kind.wire,
      'itemCount': note.items.length,
      'pendingCount': note.items.where((i) => !i.done).length,
    },
];

/// A tick made on a widget that the app has not yet folded into its own state.
///
/// Native code appends one of these on every toggle and drops it once the
/// server confirms the write; anything left over is replayed by the app. The
/// [done] value is absolute rather than a flip, so replaying one twice, or
/// replaying one the server already took, converges on the same result.
class WidgetOp {
  final String noteId;
  final String itemId;
  final bool done;

  /// When the tick happened, used only to replay ops in the order they were
  /// made. Null when the native side wrote no timestamp.
  final DateTime? at;

  const WidgetOp({
    required this.noteId,
    required this.itemId,
    required this.done,
    this.at,
  });

  @override
  bool operator ==(Object other) =>
      other is WidgetOp &&
      other.noteId == noteId &&
      other.itemId == itemId &&
      other.done == done &&
      other.at == at;

  @override
  int get hashCode => Object.hash(noteId, itemId, done, at);

  @override
  String toString() => 'WidgetOp($noteId/$itemId -> $done)';
}

/// Read back the queue native code appended to.
///
/// Deliberately forgiving: this parses a document two other languages write, so
/// a single malformed entry drops that entry rather than the user's other
/// ticks. Ops are returned oldest first, because replaying two ticks on the
/// same item out of order would land on the wrong value.
List<WidgetOp> parseWidgetOps(Object? raw) {
  if (raw is! List) return const [];
  final ops = <WidgetOp>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final noteId = entry['noteId'];
    final itemId = entry['itemId'];
    final done = entry['done'];
    if (noteId is! String || itemId is! String || done is! bool) continue;
    if (noteId.isEmpty || itemId.isEmpty) continue;
    final at = entry['at'];
    ops.add(
      WidgetOp(
        noteId: noteId,
        itemId: itemId,
        done: done,
        at: at is String ? DateTime.tryParse(at)?.toUtc() : null,
      ),
    );
  }
  // Undated ops sort before dated ones, at a fixed point rather than "equal to
  // everything": a comparator that calls a null both-ways-equal is not a total
  // order, and sorting through one can reorder the dated ops around it.
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  ops.sort((a, b) => (a.at ?? epoch).compareTo(b.at ?? epoch));
  return ops;
}

/// Note ids a widget rendered but could not find in the published document.
List<String> parseWantedIds(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final entry in raw)
      if (entry is String && entry.isNotEmpty) entry,
  ];
}
