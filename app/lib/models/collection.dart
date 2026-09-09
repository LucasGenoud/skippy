/// Collections share their workspace's membership and labels.
class NoteCollection {
  final String id;
  final String name;
  final String layout;
  final double position;

  const NoteCollection({
    required this.id,
    required this.name,
    this.layout = 'masonry',
    this.position = 0,
  });
  static const inbox = NoteCollection(id: 'inbox', name: 'Inbox');
  NoteCollection copyWith({String? name, String? layout}) => NoteCollection(
    id: id,
    name: name ?? this.name,
    layout: layout ?? this.layout,
    position: position,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'layout': layout,
    'position': position,
  };
  factory NoteCollection.fromJson(Map<String, dynamic> json) {
    final layout = switch (json['layout']) {
      'masonry' || 'list' || 'board' => json['layout'] as String,
      _ => 'masonry',
    };
    return NoteCollection(
      id: json['id'] as String,
      name: json['name'] as String,
      layout: layout,
      position: (json['position'] as num?)?.toDouble() ?? 0,
    );
  }
}
