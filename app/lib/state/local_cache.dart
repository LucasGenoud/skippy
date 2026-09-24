import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Stable cache identity for one account on one server.
String notesCacheKey(String namespace, String? userId) {
  final account = userId ?? 'local';
  final trimmed = namespace.trim();
  if (trimmed.isEmpty) return account;
  return '${Uri.encodeComponent(trimmed)}::$account';
}

/// A tiny persistence seam for the offline notes cache. Swappable, the app
/// uses [PrefsLocalCache] (shared_preferences, which is localStorage on web),
/// tests inject an in-memory fake, mirroring how the store abstracts [Api].
///
/// Each signed-in server/user pair gets one JSON document (notes + labels +
/// checklist history + the pending sync queue). [NotesStore] builds that
/// composite key; this seam deliberately treats it as opaque.
abstract class LocalCache {
  Future<Map<String, dynamic>?> read(String key);
  Future<void> write(String key, Map<String, dynamic> doc);
  Future<void> clear(String key);
}

/// Backed by shared_preferences. On web that is localStorage, whose limited
/// capacity can be exhausted by a large notebook. The seam allows a different
/// web storage backend without changing the notes store.
class PrefsLocalCache implements LocalCache {
  String _storageKey(String key) => 'notes_cache_$key';

  // Keep only the last successful write. Sync-status notifications can
  // otherwise write the same full document to browser localStorage again.
  ({String key, String json})? _lastWrite;

  @override
  Future<Map<String, dynamic>?> read(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey(key));
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null; // Corrupt cache: behave as if empty.
    }
  }

  @override
  Future<void> write(String key, Map<String, dynamic> doc) async {
    final next = (key: key, json: jsonEncode(doc));
    if (next == _lastWrite) {
      return;
    }
    _lastWrite = null;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_storageKey(key), next.json)) {
      throw StateError('offline storage could not save changes');
    }
    _lastWrite = next;
  }

  @override
  Future<void> clear(String key) async {
    if (_lastWrite?.key == key) {
      _lastWrite = null;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey(key));
  }
}

/// In-memory cache: the default when none is injected. Persists nothing across
/// launches, so the store behaves exactly as it did before offline support.
class MemoryLocalCache implements LocalCache {
  final Map<String, Map<String, dynamic>> _store = {};

  @override
  Future<Map<String, dynamic>?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, Map<String, dynamic> doc) async {
    _store[key] = doc;
  }

  @override
  Future<void> clear(String key) async {
    _store.remove(key);
  }
}
