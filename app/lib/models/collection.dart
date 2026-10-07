/// A shared container; its layout is configured for everyone in the workspace.
class NoteCollection {
  final String id;
  final String workspaceId;
  final String name;
  final String? icon;
  final String? color;
  final String layout;
  final String sort;
  final double position;

  const NoteCollection({
    required this.id,
    required this.workspaceId,
    required this.name,
    this.icon,
    this.color,
    this.layout = 'masonry',
    this.sort = 'custom',
    this.position = 0,
  });

  /// Id of a workspace's base collection, which the server creates with the
  /// workspace. Content that names no collection belongs there.
  static String generalId(String workspaceId) => '$workspaceId-general';

  factory NoteCollection.general(
    String workspaceId, {
    String layout = 'masonry',
  }) => NoteCollection(
    id: generalId(workspaceId),
    workspaceId: workspaceId,
    name: 'General',
    layout: layout,
  );

  factory NoteCollection.fromJson(Map<String, dynamic> j) => NoteCollection(
    id: j['id'] as String,
    workspaceId: j['workspace_id'] as String,
    name: j['name'] as String,
    icon: j['icon'] as String?,
    color: j['color'] as String?,
    layout: j['layout'] as String? ?? 'masonry',
    sort: j['sort'] as String? ?? 'custom',
    position: (j['position'] as num?)?.toDouble() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'workspace_id': workspaceId,
    'name': name,
    'icon': icon,
    'color': color,
    'layout': layout,
    'sort': sort,
    'position': position,
  };
}
