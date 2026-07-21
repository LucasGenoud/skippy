/// Diagnostics for the semantic-search index, shown in Settings: which model
/// embeds notes, its vector width, and how many of the user's notes are
/// indexed. [enabled] is false when the server has semantic search off.
class SearchStats {
  final bool enabled;
  final String model;
  final int dimensions;
  final int totalNotes;
  final int indexedNotes;

  const SearchStats({
    required this.enabled,
    required this.model,
    required this.dimensions,
    required this.totalNotes,
    required this.indexedNotes,
  });

  static const disabled = SearchStats(
    enabled: false,
    model: '',
    dimensions: 0,
    totalNotes: 0,
    indexedNotes: 0,
  );

  factory SearchStats.fromJson(Map<String, dynamic> json) {
    if (json['enabled'] != true) return disabled;
    return SearchStats(
      enabled: true,
      model: json['model'] as String? ?? 'unknown',
      dimensions: (json['dimensions'] as num?)?.toInt() ?? 0,
      totalNotes: (json['total_notes'] as num?)?.toInt() ?? 0,
      indexedNotes: (json['indexed_notes'] as num?)?.toInt() ?? 0,
    );
  }
}
