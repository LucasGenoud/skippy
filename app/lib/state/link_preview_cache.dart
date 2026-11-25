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
  final Map<String, LinkPreview?> _resolved = {};

  LinkPreviewCache({required this.api});

  /// The preview for [url], fetching (and caching) on first request.
  Future<LinkPreview?> preview(String url) => _inFlight.putIfAbsent(url, () {
    final fetch = api.unfurl(url);
    fetch.then((value) => _resolved[url] = value, onError: (_) {});
    return fetch;
  });

  /// The preview for [url] if its fetch has finished, so a card built for a
  /// link already fetched starts from it instead of a frame of bare host.
  LinkPreview? resolved(String url) => _resolved[url];
}
