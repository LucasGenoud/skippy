import 'package:flutter/material.dart';

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

// Date/time formatting lives in SettingsStore (honors the user's format
// preferences); this file keeps only app-wide helpers.

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
