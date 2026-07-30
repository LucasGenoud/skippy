/// Open Graph / HTML metadata for a URL, fetched by the backend `/api/unfurl`
/// endpoint and rendered as a rich preview card. Every field except [url] may
/// be null, a bare link still yields a card titled with its host.
class LinkPreview {
  final String url;
  final String? title;
  final String? description;
  final String? image;
  final String? siteName;
  final String? favicon;

  const LinkPreview({
    required this.url,
    this.title,
    this.description,
    this.image,
    this.siteName,
    this.favicon,
  });

  factory LinkPreview.fromJson(Map<String, dynamic> json) => LinkPreview(
    url: json['url'] as String? ?? '',
    title: _clean(json['title']),
    description: _clean(json['description']),
    image: _clean(json['image']),
    siteName: _clean(json['site_name']),
    favicon: _clean(json['favicon']),
  );

  /// The human-friendly host (`www.` stripped) for the card's caption line.
  String get host {
    final uri = Uri.tryParse(url);
    final h = uri?.host ?? '';
    return h.startsWith('www.') ? h.substring(4) : h;
  }

  /// Whether there's any metadata beyond the bare URL worth a rich card.
  bool get hasRichContent =>
      (title != null && title!.isNotEmpty) ||
      (image != null && image!.isNotEmpty);

  static String? _clean(Object? v) {
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }
}
