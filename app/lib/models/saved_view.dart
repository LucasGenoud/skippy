/// A named search, pinned to the sidebar.
///
/// A smart view holds no notes of its own: it is a [query] in the search box's
/// own language (see `util/search_query.dart`), re-evaluated every time it is
/// opened. That is the whole point, "Overdue work" stays right as notes change
/// without anything having to file them anywhere.
///
/// Saved views live in the per-user settings document rather than in the
/// database, so they sync across a user's devices, like the palette and the
/// grid presets. They are deliberately not workspace-scoped: the query is
/// resolved against whichever workspace is open, so "is:pinned has:reminder"
/// is useful in all of them, and a `label:` term simply matches nothing in a
/// workspace with no label by that name.
class SavedView {
  final String id;
  final String name;

  /// The search string this view stands for, operators included.
  final String query;

  /// Key into the curated icon set in `util/label_style.dart`, or null for the
  /// default glyph. Shared with labels on purpose: one icon vocabulary.
  final String? icon;

  /// Hex colour (`#RRGGBB`) for the icon, or null for the theme default.
  final String? color;

  const SavedView({
    required this.id,
    required this.name,
    required this.query,
    this.icon,
    this.color,
  });

  SavedView copyWith({
    String? name,
    String? query,
    String? icon,
    String? color,
  }) => SavedView(
    id: id,
    name: name ?? this.name,
    query: query ?? this.query,
    // Null clears, so an edit that removes the icon or colour sticks.
    icon: icon,
    color: color,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'query': query,
    if (icon != null) 'icon': icon,
    if (color != null) 'color': color,
  };

  /// Null for an entry that carries no id, name, or query: a saved view
  /// without one of those has nothing to show or to run.
  static SavedView? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim();
    final name = (json['name'] as String?)?.trim();
    final query = (json['query'] as String?)?.trim();
    if (id == null || id.isEmpty) return null;
    if (name == null || name.isEmpty) return null;
    if (query == null || query.isEmpty) return null;
    return SavedView(
      id: id,
      name: name,
      query: query,
      icon: (json['icon'] as String?)?.trim().isNotEmpty == true
          ? (json['icon'] as String).trim()
          : null,
      color: (json['color'] as String?)?.trim().isNotEmpty == true
          ? (json['color'] as String).trim()
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SavedView &&
      other.id == id &&
      other.name == name &&
      other.query == query &&
      other.icon == icon &&
      other.color == color;

  @override
  int get hashCode => Object.hash(id, name, query, icon, color);
}
