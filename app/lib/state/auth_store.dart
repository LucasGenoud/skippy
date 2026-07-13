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

  static const _tokenKey = 'sticky_notes_token';

  AuthStore({required this.api}) {
    api.onUnauthorized = _onSessionRejected;
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
      status = AuthStatus.signedIn;
    } on ApiException {
      // Token revoked or expired; anything else (network) keeps the token and
      // signs in optimistically so the app works offline.
      api.token = null;
      await prefs.remove(_tokenKey);
      status = AuthStatus.signedOut;
    } catch (_) {
      status = AuthStatus.signedIn;
    }
    notifyListeners();
  }

  Future<bool> _authenticate(
    Future<({String token, AuthUser user})> Function() call,
  ) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final result = await call();
      api.token = result.token;
      user = result.user;
      status = AuthStatus.signedIn;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, result.token);
      return true;
    } on ApiException catch (e) {
      error = switch (e.statusCode) {
        401 => 'Wrong username or password',
        409 => 'That username is taken',
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

  Future<bool> signIn(String username, String password) =>
      _authenticate(() => api.login(username, password));

  Future<bool> registerAccount(String username, String password) =>
      _authenticate(() => api.register(username, password));

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
    notifyListeners();
  }
}
