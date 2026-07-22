import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/note.dart';
import 'mime.dart';

const _backupFormat = 'skippy-backup';
const _backupVersion = 1;
const maxBackupArchiveBytes = 512 * 1024 * 1024;
const _maxManifestBytes = 8 * 1024 * 1024;
const _maxNotes = 10000;
const _maxLabels = 2000;
const _maxAttachments = 10000;

typedef AttachmentReader = Future<Uint8List> Function(Attachment attachment);
typedef BackupProgress = void Function(int completed, int total);

class BackupBundle {
  final List<BackupLabel> labels;
  final List<BackupNote> notes;

  const BackupBundle({required this.labels, required this.notes});

  int get attachmentCount =>
      notes.fold(0, (count, note) => count + note.attachments.length);
}

class BackupRestoreResult {
  final int notes;
  final int attachments;
  final int labelsCreated;
  final int labelsReused;

  const BackupRestoreResult({
    required this.notes,
    required this.attachments,
    required this.labelsCreated,
    required this.labelsReused,
  });
}

class BackupRestoreException implements Exception {
  final String message;
  final int restoredNotes;

  const BackupRestoreException(this.message, {required this.restoredNotes});

  @override
  String toString() => message;
}

class BackupLabel {
  final String id;
  final String name;
  final String? color;
  final String? icon;

  const BackupLabel({
    required this.id,
    required this.name,
    this.color,
    this.icon,
  });
}

class BackupNote {
  final String id;
  final NoteKind kind;
  final String title;
  final String content;
  final List<BackupChecklistItem> items;
  final String color;
  final bool pinned;
  final bool archived;
  final DateTime? reminderAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> labelIds;
  final List<BackupAttachment> attachments;

  const BackupNote({
    required this.id,
    required this.kind,
    required this.title,
    required this.content,
    required this.items,
    required this.color,
    required this.pinned,
    required this.archived,
    required this.reminderAt,
    required this.createdAt,
    required this.updatedAt,
    required this.labelIds,
    required this.attachments,
  });
}

class BackupChecklistItem {
  final String text;
  final bool done;

  const BackupChecklistItem({required this.text, required this.done});
}

class BackupAttachment {
  final String filename;
  final String mime;
  final Uint8List bytes;

  const BackupAttachment({
    required this.filename,
    required this.mime,
    required this.bytes,
  });
}

String backupFilename([DateTime? now]) {
  final date = now ?? DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return 'skippy-backup-${date.year}-${two(date.month)}-${two(date.day)}.zip';
}

/// Build one portable zip. Attachment bytes are fetched lazily and stored
/// under opaque paths; the manifest carries their original names and MIME
/// types, so path separators or duplicate filenames cannot collide.
Future<Uint8List> createBackupArchive({
  required List<Note> notes,
  required List<Label> labels,
  required AttachmentReader readAttachment,
  DateTime? now,
  BackupProgress? onProgress,
}) async {
  final archive = Archive();
  final total = notes.fold<int>(
    0,
    (count, note) => count + note.attachments.length,
  );
  var completed = 0;
  final noteDocs = <Map<String, dynamic>>[];

  for (var noteIndex = 0; noteIndex < notes.length; noteIndex++) {
    final note = notes[noteIndex];
    final attachmentDocs = <Map<String, dynamic>>[];
    for (
      var attachmentIndex = 0;
      attachmentIndex < note.attachments.length;
      attachmentIndex++
    ) {
      final attachment = note.attachments[attachmentIndex];
      final bytes = await readAttachment(attachment);
      final path =
          'files/$noteIndex/$attachmentIndex-${_safeName(attachment.filename)}';
      archive.addFile(ArchiveFile.bytes(path, bytes));
      attachmentDocs.add({
        'path': path,
        'filename': attachment.filename,
        'mime': attachment.mime,
        'size': bytes.length,
      });
      completed++;
      onProgress?.call(completed, total);
    }
    noteDocs.add({
      'id': note.id,
      'kind': note.kind.wire,
      'title': note.title,
      'content': note.content,
      'items': [
        for (final item in note.items) {'text': item.text, 'done': item.done},
      ],
      'color': note.color,
      'pinned': note.pinned,
      'archived': note.archived,
      'reminder_at': note.reminderAt?.toUtc().toIso8601String(),
      'created_at': note.createdAt.toUtc().toIso8601String(),
      'updated_at': note.updatedAt.toUtc().toIso8601String(),
      'label_ids': note.labelIds.toList(),
      'attachments': attachmentDocs,
    });
  }

  final manifest = const JsonEncoder.withIndent('  ').convert({
    'format': _backupFormat,
    'version': _backupVersion,
    'exported_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'labels': [
      for (final label in labels)
        {
          'id': label.id,
          'name': label.name,
          'color': label.color,
          'icon': label.icon,
        },
    ],
    'notes': noteDocs,
  });
  archive.addFile(ArchiveFile.string('backup.json', manifest));
  return ZipEncoder().encodeBytes(archive);
}

