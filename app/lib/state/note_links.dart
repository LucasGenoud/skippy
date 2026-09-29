import 'package:flutter/services.dart';

import '../models/note.dart';
import '../util/widget_payload.dart';

/// Links between notes, written into a note's text as `[[id|Title]]`.
///
/// The id is what a link follows, so renaming the target never breaks it. The
/// title is what the text shows where the live title is unknown: exports, the
/// editor source, a note that is no longer reachable.
///
///     see [[3f2c…-…|Groceries]] for the list
///         └──┬───┘ └───┬───┘
///          hidden    shown

/// Scheme of the markdown hrefs [markdownNoteLinks] writes.
const kNoteLinkScheme = 'skippy-note';

const _uuidLength = 36;
const _maxTitleLength = 80;
const _maxQueryLength = 60;
const _defaultCandidates = 6;

final RegExp _linkPattern = RegExp(r'\[\[([0-9a-fA-F-]{36})\|([^\[\]\n]*)\]\]');
final RegExp _openLinkPattern = RegExp(
  '\\[\\[([^\\[\\]\\n|]{0,$_maxQueryLength})\$',
);
final RegExp _titleUnsafe = RegExp(r'[\[\]|\r\n]');
final RegExp _spaces = RegExp(r'\s+');

class NoteLink {
  /// Bounds of the whole `[[id|Title]]` token in its text.
  final int start;
  final int end;
  final String noteId;
  final String title;

  const NoteLink({
    required this.start,
    required this.end,
    required this.noteId,
    required this.title,
  });

  /// Bounds of the visible title inside the token.
  int get titleStart => start + 3 + _uuidLength;
  int get titleEnd => end - 2;
}

List<NoteLink> findNoteLinks(String text) => [
  for (final match in _linkPattern.allMatches(text))
    NoteLink(
      start: match.start,
      end: match.end,
      noteId: match.group(1)!,
      title: match.group(2)!,
    ),
];

/// The token linking to [noteId]. Brackets, pipes and line breaks would end the
/// token early, so they become spaces.
String noteLinkToken(String noteId, String title) {
  var clean = title.replaceAll(_titleUnsafe, ' ').replaceAll(_spaces, ' ');
  clean = clean.trim();
  if (clean.length > _maxTitleLength) {
    clean = clean.substring(0, _maxTitleLength).trim();
  }
  if (clean.isEmpty) {
    clean = 'Untitled note';
  }
  return '[[$noteId|$clean]]';
}

/// What a link to [note] is called.
String noteLinkTitle(Note note) => widgetDisplayTitle(note);

/// [text] with each link shown as its title: [titleFor] when it knows the note,
/// else the title stored in the link.
String plainNoteLinks(String text, {String? Function(String id)? titleFor}) =>
    text.replaceAllMapped(
      _linkPattern,
      (m) => titleFor?.call(m.group(1)!) ?? m.group(2)!,
    );

/// [text] with each link as a markdown link [noteIdFromHref] can follow.
String markdownNoteLinks(
  String text, {
  String? Function(String id)? titleFor,
}) => text.replaceAllMapped(_linkPattern, (m) {
  final id = m.group(1)!;
  final title = titleFor?.call(id) ?? m.group(2)!;
  return '[$title]($kNoteLinkScheme:$id)';
});

String? noteIdFromHref(String href) {
  const prefix = '$kNoteLinkScheme:';
  if (!href.startsWith(prefix)) {
    return null;
  }
  return href.substring(prefix.length);
}

/// [text] with links to the keys of [ids] pointing at their values instead,
/// for copies of notes that should link to each other rather than the source.
String remapNoteLinks(String text, Map<String, String> ids) =>
    text.replaceAllMapped(_linkPattern, (m) {
      final target = ids[m.group(1)!];
      if (target == null) {
        return m.group(0)!;
      }
      return '[[$target|${m.group(2)!}]]';
    });

/// While a link is being typed, `[[gro|` with the caret at `|`, the text after
/// `[[`; otherwise null.
String? openLinkQuery(String text, int caret) {
  if (caret < 0 || caret > text.length) {
    return null;
  }
  return _openLinkPattern.firstMatch(text.substring(0, caret))?.group(1);
}

/// Notes whose text links to [noteId], most recently edited first.
List<Note> backlinksTo(String noteId, Iterable<Note> notes) {
  final needle = '[[$noteId|';
  return [
    for (final note in notes)
      if (!note.trashed && note.id != noteId && note.content.contains(needle))
        note,
  ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
}

/// Notes a link typed as `[[query` could point at, most recently edited first.
List<Note> linkCandidates(
  Iterable<Note> notes,
  String query, {
  String? excludeId,
  int limit = _defaultCandidates,
}) {
  final needle = query.trim().toLowerCase();
  final matches = [
    for (final note in notes)
      if (!note.trashed &&
          note.id != excludeId &&
          (needle.isEmpty ||
              note.title.toLowerCase().contains(needle) ||
              note.content.toLowerCase().contains(needle)))
        note,
  ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return matches.take(limit).toList();
}

/// A caret [offset] that landed inside a link moves to the edge it was
/// heading for, so a link reads and moves as one unit. [previous] is where the
/// caret was; a jump from elsewhere lands on the nearer edge.
int snapOutOfLinks(String text, int offset, {required int previous}) {
  for (final link in findNoteLinks(text)) {
    if (offset <= link.start || offset >= link.end) {
      continue;
    }
    if (offset > previous) {
      return link.end;
    }
    if (offset < previous) {
      return link.start;
    }
    return offset - link.start < link.end - offset ? link.start : link.end;
  }
  return offset;
}

/// An edit that removes part of a link removes the whole link, so a backspace
/// after one deletes it instead of exposing its id.
class NoteLinkFormatter extends TextInputFormatter {
  const NoteLinkFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final before = oldValue.text;
    final after = newValue.text;
    if (after.length >= before.length || !before.contains('[[')) {
      return newValue;
    }

    // The changed span: everything between the common prefix and suffix.
    final shorter = after.length;
    var prefix = 0;
    while (prefix < shorter && before[prefix] == after[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < shorter - prefix &&
        before[before.length - 1 - suffix] ==
            after[after.length - 1 - suffix]) {
      suffix++;
    }
    var start = prefix;
    var end = before.length - suffix;
    final inserted = after.substring(prefix, after.length - suffix);

    var widened = false;
    for (final link in findNoteLinks(before)) {
      final overlaps = start < link.end && end > link.start;
      final partial = start > link.start || end < link.end;
      if (!overlaps || !partial) {
        continue;
      }
      if (link.start < start) {
        start = link.start;
      }
      if (link.end > end) {
        end = link.end;
      }
      widened = true;
    }
    if (!widened) {
      return newValue;
    }

    return TextEditingValue(
      text: before.replaceRange(start, end, inserted),
      selection: TextSelection.collapsed(offset: start + inserted.length),
    );
  }
}
