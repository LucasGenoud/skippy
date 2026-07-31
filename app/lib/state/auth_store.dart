import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../models/note.dart';
import 'local_cache.dart';

enum AuthStatus { restoring, signedOut, signedIn }

class AuthStore extends ChangeNotifier {
  final ApiClient api;

  AuthStatus status = AuthStatus.restoring;
  AuthUser? user;
  bool busy = false;
  String? error;

  /// True only when the current session came from this installation's saved
  /// token. The notes cache uses this to migrate the one legacy, unscoped
  /// cache exactly once; a fresh login to another server must never claim it.
  bool restoredSession = false;

  /// HTTP status of the last auth failure, when it was an [ApiException].
  /// Lets the login screen decide which fields to flag red (401 = both
  /// credentials, 409 = email taken); null for network/other errors.
  int? errorStatus;

  static const _tokenKey = 'sticky_notes_token';
  static const _userKey = 'sticky_notes_user';
  static const _urlsKey = 'sticky_notes_backend_urls';
  static const _activeUrlKey = 'sticky_notes_active_url';

  /// Invalidates authentication work when another attempt or a server/session
  /// switch supersedes it.
  int _authGeneration = 0;

  /// All backend URLs the user has saved.
  List<String> savedUrls = [];

  /// The currently active backend URL.
  String get activeUrl => api.baseUrl;

  AuthStore({required this.api}) {
    api.onUnauthorized = _onSessionRejected;
  }

  // ── Backend URL management ──────────────────────────────────────────────

  /// Load saved URLs from disk (call early, before [restore]).
  Future<void> loadSavedUrls() async {
    final prefs = await SharedPreferences.getInstance();
    savedUrls = prefs.getStringList(_urlsKey) ?? [];
    final active = prefs.getString(_activeUrlKey);
    if (active != null && active.isNotEmpty) {
      api.baseUrl = active;
    }
    // Ensure the current URL is always in the saved list.
    if (!savedUrls.contains(api.baseUrl)) {
      savedUrls.insert(0, api.baseUrl);
      await prefs.setStringList(_urlsKey, savedUrls);
    }
    notifyListeners();
  }

