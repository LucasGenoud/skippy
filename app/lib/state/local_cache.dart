import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A tiny persistence seam for the offline notes cache. Swappable — the app
/// uses [PrefsLocalCache] (shared_preferences, which is localStorage on web),
/// tests inject an in-memory fake — mirroring how the store abstracts [Api].
///
/// Each signed-in server/user pair gets one JSON document (notes + labels +
/// checklist history + the pending sync queue). [NotesStore] builds that
/// composite key; this seam deliberately treats it as opaque.
abstract class LocalCache {
  Future<Map<String, dynamic>?> read(String key);
  Future<void> write(String key, Map<String, dynamic> doc);
  Future<void> clear(String key);
}

/// Backed by shared_preferences. On web that is localStorage (~5 MB), which is
/// ample for text notes; the seam lets us move to IndexedDB later if needed.
class PrefsLocalCache implements LocalCache {
  String _storageKey(String key) => 'notes_cache_$key';

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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey(key), jsonEncode(doc));
  }

  @override
  Future<void> clear(String key) async {
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
