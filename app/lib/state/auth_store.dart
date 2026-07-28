import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../models/note.dart';

enum AuthStatus { restoring, signedOut, signedIn }

class AuthStore extends ChangeNotifier {
  final ApiClient api;

  AuthStatus status = AuthStatus.restoring;
  AuthUser? user;
  bool busy = false;
  String? error;

  /// HTTP status of the last auth failure, when it was an [ApiException].
  /// Lets the login screen decide which fields to flag red (401 = both
  /// credentials, 409 = email taken); null for network/other errors.
  int? errorStatus;

  static const _tokenKey = 'sticky_notes_token';
  static const _userKey = 'sticky_notes_user';
  static const _urlsKey = 'sticky_notes_backend_urls';
  static const _activeUrlKey = 'sticky_notes_active_url';

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
      status = AuthStatus.signedOut;
      notifyListeners();
      return;
    }
    api.token = saved;
    final cached = _cachedUser(prefs);
    if (cached != null) {
      // Open on the cached session immediately: the notes cache is keyed by
      // user id, so this is what lets the app paint real notes on launch with
      // no network at all. The token is still checked — just off the critical
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
        status = AuthStatus.signedIn;
      }
    } catch (_) {
      // Unreachable: stay signed in so the app is usable offline.
      status = AuthStatus.signedIn;
    }
    notifyListeners();
  }

  /// Confirm a restored token after the UI is already up, and refresh the
  /// stored profile. Only an outright rejection signs the user out — being
  /// unable to reach the server is exactly the case the cached session exists
  /// for, and must never cost someone access to their notes.
  Future<void> _verifySession(SharedPreferences prefs) async {
    try {
      final fresh = await api.me();
      if (api.token == null) return; // signed out while the check was in flight
      user = fresh;
      await prefs.setString(_userKey, jsonEncode(fresh.toJson()));
      notifyListeners();
    } on ApiException catch (e) {
      // A 401 already tripped `onUnauthorized`; clearing again is harmless and
      // covers a 403 the interceptor doesn't watch for.
      if (_isRejection(e)) await _clearSession();
    } catch (_) {
      // Offline: keep the session exactly as it is.
    }
  }

  /// Whether the server actively refused this session, as opposed to failing
  /// to answer (5xx, timeouts) — which says nothing about the token.
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
    busy = true;
    error = null;
    errorStatus = null;
    notifyListeners();
    try {
      final result = await call();
      api.token = result.token;
      user = result.user;
      status = AuthStatus.signedIn;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, result.token);
      await prefs.setString(_userKey, jsonEncode(result.user.toJson()));
      return true;
    } on ApiException catch (e) {
      errorStatus = e.statusCode;
      error = switch (e.statusCode) {
        401 => 'Wrong email or password',
        409 => 'That email is already registered',
        _ => e.serverMessage,
      };
      return false;
    } catch (_) {
      error = "Can't reach the server — is it running?";
      return false;
    } finally {
      busy = false;
      notifyListeners();
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

  /// Signing out is a local decision, so the session goes first and the server
  /// is told afterwards, best-effort. Waiting on that round trip meant that
  /// with no connection the button appeared dead for the length of the request
  /// timeout — and then signed out anyway.
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
    api.token = null;
    user = null;
    status = AuthStatus.signedOut;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userKey);
    notifyListeners();
  }
}
