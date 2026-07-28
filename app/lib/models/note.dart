import 'package:flutter/foundation.dart';

enum NoteKind {
  text,
  checklist,
  markdown,
  audio;

  /// Wire name used by the API.
  String get wire => name;

  static NoteKind fromWire(String? value) => switch (value) {
    'checklist' => NoteKind.checklist,
    'markdown' => NoteKind.markdown,
    'audio' => NoteKind.audio,
    _ => NoteKind.text,
  };
}

/// The bounded set of AI edits a user can request for a note.
enum NoteRewriteMode {
  concise('concise'),
  grammar('grammar');

  final String wire;
  const NoteRewriteMode(this.wire);
}

class ChecklistItem {
  final String id;
  final String text;
  final bool done;

  const ChecklistItem({
    required this.id,
    required this.text,
    this.done = false,
  });

  ChecklistItem copyWith({String? text, bool? done}) =>
      ChecklistItem(id: id, text: text ?? this.text, done: done ?? this.done);

  factory ChecklistItem.fromJson(Map<String, dynamic> json) => ChecklistItem(
    id: json['id'] as String,
    text: json['text'] as String? ?? '',
    done: json['done'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'done': done};

  @override
  bool operator ==(Object other) =>
      other is ChecklistItem &&
      other.id == id &&
      other.text == text &&
      other.done == done;

  @override
  int get hashCode => Object.hash(id, text, done);
}

class UserRef {
  final String id;
  final String name;

  const UserRef({required this.id, required this.name});

  factory UserRef.fromJson(Map<String, dynamic> json) => UserRef(
    id: json['id'] as String,
    // Read old cached notes once so an offline upgrade remains usable.
    name: (json['name'] ?? json['username']) as String,
  );

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

class Attachment {
  final String id;
  final String mime;
  final String filename;
  final int size;

  /// Signed, time-limited URL path provided by the server
  /// (`/api/files/{id}?exp=..&sig=..`). The client resolves it against the API
  /// base to load the bytes; null only for a locally-built attachment that
  /// hasn't round-tripped through the server yet.
  final String? url;

  const Attachment({
    required this.id,
    required this.mime,
    this.filename = '',
    this.size = 0,
    this.url,
  });

  bool get isImage => mime.startsWith('image/');
  bool get isAudio => mime.startsWith('audio/');

  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
    id: json['id'] as String,
    mime: json['mime'] as String? ?? '',
    filename: json['filename'] as String? ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    url: json['url'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'mime': mime,
    'filename': filename,
    'size': size,
    if (url != null) 'url': url,
  };
}

class Note {
  final String id;

  /// The workspace holding this note. Everyone in that workspace can see it;
  /// per-note collaborators are an additional, narrower grant.
  final String workspaceId;
  final NoteKind kind;
  final String title;
  final String content;
  final List<ChecklistItem> items;
  final String color;
  final bool pinned;
  final bool archived;
  final bool trashed;
  final double position;

  /// The board column holding this note, or null for unassigned. At most one,
  /// unlike [labelIds] — stages are a separate, exclusive system, which is why
  /// the board never has to guess which column a note belongs in.
  final String? stageId;

  /// Order within [stageId]'s column. Separate from [position] so arranging
  /// the board never reshuffles the grid, and vice versa.
  final double stagePosition;
  final DateTime? reminderAt;

  /// Audio-note transcription state: `none` (not an audio note or no clip yet),
  /// `pending` (Whisper running), `done`, or `failed`. Server-owned.
  final String transcriptStatus;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Set<String> labelIds;
  final UserRef? owner;
  final List<UserRef> collaborators;
  final List<Attachment> attachments;

  const Note({
    required this.id,
    this.workspaceId = '',
    this.kind = NoteKind.text,
    this.title = '',
    this.content = '',
    this.items = const [],
    this.color = 'default',
    this.pinned = false,
    this.archived = false,
    this.trashed = false,
    this.position = 0,
    this.stageId,
    this.stagePosition = 0,
    this.reminderAt,
    this.transcriptStatus = 'none',
    required this.createdAt,
    required this.updatedAt,
    this.labelIds = const {},
    this.owner,
    this.collaborators = const [],
    this.attachments = const [],
  });

  bool get isChecklist => kind == NoteKind.checklist;
  bool get isAudio => kind == NoteKind.audio;

  /// The recorded clip, if this audio note has one.
  Attachment? get audioClip {
    for (final a in attachments) {
      if (a.isAudio) return a;
    }
    return null;
  }

  bool get transcribing => transcriptStatus == 'pending';
  bool get transcriptFailed => transcriptStatus == 'failed';

