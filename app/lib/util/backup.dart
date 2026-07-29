import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/note.dart';
import '../models/workspace.dart';
import 'mime.dart';

const _backupFormat = 'skippy-backup';
const _backupVersion = 2;
const maxBackupArchiveBytes = 512 * 1024 * 1024;
const _maxManifestBytes = 8 * 1024 * 1024;
const _maxWorkspaces = 1000;
const _maxNotes = 10000;
const _maxLabels = 2000;
const _maxStages = 2000;
const _maxAttachments = 10000;

typedef AttachmentReader = Future<Uint8List> Function(Attachment attachment);
typedef BackupProgress = void Function(int completed, int total);

class BackupBundle {
  final List<BackupWorkspace> workspaces;

  const BackupBundle({required this.workspaces});

  List<BackupLabel> get labels => [
    for (final workspace in workspaces) ...workspace.labels,
  ];

  List<BackupStage> get stages => [
    for (final workspace in workspaces) ...workspace.stages,
  ];

  List<BackupNote> get notes => [
    for (final workspace in workspaces) ...workspace.notes,
  ];

  int get attachmentCount =>
      notes.fold(0, (count, note) => count + note.attachments.length);
}

class BackupWorkspace {
  final String id;
  final String name;
  final bool isDefault;
  final List<BackupLabel> labels;
  final List<BackupStage> stages;
  final List<BackupNote> notes;

  const BackupWorkspace({
    required this.id,
    required this.name,
    required this.isDefault,
    required this.labels,
    required this.stages,
    required this.notes,
  });

  int get attachmentCount =>
      notes.fold(0, (count, note) => count + note.attachments.length);
}

class BackupRestoreResult {
  final int workspaces;
  final int notes;
  final int attachments;
  final int labels;
  final int stages;

