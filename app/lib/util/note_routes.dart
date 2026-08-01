import 'package:flutter/material.dart';

/// The route name every editor showing an existing note carries.
///
/// Names are what let an open request that arrives from outside the widget tree
/// — a home-screen widget tap, a reminder notification — find out whether that
/// note is already on screen. New notes have no id yet and stay unnamed.
String noteRouteName(String noteId) => 'note/$noteId';

/// Remembers which routes the navigator is holding.
///
/// Without this, every tap on the same home-screen widget pushed another copy
/// of the note: three taps meant three back presses to reach the list again.
/// The navigator exposes no way to read its stack, so we watch it being built.
class OpenNoteRoutes extends NavigatorObserver {
  final List<Route<dynamic>> _routes = [];

  /// Whether a route by that name is currently on the stack.
  bool isOpen(String name) => _routes.any((r) => r.settings.name == name);

  /// Show [noteId], for a tap that came from outside the app: the home screen,
  /// or a reminder notification.
  ///
  /// Tapping the same widget twice means "show me this note", not "open a
  /// second copy of it". So when that note is already on the stack this comes
  /// back to it — taking down whatever was covering it — rather than pushing an
  /// editor the user then has to back out of twice. [build] makes the editor
  /// when the note is not open yet.
  void showNote(NavigatorState navigator, String noteId, WidgetBuilder build) {
    final name = noteRouteName(noteId);
    if (isOpen(name)) {
      navigator.popUntil((route) => route.settings.name == name);
      return;
    }
    navigator.push(
      MaterialPageRoute<void>(settings: RouteSettings(name: name), builder: build),
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _routes.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _routes.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _routes.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final at = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (at < 0) {
      if (newRoute != null) _routes.add(newRoute);
      return;
    }
    if (newRoute == null) {
      _routes.removeAt(at);
    } else {
      _routes[at] = newRoute;
    }
  }
}