  bool get isEmpty =>
      title.trim().isEmpty &&
      content.trim().isEmpty &&
      items.every((i) => i.text.trim().isEmpty) &&
      attachments.isEmpty;

  bool get isShared => collaborators.isNotEmpty;

  bool isOwnedBy(String? userId) => owner == null || owner!.id == userId;

  /// Marks a nullable [copyWith] argument as "not passed", so callers can tell
  /// "leave it alone" apart from "set it to null".
  static const _unset = 'sticky-notes-unset';

  Note copyWith({
    String? workspaceId,
    NoteKind? kind,
    String? title,
    String? content,
    List<ChecklistItem>? items,
    String? color,
    bool? pinned,
    bool? archived,
    bool? trashed,
    double? position,
    Object? stageId = _unset,
    double? stagePosition,
    Object? reminderAt = _unset,
    String? transcriptStatus,
    DateTime? updatedAt,
    Set<String>? labelIds,
    List<UserRef>? collaborators,
    List<Attachment>? attachments,
  }) {
    return Note(
      id: id,
      workspaceId: workspaceId ?? this.workspaceId,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      content: content ?? this.content,
      items: items ?? this.items,
      color: color ?? this.color,
      pinned: pinned ?? this.pinned,
      archived: archived ?? this.archived,
      trashed: trashed ?? this.trashed,
      position: position ?? this.position,
      stageId: stageId == _unset ? this.stageId : stageId as String?,
      stagePosition: stagePosition ?? this.stagePosition,
      reminderAt: reminderAt == _unset
          ? this.reminderAt
          : reminderAt as DateTime?,
      transcriptStatus: transcriptStatus ?? this.transcriptStatus,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      labelIds: labelIds ?? this.labelIds,
      owner: owner,
      collaborators: collaborators ?? this.collaborators,
      attachments: attachments ?? this.attachments,
    );
  }