BackupBundle parseBackupArchive(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > maxBackupArchiveBytes) {
    throw const FormatException('Backup must be a non-empty zip under 512 MB');
  }

  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: true);
  } catch (_) {
    throw const FormatException('This file is not a readable Skippy backup');
  }

  final entries = <String, ArchiveFile>{};
  var expandedBytes = 0;
  for (final entry in archive.files) {
    if (!entry.isFile) continue;
    if (entries.containsKey(entry.name)) {
      throw const FormatException('Backup contains duplicate file paths');
    }
    expandedBytes += entry.size;
    if (expandedBytes > maxBackupArchiveBytes) {
      throw const FormatException('Expanded backup is larger than 512 MB');
    }
    entries[entry.name] = entry;
  }
  final manifestFile = entries['backup.json'];
  if (manifestFile == null || manifestFile.size > _maxManifestBytes) {
    throw const FormatException('Backup manifest is missing or too large');
  }

  final Map<String, dynamic> manifest;
  try {
    final decoded = jsonDecode(utf8.decode(manifestFile.content));
    manifest = (decoded as Map).cast<String, dynamic>();
  } catch (_) {
    throw const FormatException('Backup manifest is invalid');
  }
  if (manifest['format'] != _backupFormat ||
      manifest['version'] != _backupVersion) {
    throw const FormatException('Unsupported Skippy backup version');
  }

  final rawLabels = _list(manifest['labels'], 'labels');
  final rawNotes = _list(manifest['notes'], 'notes');
  if (rawLabels.length > _maxLabels || rawNotes.length > _maxNotes) {
    throw const FormatException('Backup contains too many notes or labels');
  }

  final labels = <BackupLabel>[];
  final labelIds = <String>{};
  for (final raw in rawLabels) {
    final map = _map(raw, 'label');
    final id = _requiredString(map, 'id', max: 200);
    final name = _requiredString(map, 'name', max: 100).trim();
    if (name.isEmpty || !labelIds.add(id)) {
      throw const FormatException('Backup contains an invalid label');
    }
    labels.add(
      BackupLabel(
        id: id,
        name: name,
        color: _optionalString(map['color'], max: 32),
        icon: _optionalString(map['icon'], max: 64),
      ),
    );
  }

  final notes = <BackupNote>[];
  final usedFiles = <String>{'backup.json'};
  var attachmentCount = 0;
  for (final raw in rawNotes) {
    final map = _map(raw, 'note');
    final rawKind = _requiredString(map, 'kind', max: 20);
    if (!const {'text', 'markdown', 'checklist', 'audio'}.contains(rawKind)) {
      throw const FormatException('Backup contains an unknown note type');
    }
    final rawItems = _list(map['items'], 'items');
    final rawLabelIds = _list(map['label_ids'], 'label_ids');
    final rawAttachments = _list(map['attachments'], 'attachments');
    attachmentCount += rawAttachments.length;
    if (attachmentCount > _maxAttachments) {
      throw const FormatException('Backup contains too many attachments');
    }

    final attachments = <BackupAttachment>[];
    for (final rawAttachment in rawAttachments) {
      final attachment = _map(rawAttachment, 'attachment');
      final path = _requiredString(attachment, 'path', max: 500);
      final entry = entries[path];
      if (entry == null || !path.startsWith('files/') || !usedFiles.add(path)) {
        throw const FormatException('Backup attachment data is missing');
      }
      if (entry.size > maxUploadBytes) {
        throw const FormatException('A backup attachment exceeds 25 MB');
      }
      final content = entry.content;
      if (content.length > maxUploadBytes) {
        throw const FormatException('A backup attachment exceeds 25 MB');
      }
      final declaredSize = attachment['size'];
      if (declaredSize is! num || declaredSize.toInt() != content.length) {
        throw const FormatException('Backup attachment size does not match');
      }
      attachments.add(
        BackupAttachment(
          filename: _requiredString(attachment, 'filename', max: 255),
          mime: _requiredString(attachment, 'mime', max: 200),
          bytes: content,
        ),
      );
    }

    final reminder = _optionalDate(map['reminder_at']);
    final created = _requiredDate(map['created_at']);
    final updated = _requiredDate(map['updated_at']);
    notes.add(
      BackupNote(
        id: _requiredString(map, 'id', max: 200),
        kind: NoteKind.fromWire(rawKind),
        title: _string(map['title'], max: 100000),
        content: _string(map['content'], max: 10000000),
        items: [
          for (final rawItem in rawItems)
            if (_map(rawItem, 'checklist item') case final item)
              BackupChecklistItem(
                text: _string(item['text'], max: 100000),
                done: item['done'] == true,
              ),
        ],
        color: _string(map['color'], max: 64, fallback: 'default'),
        pinned: map['pinned'] == true,
        archived: map['archived'] == true,
        reminderAt: reminder,
        createdAt: created,
        updatedAt: updated,
        labelIds: [
          for (final value in rawLabelIds)
            if (value is String && labelIds.contains(value)) value,
        ],
        attachments: attachments,
      ),
    );
  }

  if (entries.keys.any((path) => !usedFiles.contains(path))) {
    throw const FormatException('Backup contains unreferenced files');
  }
  return BackupBundle(labels: labels, notes: notes);
}

