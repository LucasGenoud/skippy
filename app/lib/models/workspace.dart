import 'collection.dart';
import 'note.dart';
import 'saved_view.dart';

/// A container for notes and labels. Every account has one default workspace
/// and may create more; members are invited per workspace and see every note
/// it holds. Its labels are a shared taxonomy rather than personal ones.
class Workspace {
  final String id;
  final List<NoteCollection> collections;
  final List<SavedView> savedViews;
  final String name;
  final bool notesEnabled;
  final bool boardEnabled;

  /// Null only for a workspace created locally that hasn't round-tripped
  /// through the server yet.
  final UserRef? owner;

  /// Everyone invited, excluding the owner.
  final List<UserRef> members;

  /// The workspace created with the account. It can't be deleted or left, so
  /// notes always have somewhere to live.
  final bool isDefault;

  const Workspace({
    required this.id,
    this.collections = const [],
    this.savedViews = const [],
    required this.name,
    this.notesEnabled = true,
    this.boardEnabled = true,
    this.owner,
    this.members = const [],
    this.isDefault = false,
  });

  bool isOwnedBy(String? userId) => owner == null || owner!.id == userId;

  /// Whether anyone besides the owner is in it.
  bool get isShared => members.isNotEmpty;

  Workspace copyWith({
    List<NoteCollection>? collections,
    List<SavedView>? savedViews,
    String? name,
    bool? notesEnabled,
    bool? boardEnabled,
    List<UserRef>? members,
  }) => Workspace(
    id: id,
    collections: collections ?? this.collections,
    savedViews: savedViews ?? this.savedViews,
    name: name ?? this.name,
    notesEnabled: notesEnabled ?? this.notesEnabled,
    boardEnabled: boardEnabled ?? this.boardEnabled,
    owner: owner,
    members: members ?? this.members,
    isDefault: isDefault,
  );

  factory Workspace.fromJson(Map<String, dynamic> json) => Workspace(
    id: json['id'] as String,
    collections: [
      for (final c
          in json['collections'] as List? ??
              [
                NoteCollection.general(
                  json['id'] as String,
                  layout: json['notes_enabled'] == false ? 'board' : 'masonry',
                ).toJson(),
              ])
        NoteCollection.fromJson((c as Map).cast<String, dynamic>()),
    ],
    savedViews: [
      for (final entry in json['smart_views'] as List? ?? const [])
        if (entry is Map<String, dynamic>)
          if (SavedView.fromJson(entry) case final SavedView view) view,
    ],
    name: json['name'] as String? ?? '',
    notesEnabled: json['notes_enabled'] as bool? ?? true,
    boardEnabled: json['board_enabled'] as bool? ?? true,
    owner: json['owner'] == null
        ? null
        : UserRef.fromJson(json['owner'] as Map<String, dynamic>),
    members: ((json['members'] as List?) ?? const [])
        .map((j) => UserRef.fromJson(j as Map<String, dynamic>))
        .toList(),
    isDefault: json['is_default'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'collections': [for (final c in collections) c.toJson()],
    'smart_views': [for (final view in savedViews) view.toJson()],
    'name': name,
    'notes_enabled': notesEnabled,
    'board_enabled': boardEnabled,
    'owner': owner?.toJson(),
    'members': [for (final m in members) m.toJson()],
    'is_default': isDefault,
  };
}
