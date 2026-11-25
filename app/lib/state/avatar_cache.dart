import 'package:flutter/painting.dart';

import '../api/api_client.dart';

/// Session-scoped profile pictures, fetched once per user and version. A
/// version is part of the key, so a replaced picture is fetched again and an
/// unchanged one never is.
///
/// Each picture is one [MemoryImage] for the whole session: a new instance
/// would be a new image-cache key, and the picture would reload, and fade in
/// again, every time a widget showing it rebuilt.
class AvatarCache {
  final Api api;
  final Map<String, Future<ImageProvider?>> _inFlight = {};
  final Map<String, ImageProvider?> _resolved = {};

  AvatarCache({required this.api});

  /// [userId]'s picture at [version]; null when there is none to show.
  Future<ImageProvider?> image(String userId, int version) {
    final key = _key(userId, version);
    return _inFlight.putIfAbsent(key, () async {
      try {
        final bytes = await api.fetchAvatar(userId, version);
        final image = bytes == null || bytes.isEmpty
            ? null
            : MemoryImage(bytes);
        _resolved[key] = image;
        return image;
      } catch (_) {
        // Offline or refused: the initial stands in, and a later build asks
        // again.
        _inFlight.remove(key);
        return null;
      }
    });
  }

  /// The picture if it has already arrived, so a widget built again starts
  /// from it instead of a frame of initials.
  ImageProvider? resolved(String userId, int version) =>
      _resolved[_key(userId, version)];

  static String _key(String userId, int version) => '$userId@$version';
}