  const BackupRestoreResult({
    required this.workspaces,
    required this.notes,
    required this.attachments,
    required this.labels,
    required this.stages,
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
  final double position;

  const BackupLabel({
    required this.id,
    required this.name,
    this.color,
    this.icon,
    this.position = 0,
  });
}

class BackupStage {
  final String id;
  final String name;
  final String? color;
  final double position;

  const BackupStage({
    required this.id,
    required this.name,
    this.color,
    this.position = 0,
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
  final bool trashed;
  final double position;
  final String? stageId;
  final double stagePosition;
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
    this.trashed = false,
    this.position = 0,
    this.stageId,
    this.stagePosition = 0,
    required this.reminderAt,
    required this.createdAt,
    required this.updatedAt,
    required this.labelIds,
    required this.attachments,
  });
}

class BackupChecklistItem {
  final String id;
  final String text;
  final bool done;

  const BackupChecklistItem({
    this.id = '',
    required this.text,
    required this.done,
  });
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

/// Build one portable zip containing every supplied workspace as a distinct
/// container. The caller supplies owned workspaces only; memberships and note
/// collaborators are deliberately not serialized.
Future<Uint8List> createBackupArchive({
  required List<Workspace> workspaces,
  required List<Note> notes,
  required List<Label> labels,
  required List<Stage> stages,
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
  final workspaceDocs = <Map<String, dynamic>>[];

  for (
    var workspaceIndex = 0;
    workspaceIndex < workspaces.length;
    workspaceIndex++
  ) {
    final workspace = workspaces[workspaceIndex];
    final workspaceLabels = [
      for (final label in labels)
        if (label.workspaceId == workspace.id) label,
    ]..sort((a, b) => a.position.compareTo(b.position));
    final workspaceStages = [
      for (final stage in stages)
        if (stage.workspaceId == workspace.id) stage,
    ]..sort((a, b) => a.position.compareTo(b.position));
    final workspaceNotes = [
      for (final note in notes)
        if (note.workspaceId == workspace.id) note,
    ]..sort((a, b) => a.position.compareTo(b.position));
    final noteDocs = <Map<String, dynamic>>[];

    for (var noteIndex = 0; noteIndex < workspaceNotes.length; noteIndex++) {
      final note = workspaceNotes[noteIndex];
      final attachmentDocs = <Map<String, dynamic>>[];
      for (
        var attachmentIndex = 0;
        attachmentIndex < note.attachments.length;
        attachmentIndex++
      ) {
        final attachment = note.attachments[attachmentIndex];
        final bytes = await readAttachment(attachment);
        final path =
            'files/$workspaceIndex/$noteIndex/'
            '$attachmentIndex-${_safeName(attachment.filename)}';
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
          for (final item in note.items)
            {'id': item.id, 'text': item.text, 'done': item.done},
        ],
        'color': note.color,
        'pinned': note.pinned,
        'archived': note.archived,
        'trashed': note.trashed,
        'position': note.position,
        'stage_id': note.stageId,
        'stage_position': note.stagePosition,
        'reminder_at': note.reminderAt?.toUtc().toIso8601String(),
        'created_at': note.createdAt.toUtc().toIso8601String(),
        'updated_at': note.updatedAt.toUtc().toIso8601String(),
        'label_ids': note.labelIds.toList(),
        'attachments': attachmentDocs,
      });
    }

    workspaceDocs.add({
      'id': workspace.id,
      'name': workspace.name,
      'is_default': workspace.isDefault,
      'labels': [
        for (final label in workspaceLabels)
          {
            'id': label.id,
            'name': label.name,
            'color': label.color,
            'icon': label.icon,
            'position': label.position,
          },
      ],
      'stages': [
        for (final stage in workspaceStages)
          {
            'id': stage.id,
            'name': stage.name,
            'color': stage.color,
            'position': stage.position,
          },
      ],
      'notes': noteDocs,
    });
  }

  final manifest = const JsonEncoder.withIndent('  ').convert({
    'format': _backupFormat,
    'version': _backupVersion,
    'exported_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'workspaces': workspaceDocs,
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
  if (manifest['format'] != _backupFormat) {
    throw const FormatException('Unsupported Skippy backup version');
  }

  final version = manifest['version'];
  if (version == 1) {
    return _parseLegacyBackup(manifest, entries);
  }
  if (version != _backupVersion) {
    throw const FormatException('Unsupported Skippy backup version');
  }

  final rawWorkspaces = _list(manifest['workspaces'], 'workspaces');
  if (rawWorkspaces.isEmpty || rawWorkspaces.length > _maxWorkspaces) {
    throw const FormatException('Backup contains an invalid workspace list');
  }

  final usedFiles = <String>{'backup.json'};
  final workspaceIds = <String>{};
  final workspaces = <BackupWorkspace>[];
  var noteCount = 0;
  var labelCount = 0;
  var stageCount = 0;
  var attachmentCount = 0;
  var defaultCount = 0;

  for (final rawWorkspace in rawWorkspaces) {
    final map = _map(rawWorkspace, 'workspace');
    final id = _requiredString(map, 'id', max: 200);
    final name = _requiredString(map, 'name', max: 60).trim();
    final isDefault = map['is_default'] == true;
    if (name.isEmpty || !workspaceIds.add(id)) {
      throw const FormatException('Backup contains an invalid workspace');
    }
    if (isDefault && ++defaultCount > 1) {
      throw const FormatException(
        'Backup contains multiple default workspaces',
      );
    }

    final parsed = _parseWorkspaceContents(
      map,
      entries,
      usedFiles,
      legacy: false,
    );
    noteCount += parsed.notes.length;
    labelCount += parsed.labels.length;
    stageCount += parsed.stages.length;
    attachmentCount += parsed.attachmentCount;
    if (noteCount > _maxNotes ||
        labelCount > _maxLabels ||
        stageCount > _maxStages ||
        attachmentCount > _maxAttachments) {
      throw const FormatException('Backup contains too much workspace data');
    }
    workspaces.add(
      BackupWorkspace(
        id: id,
        name: name,
        isDefault: isDefault,
        labels: parsed.labels,
        stages: parsed.stages,
        notes: parsed.notes,
      ),
    );
  }

  if (entries.keys.any((path) => !usedFiles.contains(path))) {
    throw const FormatException('Backup contains unreferenced files');
  }
  return BackupBundle(workspaces: workspaces);
}

BackupBundle _parseLegacyBackup(
  Map<String, dynamic> manifest,
  Map<String, ArchiveFile> entries,
) {
  final workspaceMap = <String, dynamic>{
    'labels': manifest['labels'],
    'stages': const <dynamic>[],
    'notes': manifest['notes'],
  };
  final usedFiles = <String>{'backup.json'};
  final parsed = _parseWorkspaceContents(
    workspaceMap,
    entries,
    usedFiles,
    legacy: true,
  );
  if (parsed.notes.length > _maxNotes ||
      parsed.labels.length > _maxLabels ||
      parsed.attachmentCount > _maxAttachments) {
    throw const FormatException('Backup contains too much workspace data');
  }
  if (entries.keys.any((path) => !usedFiles.contains(path))) {
    throw const FormatException('Backup contains unreferenced files');
  }
  return BackupBundle(
    workspaces: [
      BackupWorkspace(
        id: 'legacy-default',
        name: 'My notes',
        isDefault: true,
        labels: parsed.labels,
        stages: const [],
        notes: parsed.notes,
      ),
    ],
  );
}

BackupWorkspace _parseWorkspaceContents(
  Map<String, dynamic> map,
  Map<String, ArchiveFile> entries,
  Set<String> usedFiles, {
  required bool legacy,
}) {
  final rawLabels = _list(map['labels'], 'labels');
  final rawStages = _list(map['stages'], 'stages');
  final rawNotes = _list(map['notes'], 'notes');

  final labels = <BackupLabel>[];
  final labelIds = <String>{};
  for (final raw in rawLabels) {
    final label = _map(raw, 'label');
    final id = _requiredString(label, 'id', max: 200);
    final name = _requiredString(label, 'name', max: 100).trim();
    if (name.isEmpty || !labelIds.add(id)) {
      throw const FormatException('Backup contains an invalid label');
    }
    labels.add(
      BackupLabel(
        id: id,
        name: name,
        color: _optionalString(label['color'], max: 32),
        icon: _optionalString(label['icon'], max: 64),
        position: _number(label['position'], legacy ? 0.0 : null),
      ),
    );
  }

  final stages = <BackupStage>[];
  final stageIds = <String>{};
  for (final raw in rawStages) {
    final stage = _map(raw, 'stage');
    final id = _requiredString(stage, 'id', max: 200);
    final name = _requiredString(stage, 'name', max: 100).trim();
    if (name.isEmpty || !stageIds.add(id)) {
      throw const FormatException('Backup contains an invalid board column');
    }
    stages.add(
      BackupStage(
        id: id,
        name: name,
        color: _optionalString(stage['color'], max: 32),
        position: _number(stage['position'], null),
      ),
    );
  }

  final notes = <BackupNote>[];
  for (final raw in rawNotes) {
    final note = _map(raw, 'note');
    final rawKind = _requiredString(note, 'kind', max: 20);
    if (!const {'text', 'markdown', 'checklist', 'audio'}.contains(rawKind)) {
      throw const FormatException('Backup contains an unknown note type');
    }
    final rawItems = _list(note['items'], 'items');
    final rawLabelIds = _list(note['label_ids'], 'label_ids');
    final rawAttachments = _list(note['attachments'], 'attachments');

    final attachments = <BackupAttachment>[];
    for (final rawAttachment in rawAttachments) {
      final attachment = _map(rawAttachment, 'attachment');
      final path = _requiredString(attachment, 'path', max: 500);
      final entry = entries[path];
      if (entry == null || !path.startsWith('files/') || !usedFiles.add(path)) {
        throw const FormatException('Backup attachment data is missing');
      }
      if (entry.size > maxUploadBytes ||
          entry.content.length > maxUploadBytes) {
        throw const FormatException('A backup attachment exceeds 25 MB');
      }
      final declaredSize = attachment['size'];
      if (declaredSize is! num ||
          declaredSize.toInt() != entry.content.length) {
        throw const FormatException('Backup attachment size does not match');
      }
      attachments.add(
        BackupAttachment(
          filename: _requiredString(attachment, 'filename', max: 255),
          mime: _requiredString(attachment, 'mime', max: 200),
          bytes: entry.content,
        ),
      );
    }

    final stageId = _optionalString(note['stage_id'], max: 200);
    notes.add(
      BackupNote(
        id: _requiredString(note, 'id', max: 200),
        kind: NoteKind.fromWire(rawKind),
        title: _string(note['title'], max: 100000),
        content: _string(note['content'], max: 10000000),
        items: [
          for (final rawItem in rawItems)
            if (_map(rawItem, 'checklist item') case final item)
              BackupChecklistItem(
                id: _string(item['id'], max: 200),
                text: _string(item['text'], max: 100000),
                done: item['done'] == true,
              ),
        ],
        color: _string(note['color'], max: 64, fallback: 'default'),
        pinned: note['pinned'] == true,
        archived: note['archived'] == true,
        trashed: note['trashed'] == true,
        position: _number(note['position'], 0),
        stageId: stageId != null && stageIds.contains(stageId) ? stageId : null,
        stagePosition: _number(note['stage_position'], 0),
        reminderAt: _optionalDate(note['reminder_at']),
        createdAt: _requiredDate(note['created_at']),
        updatedAt: _requiredDate(note['updated_at']),
        labelIds: [
          for (final value in rawLabelIds)
            if (value is String && labelIds.contains(value)) value,
        ],
        attachments: attachments,
      ),
    );
  }

  return BackupWorkspace(
    id: '',
    name: '',
    isDefault: false,
    labels: labels,
    stages: stages,
    notes: notes,
  );
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

double _number(Object? value, double? fallback) {
  if (value == null && fallback != null) return fallback;
  if (value is! num || !value.toDouble().isFinite) {
    throw const FormatException('Backup number field is invalid');
  }
  return value.toDouble();
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
