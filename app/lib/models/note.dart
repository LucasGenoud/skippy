import 'package:flutter/foundation.dart';

enum NoteKind {
  text,
  checklist,
  markdown;

  /// Wire name used by the API.
  String get wire => name;

  static NoteKind fromWire(String? value) => switch (value) {
    'checklist' => NoteKind.checklist,
    'markdown' => NoteKind.markdown,
    _ => NoteKind.text,
  };
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
  final String username;

  const UserRef({required this.id, required this.username});

  factory UserRef.fromJson(Map<String, dynamic> json) =>
      UserRef(id: json['id'] as String, username: json['username'] as String);
}

class Attachment {
  final String id;
  final String mime;
  final String filename;
  final int size;

  const Attachment({
    required this.id,
    required this.mime,
    this.filename = '',
    this.size = 0,
  });

  bool get isImage => mime.startsWith('image/');

  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
    id: json['id'] as String,
    mime: json['mime'] as String? ?? '',
    filename: json['filename'] as String? ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
  );
}

class Note {
  final String id;
  final NoteKind kind;
  final String title;
  final String content;
  final List<ChecklistItem> items;
  final String color;
  final bool pinned;
  final bool archived;
  final bool trashed;
  final double position;
  final DateTime? reminderAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Set<String> labelIds;
  final UserRef? owner;
  final List<UserRef> collaborators;
  final List<Attachment> attachments;

  const Note({
    required this.id,
    this.kind = NoteKind.text,
    this.title = '',
    this.content = '',
    this.items = const [],
    this.color = 'default',
    this.pinned = false,
    this.archived = false,
    this.trashed = false,
    this.position = 0,
    this.reminderAt,
    required this.createdAt,
    required this.updatedAt,
    this.labelIds = const {},
    this.owner,
    this.collaborators = const [],
    this.attachments = const [],
  });

  bool get isChecklist => kind == NoteKind.checklist;

  bool get isEmpty =>
      title.trim().isEmpty &&
      content.trim().isEmpty &&
      items.every((i) => i.text.trim().isEmpty) &&
      attachments.isEmpty;

  bool get isShared => collaborators.isNotEmpty;

  bool isOwnedBy(String? userId) => owner == null || owner!.id == userId;

  static const _sentinelDate = 'sticky-notes-keep';

  Note copyWith({
    NoteKind? kind,
    String? title,
    String? content,
    List<ChecklistItem>? items,
    String? color,
    bool? pinned,
    bool? archived,
    bool? trashed,
    double? position,
    Object? reminderAt = _sentinelDate,
    DateTime? updatedAt,
    Set<String>? labelIds,
    List<UserRef>? collaborators,
    List<Attachment>? attachments,
  }) {
    return Note(
      id: id,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      content: content ?? this.content,
      items: items ?? this.items,
      color: color ?? this.color,
      pinned: pinned ?? this.pinned,
      archived: archived ?? this.archived,
      trashed: trashed ?? this.trashed,
      position: position ?? this.position,
      reminderAt: reminderAt == _sentinelDate
          ? this.reminderAt
          : reminderAt as DateTime?,
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
      reminderAt: json['reminder_at'] == null
          ? null
          : DateTime.tryParse(json['reminder_at'] as String)?.toLocal(),
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

  static List<Map<String, dynamic>> itemsToJson(List<ChecklistItem> items) => [
    for (final i in items) i.toJson(),
  ];
}

class Label {
  final String id;
  final String name;

  const Label({required this.id, required this.name});

  factory Label.fromJson(Map<String, dynamic> json) =>
      Label(id: json['id'] as String, name: json['name'] as String);
}

@immutable
class AuthUser {
  final String id;
  final String username;

  const AuthUser({required this.id, required this.username});

  factory AuthUser.fromJson(Map<String, dynamic> json) =>
      AuthUser(id: json['id'] as String, username: json['username'] as String);
}