  factory Note.fromJson(Map<String, dynamic> json) {
    return Note(
      id: json['id'] as String,
      workspaceId: json['workspace_id'] as String? ?? '',
      kind: NoteKind.fromWire(json['kind'] as String?),
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      items: ((json['items'] as List?) ?? const [])
          .map((j) => ChecklistItem.fromJson(j as Map<String, dynamic>))
          .toList(),
      color: json['color'] as String? ?? 'default',
      pinned: json['pinned'] as bool? ?? false,
      archived: json['archived'] as bool? ?? false,
      trashed: json['trashed'] as bool? ?? false,
      position: (json['position'] as num?)?.toDouble() ?? 0,
      stageId: json['stage_id'] as String?,
      // Absent for a cache written before boards existed; the grid position is
      // the same seed the server's migration uses.
      stagePosition:
          (json['stage_position'] as num?)?.toDouble() ??
          (json['position'] as num?)?.toDouble() ??
          0,
      reminderAt: json['reminder_at'] == null
          ? null
          : DateTime.tryParse(json['reminder_at'] as String)?.toLocal(),
      transcriptStatus: json['transcript_status'] as String? ?? 'none',
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.now(),
      labelIds: ((json['label_ids'] as List?) ?? const [])
          .cast<String>()
          .toSet(),
      owner: json['owner'] == null
          ? null
          : UserRef.fromJson(json['owner'] as Map<String, dynamic>),
      collaborators: ((json['collaborators'] as List?) ?? const [])
          .map((j) => UserRef.fromJson(j as Map<String, dynamic>))
          .toList(),
      attachments: ((json['attachments'] as List?) ?? const [])
          .map((j) => Attachment.fromJson(j as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Full, lossless serialization — the inverse of [Note.fromJson], used to
  /// cache notes locally for offline use. Keys match the wire format so a
  /// cached note reads back identically to one fetched from the server.
  Map<String, dynamic> toJson() => {
    'id': id,
    'workspace_id': workspaceId,
    'kind': kind.wire,
    'title': title,
    'content': content,
    'items': itemsToJson(items),
    'color': color,
    'pinned': pinned,
    'archived': archived,
    'trashed': trashed,
    'position': position,
    'stage_id': stageId,
    'stage_position': stagePosition,
    'reminder_at': reminderAt?.toUtc().toIso8601String(),
    'transcript_status': transcriptStatus,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'label_ids': labelIds.toList(),
    'owner': owner?.toJson(),
    'collaborators': [for (final c in collaborators) c.toJson()],
    'attachments': [for (final a in attachments) a.toJson()],
  };

  static List<Map<String, dynamic>> itemsToJson(List<ChecklistItem> items) => [
    for (final i in items) i.toJson(),
  ];
}

/// A past state of a note's content from its edit history. Only content is
/// versioned (title/body/checklist/kind) — never organizational state like
/// color, pins, or labels.
class NoteVersion {
  final String id;
  final String noteId;
  final NoteKind kind;
  final String title;
  final String content;
  final List<ChecklistItem> items;

  /// Who authored this state; null for the note's original/legacy snapshot.
  final UserRef? editedBy;
  final DateTime createdAt;

  const NoteVersion({
    required this.id,
    required this.noteId,
    this.kind = NoteKind.text,
    this.title = '',
    this.content = '',
    this.items = const [],
    this.editedBy,
    required this.createdAt,
  });

  bool get isChecklist => kind == NoteKind.checklist;

  factory NoteVersion.fromJson(Map<String, dynamic> json) => NoteVersion(
    id: json['id'] as String,
    noteId: json['note_id'] as String? ?? '',
    kind: NoteKind.fromWire(json['kind'] as String?),
    title: json['title'] as String? ?? '',
    content: json['content'] as String? ?? '',
    items: ((json['items'] as List?) ?? const [])
        .map((j) => ChecklistItem.fromJson(j as Map<String, dynamic>))
        .toList(),
    editedBy: json['edited_by'] == null
        ? null
        : UserRef.fromJson(json['edited_by'] as Map<String, dynamic>),
    // Parsed the same way as Note.created_at/updated_at (no toLocal), so the
    // timeline's timestamps line up with the note's own "Edited" stamp.
    createdAt:
        DateTime.tryParse(json['created_at'] as String? ?? '') ??
        DateTime.now(),
  );
}

class Label {
  final String id;

  /// The workspace this label belongs to. Labels are a shared taxonomy: every
  /// member of that workspace sees and uses the same set.
  final String workspaceId;
  final String name;

  /// Hex colour (`#RRGGBB`) for the label's chip/dot, or null for the theme
  /// default. [icon] is a stable key into the client's curated icon set (see
  /// `util/label_style.dart`), or null for the default label glyph.
  final String? color;
  final String? icon;

  /// Order in the sidebar's label list. Same sparse-position trick as
  /// [Stage.position].
  final double position;

  const Label({
    required this.id,
    required this.name,
    this.workspaceId = '',
    this.color,
    this.icon,
    this.position = 0,
  });

  factory Label.fromJson(Map<String, dynamic> json) => Label(
    id: json['id'] as String,
    workspaceId: json['workspace_id'] as String? ?? '',
    name: json['name'] as String,
    color: json['color'] as String?,
    icon: json['icon'] as String?,
    position: (json['position'] as num?)?.toDouble() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'workspace_id': workspaceId,
    'name': name,
    if (color != null) 'color': color,
    if (icon != null) 'icon': icon,
    'position': position,
  };

  Label copyWith({String? name, String? color, String? icon, double? position}) =>
      Label(
        id: id,
        workspaceId: workspaceId,
        name: name ?? this.name,
        color: color ?? this.color,
        icon: icon ?? this.icon,
        position: position ?? this.position,
      );
}

/// A board column. Stages are workspace state like labels — every member sees
/// the same board — but a separate system on purpose: a note carries any number
/// of labels and at most one stage. Nothing here refers to [Label], and nothing
/// in [Label] refers to this.
///
/// Stages carry no icon: a column header is text-led, and a glyph per column is
/// noise rather than information.
@immutable
class Stage {
  final String id;
  final String workspaceId;
  final String name;

  /// Hex colour (`#RRGGBB`) for the column header, or null for the theme
  /// default.
  final String? color;

  /// Left-to-right order on the board.
  final double position;

  const Stage({
    required this.id,
    required this.name,
    this.workspaceId = '',
    this.color,
    this.position = 0,
  });

  factory Stage.fromJson(Map<String, dynamic> json) => Stage(
    id: json['id'] as String,
    workspaceId: json['workspace_id'] as String? ?? '',
    name: json['name'] as String,
    color: json['color'] as String?,
    position: (json['position'] as num?)?.toDouble() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'workspace_id': workspaceId,
    'name': name,
    if (color != null) 'color': color,
    'position': position,
  };

  Stage copyWith({String? name, String? color, double? position}) => Stage(
    id: id,
    workspaceId: workspaceId,
    name: name ?? this.name,
    color: color ?? this.color,
    position: position ?? this.position,
  );
}

@immutable
class AuthUser {
  final String id;
  final String name;
  final String email;

  const AuthUser({required this.id, required this.name, required this.email});

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
    id: json['id'] as String,
    name: (json['name'] ?? json['username'] ?? '') as String,
    email: json['email'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'email': email};
}
