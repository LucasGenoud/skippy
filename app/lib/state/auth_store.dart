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
    try {
      user = await api.me();
      await prefs.setString(_userKey, jsonEncode(user!.toJson()));
      status = AuthStatus.signedIn;
    } on ApiException {
      // Token revoked or expired; anything else (network) keeps the token and
      // signs in optimistically so the app works offline.
      api.token = null;
      await prefs.remove(_tokenKey);
      await prefs.remove(_userKey);
      status = AuthStatus.signedOut;
    } catch (_) {
      // Network unreachable: stay signed in with the last-known user so the
      // per-user offline cache (keyed by user id) loads.
      user = _cachedUser(prefs) ?? user;
      status = AuthStatus.signedIn;
    }
    notifyListeners();
  }

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

  Future<void> signOut() async {
    try {
      await api.logout();
    } catch (_) {}
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