  /// Switch to a different saved backend URL.
  Future<void> setActiveUrl(String url) async {
    if (url == api.baseUrl) return;
    // Sign out of the current server first.
    await _clearSession();
    api.baseUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeUrlKey, url);
    notifyListeners();
  }

  /// Add a new backend URL and switch to it.
  Future<void> addUrl(String url) async {
    final normalized = url.trimRight().replaceAll(RegExp(r'/+$'), '');
    if (normalized.isEmpty) return;
    if (!savedUrls.contains(normalized)) {
      savedUrls.add(normalized);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_urlsKey, savedUrls);
    }
    await setActiveUrl(normalized);
  }

  /// Edit a saved URL in place, preserving its position in the list. Editing
  /// the active URL updates the live connection too.
  Future<void> editUrl(String oldUrl, String newUrl) async {
    final normalized = newUrl.trimRight().replaceAll(RegExp(r'/+$'), '');
    if (normalized.isEmpty || normalized == oldUrl) return;
    if (savedUrls.contains(normalized)) return;
    final index = savedUrls.indexOf(oldUrl);
    if (index == -1) return;
    savedUrls[index] = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_urlsKey, savedUrls);
    if (oldUrl == api.baseUrl) {
      await _clearSession();
      api.baseUrl = normalized;
      await prefs.setString(_activeUrlKey, normalized);
    }
    notifyListeners();
  }

  /// Remove a saved URL (cannot remove the currently active one).
  Future<void> removeUrl(String url) async {
    if (url == api.baseUrl || savedUrls.length <= 1) return;
    savedUrls.remove(url);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_urlsKey, savedUrls);
    notifyListeners();
  }

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_tokenKey);
    if (saved == null) {
      restoredSession = false;
      status = AuthStatus.signedOut;
      notifyListeners();
      return;
    }
    restoredSession = true;
    api.token = saved;
    final cached = _cachedUser(prefs);
    if (cached != null) {
      // Open on the cached session immediately: the notes cache is keyed by
      // user id, so this is what lets the app paint real notes on launch with
      // no network at all. The token is still checked, just off the critical
      // path, in [_verifySession].
      user = cached;
      status = AuthStatus.signedIn;
      notifyListeners();
      unawaited(_verifySession(prefs));
      return;
    }
    // No cached profile (a session saved by an older build, or a write that
    // never landed): the server has to say who this token belongs to before
    // the per-user cache can be keyed, so this one call is worth waiting for.
    try {
      user = await api.me();
      await prefs.setString(_userKey, jsonEncode(user!.toJson()));
      status = AuthStatus.signedIn;
    } on ApiException catch (e) {
      if (_isRejection(e)) {
        api.token = null;
        await prefs.remove(_tokenKey);
        await prefs.remove(_userKey);
        status = AuthStatus.signedOut;
      } else {
        // Without a cached profile there is no trustworthy user id with which
        // to open the offline cache or evaluate owner-only UI. Keep the saved
        // token for a later launch, but do not manufacture a null-user session.
        api.token = null;
        status = AuthStatus.signedOut;
        error = "Can't restore the saved session while the server is offline";
      }
    } catch (_) {
      api.token = null;
      status = AuthStatus.signedOut;
      error = "Can't restore the saved session while the server is offline";
    }
    notifyListeners();
  }

  /// Confirm a restored token after the UI is already up, and refresh the
  /// stored profile. Only an outright rejection signs the user out, being
  /// unable to reach the server is exactly the case the cached session exists
  /// for, and must never cost someone access to their notes.
  Future<void> _verifySession(SharedPreferences prefs) async {
    final verifyingToken = api.token;
    final verifyingBaseUrl = api.baseUrl;
    if (verifyingToken == null) return;
    try {
      final fresh = await api.me();
      if (api.token != verifyingToken || api.baseUrl != verifyingBaseUrl) {
        return;
      }
      user = fresh;
      await prefs.setString(_userKey, jsonEncode(fresh.toJson()));
      notifyListeners();
    } on ApiException catch (e) {
      // A 401 already tripped `onUnauthorized`; clearing again is harmless and
      // covers a 403 the interceptor doesn't watch for.
      if (_isRejection(e) &&
          api.token == verifyingToken &&
          api.baseUrl == verifyingBaseUrl) {
        await _clearSession();
      }
    } catch (_) {
      // Offline: keep the session exactly as it is.
    }
  }

  /// Whether the server actively refused this session, as opposed to failing
  /// to answer (5xx, timeouts), which says nothing about the token.
  bool _isRejection(ApiException e) =>
      e.statusCode == 401 || e.statusCode == 403;

  AuthUser? _cachedUser(SharedPreferences prefs) {
    final raw = prefs.getString(_userKey);
    if (raw == null) return null;
    try {
      return AuthUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _authenticate(
    Future<({String token, AuthUser user})> Function() call,
  ) async {
    final generation = ++_authGeneration;
    final baseUrl = api.baseUrl;
    bool isCurrent() => generation == _authGeneration && api.baseUrl == baseUrl;

    busy = true;
    error = null;
    errorStatus = null;
    notifyListeners();
    try {
      final result = await call();
      if (!isCurrent()) return false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, result.token);
      if (!isCurrent()) {
        if (prefs.getString(_tokenKey) == result.token) {
          await prefs.remove(_tokenKey);
          await prefs.remove(_userKey);
        }
        return false;
      }
      await prefs.setString(_userKey, jsonEncode(result.user.toJson()));
      if (!isCurrent()) {
        if (prefs.getString(_tokenKey) == result.token) {
          await prefs.remove(_tokenKey);
          await prefs.remove(_userKey);
        }
        return false;
      }
      restoredSession = false;
      api.token = result.token;
      user = result.user;
      status = AuthStatus.signedIn;
      return true;
    } on ApiException catch (e) {
      if (!isCurrent()) return false;
      errorStatus = e.statusCode;
      error = switch (e.statusCode) {
        401 => 'Wrong email or password',
        409 => 'That email is already registered',
        _ => e.serverMessage,
      };
      return false;
    } catch (_) {
      if (!isCurrent()) return false;
      error = "Can't reach the server, is it running?";
      return false;
    } finally {
      if (generation == _authGeneration) {
        busy = false;
        notifyListeners();
      }
    }
  }

  /// Clear the last auth error (e.g. when switching between sign-in and
  /// create-account so a stale message doesn't linger).
  void clearError() {
    if (error == null) return;
    error = null;
    errorStatus = null;
    notifyListeners();
  }

  Future<bool> signIn(String email, String password) =>
      _authenticate(() => api.login(email, password));

  Future<bool> registerAccount(String name, String email, String password) =>
      _authenticate(() => api.register(name, email, password));

  Future<void> updateAccount({
    String? name,
    String? email,
    String? currentPassword,
    String? newPassword,
  }) async {
    final updated = await api.updateAccount(
      name: name,
      email: email,
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
    user = updated;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(updated.toJson()));
    notifyListeners();
  }

  /// Permanently delete the server account, then remove this installation's
  /// session and offline note cache. [beforeSignOut] lets a caller close any
  /// authenticated routes before their providers are torn down.
  Future<void> deleteAccount(
    String currentPassword, {
    VoidCallback? beforeSignOut,
  }) async {
    final deletedUserId = user!.id;
    final cacheKey = notesCacheKey(api.baseUrl, deletedUserId);
    await api.deleteAccount(currentPassword);
    beforeSignOut?.call();
    await _clearSession();
    // Let the app dispose its NotesStore before removing the cache, so a
    // queued persistence microtask cannot recreate deleted local data.
    await Future<void>.delayed(Duration.zero);
    try {
      await PrefsLocalCache().clear(cacheKey);
    } catch (_) {
      // The server deletion already succeeded. A best-effort local cleanup
      // failure must not leave the UI pretending the account still exists.
    }
  }

  /// Signing out is a local decision, so the session goes first and the server
  /// is told afterwards, best-effort. Waiting on that round trip meant that
  /// with no connection the button appeared dead for the length of the request
  /// timeout, and then signed out anyway.
  Future<void> signOut() async {
    // Started before the token is cleared: [ApiClient.logout] builds its
    // headers synchronously, so the request still carries the token it is
    // asking the server to revoke. Unreachable server = the token lives out
    // its natural life there; nothing local depends on the answer.
    unawaited(api.logout().catchError((Object _) {}));
    await _clearSession();
  }

  void _onSessionRejected() {
    if (status == AuthStatus.signedIn) {
      _clearSession();
    }
  }

  Future<void> _clearSession() async {
    _authGeneration++;
    busy = false;
    restoredSession = false;
    api.token = null;
    user = null;
    status = AuthStatus.signedOut;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userKey);
    notifyListeners();
  }
}