List<dynamic> _list(Object? value, String field) {
  if (value is! List) throw FormatException('Backup $field is invalid');
  return value;
}

Map<String, dynamic> _map(Object? value, String field) {
  if (value is! Map) throw FormatException('Backup $field is invalid');
  return value.cast<String, dynamic>();
}

String _requiredString(
  Map<String, dynamic> map,
  String key, {
  required int max,
}) {
  final value = map[key];
  if (value is! String || value.isEmpty || value.length > max) {
    throw FormatException('Backup $key is invalid');
  }
  return value;
}

String _string(Object? value, {required int max, String fallback = ''}) {
  if (value == null) return fallback;
  if (value is! String || value.length > max) {
    throw const FormatException('Backup text field is invalid');
  }
  return value;
}

String? _optionalString(Object? value, {required int max}) {
  if (value == null) return null;
  return _string(value, max: max);
}

DateTime _requiredDate(Object? value) {
  final parsed = value is String ? DateTime.tryParse(value) : null;
  if (parsed == null) throw const FormatException('Backup date is invalid');
  return parsed;
}

DateTime? _optionalDate(Object? value) {
  if (value == null) return null;
  return _requiredDate(value);
}

String _safeName(String filename) {
  final cleaned = filename.replaceAll(RegExp(r'[/\\\x00-\x1f]'), '_').trim();
  return cleaned.isEmpty ? 'file' : cleaned;
}
