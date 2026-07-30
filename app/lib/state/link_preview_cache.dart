import '../api/api_client.dart';
import '../models/link_preview.dart';

/// Session-scoped memoizer for link-preview unfurls. Every distinct URL is
/// fetched at most once and shared across the whole app, every grid card and
/// the open editor that show the same link reuse one in-flight future, so
/// scrolling a grid full of links doesn't storm the backend. Combined with the
/// server's own cache, a link is fetched once per session at most.
class LinkPreviewCache {
  final Api api;
  final Map<String, Future<LinkPreview?>> _inFlight = {};

  LinkPreviewCache({required this.api});

  /// The preview for [url], fetching (and caching) on first request.
  Future<LinkPreview?> preview(String url) =>
      _inFlight.putIfAbsent(url, () => api.unfurl(url));
}
