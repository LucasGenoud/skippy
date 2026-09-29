import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/note.dart';
import 'backup.dart' show maxBackupArchiveBytes;
import 'mime.dart';

/// Reads a Google Takeout export of Keep: a zip holding one JSON file per
/// note, next to the files attached to it.
///
///     Takeout/Keep/Shopping.json   {"title", "textContent" | "listContent",
///     Takeout/Keep/1a2b.jpg         "color", "isPinned", "labels", ...}
///
/// Keep's own HTML copies of each note are ignored. Parsing is pure, so the
/// import itself (see `NotesStore.importKeep`) only deals in [KeepNote]s.

const _maxNotes = 10000;

/// Keep's note colours, by the nearest one Skippy has. Keep has more.
const _colors = {
  'RED': 'red',
  'PINK': 'red',
  'ORANGE': 'orange',
  'BROWN': 'orange',
  'YELLOW': 'yellow',
  'GREEN': 'green',
  'TEAL': 'teal',
  'BLUE': 'blue',
  'CERULEAN': 'blue',
  'PURPLE': 'blue',
  'GRAY': 'gray',
};

class KeepItem {
  final String text;
  final bool done;

  const KeepItem(this.text, {required this.done});
}

class KeepAttachment {
  final String filename;
  final String mime;
  final Uint8List bytes;

  const KeepAttachment({
    required this.filename,
    required this.mime,
    required this.bytes,
  });
}

class KeepNote {
  final String title;
  final NoteKind kind;
  final String content;
  final List<KeepItem> items;
  final String color;
  final bool pinned;
  final bool archived;
  final bool trashed;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> labels;
  final List<KeepAttachment> attachments;

  const KeepNote({
    required this.title,
    required this.kind,
    required this.content,
    required this.items,
    required this.color,
    required this.pinned,
    required this.archived,
    required this.trashed,
    required this.createdAt,
    required this.updatedAt,
    required this.labels,
    required this.attachments,
  });
}

class KeepArchive {
  final List<KeepNote> notes;

  /// Attachments a note names that are not in the zip, or are too large to
  /// upload.
  final int missingFiles;

  const KeepArchive({required this.notes, required this.missingFiles});
}

KeepArchive parseKeepArchive(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > maxBackupArchiveBytes) {
    throw const FormatException('The export must be a zip under 512 MB');
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: true);
  } catch (_) {
    throw const FormatException('This file is not a readable zip');
  }

  // Files by folder, then name, so a note only picks up its own attachments.
  final folders = <String, Map<String, ArchiveFile>>{};
  final noteFiles = <ArchiveFile>[];
  var expandedBytes = 0;
  for (final entry in archive.files) {
    if (!entry.isFile) {
      continue;
    }
    expandedBytes += entry.size;
    if (expandedBytes > maxBackupArchiveBytes) {
      throw const FormatException('The unpacked export is larger than 512 MB');
    }
    final (folder, name) = _split(entry.name);
    (folders[folder] ??= {})[name] = entry;
    if (name.toLowerCase().endsWith('.json')) {
      noteFiles.add(entry);
    }
  }

  final notes = <KeepNote>[];
  var missingFiles = 0;
  for (final file in noteFiles) {
    final json = _decodeNote(file);
    if (json == null) {
      continue;
    }
    if (notes.length == _maxNotes) {
      throw const FormatException('The export has more than 10,000 notes');
    }
    final folder = folders[_split(file.name).$1] ?? const {};
    final attachments = <KeepAttachment>[];
    for (final raw in _list(json['attachments'])) {
      final attachment = _attachment(raw, folder);
      if (attachment == null) {
        missingFiles++;
        continue;
      }
      attachments.add(attachment);
    }
    notes.add(_note(json, attachments));
  }
  if (notes.isEmpty) {
    throw const FormatException('No Google Keep notes were found in this zip');
  }
  return KeepArchive(notes: notes, missingFiles: missingFiles);
}

