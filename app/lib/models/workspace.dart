import 'note.dart';

/// A container for notes and labels. Every account has one default workspace
/// and may create more; members are invited per workspace and see every note
/// it holds. Its labels are a shared taxonomy rather than personal ones.
class Workspace {
  final String id;
  final String name;

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
    required this.name,
    this.owner,
    this.members = const [],
    this.isDefault = false,
  });

  bool isOwnedBy(String? userId) => owner == null || owner!.id == userId;

  /// Whether anyone besides the owner is in it.
  bool get isShared => members.isNotEmpty;

  Workspace copyWith({String? name, List<UserRef>? members}) => Workspace(
    id: id,
    name: name ?? this.name,
    owner: owner,
    members: members ?? this.members,
    isDefault: isDefault,
  );

  factory Workspace.fromJson(Map<String, dynamic> json) => Workspace(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
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
    'name': name,
    'owner': owner?.toJson(),
    'members': [for (final m in members) m.toJson()],
    'is_default': isDefault,
  };
}
