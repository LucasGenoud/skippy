import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerPhase;

/// Global messenger so snackbars can be shown from anywhere (including after
/// a route pops, e.g. "Empty note discarded" when the editor closes).
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void showAppSnack(
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final messenger = scaffoldMessengerKey.currentState;
  if (messenger == null) return;
  void show() {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 4),
        action: actionLabel != null && onAction != null
            ? SnackBarAction(label: actionLabel, onPressed: onAction)
            : null,
      ),
    );
  }

  // The editor calls this from dispose() while a popped route unmounts, which
  // happens mid-frame with the tree locked — showSnackBar's setState would
  // assert. Defer to the end of the in-flight frame in that case.
  if (WidgetsBinding.instance.schedulerPhase == SchedulerPhase.idle) {
    show();
  } else {
    WidgetsBinding.instance.addPostFrameCallback((_) => show());
  }
}