(String, String) _split(String path) {
  final slash = path.lastIndexOf('/');
  if (slash < 0) {
    return ('', path);
  }
  return (path.substring(0, slash), path.substring(slash + 1));
}

/// The note in [file], or null when it is not a Keep note: Takeout zips hold
/// other products' JSON too.
Map<String, dynamic>? _decodeNote(ArchiveFile file) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(file.content as List<int>));
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, dynamic>) {
    return null;
  }
  final isKeep =
      decoded.containsKey('isTrashed') &&
      (decoded.containsKey('textContent') ||
          decoded.containsKey('listContent'));
  return isKeep ? decoded : null;
}

KeepNote _note(Map<String, dynamic> json, List<KeepAttachment> attachments) {
  final list = _list(json['listContent']);
  final isChecklist = json.containsKey('listContent');
  final updatedAt =
      _time(json['userEditedTimestampUsec']) ?? DateTime.now().toUtc();

  // Keep keeps a note's web links beside its text; Skippy finds them in it.
  var content = isChecklist ? '' : _string(json['textContent']);
  final urls = [
    for (final annotation in _list(json['annotations']))
      if (annotation is Map && annotation['url'] is String)
        annotation['url'] as String,
  ];
  for (final url in urls) {
    if (!content.contains(url)) {
      content = content.isEmpty ? url : '$content\n\n$url';
    }
  }

  return KeepNote(
    title: _string(json['title']),
    kind: isChecklist ? NoteKind.checklist : NoteKind.text,
    content: content,
    items: [
      for (final item in list)
        if (item is Map)
          KeepItem(_string(item['text']), done: item['isChecked'] == true),
    ],
    color: _colors[json['color']] ?? 'default',
    pinned: json['isPinned'] == true,
    archived: json['isArchived'] == true,
    trashed: json['isTrashed'] == true,
    createdAt: _time(json['createdTimestampUsec']) ?? updatedAt,
    updatedAt: updatedAt,
    labels: [
      for (final label in _list(json['labels']))
        if (label is Map && _string(label['name']).trim().isNotEmpty)
          _string(label['name']).trim(),
    ],
    attachments: attachments,
  );
}

/// The file a Keep attachment names, found beside its note. Keep sometimes
/// records `.jpeg` for a file it saved as `.jpg`, so the name without its
/// extension is tried too.
KeepAttachment? _attachment(Object? raw, Map<String, ArchiveFile> folder) {
  if (raw is! Map) {
    return null;
  }
  final path = _string(raw['filePath']);
  if (path.isEmpty) {
    return null;
  }
  var file = folder[path];
  if (file == null) {
    final stem = _stem(path);
    for (final MapEntry(:key, :value) in folder.entries) {
      if (_stem(key) == stem && !key.toLowerCase().endsWith('.json')) {
        file = value;
        break;
      }
    }
  }
  if (file == null || file.size > maxUploadBytes) {
    return null;
  }
  final declared = _string(raw['mimetype']);
  return KeepAttachment(
    filename: _split(file.name).$2,
    mime: declared.isEmpty ? mimeFromName(file.name) : declared,
    bytes: Uint8List.fromList(file.content as List<int>),
  );
}

String _stem(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? name : name.substring(0, dot);
}

List<Object?> _list(Object? value) => value is List ? value : const [];

String _string(Object? value) => value is String ? value : '';

DateTime? _time(Object? microseconds) {
  if (microseconds is! num || microseconds <= 0) {
    return null;
  }
  return DateTime.fromMicrosecondsSinceEpoch(microseconds.toInt(), isUtc: true);
}

/// Whether an import brings along the notes that were in Keep's trash.
enum KeepTrash { skip, include }

class KeepImportResult {
  final int notes;
  final int attachments;

  /// Labels created because the workspace had none by that name.
  final int labels;

  const KeepImportResult({
    required this.notes,
    required this.attachments,
    required this.labels,
  });
}
