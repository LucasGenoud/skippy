import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerPhase;

/// Global messenger so snackbars can be shown from anywhere (including after
/// a route pops, e.g. "Empty note discarded" when the editor closes).
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Semantic flavor of a notification — drives the leading icon chip's tint so
/// the message's nature (a plain confirmation, a destructive action, a
/// problem) reads at a glance. Colors resolve from the active theme, so every
/// kind works in both light and dark mode.
enum SnackKind { normal, success, warning, danger }

/// Show a brief, non-blocking notification (a light elevated "toast").
///
/// Only one is ever on screen: a new call replaces the current one instantly
/// (no laggy cross-fade, no backlog) so rapid actions — delete, then archive,
/// then undo — each read cleanly instead of queuing up behind each other.
/// [icon] gets a tinted round chip whose color follows [kind]. An
/// [actionLabel]/[onAction] pair adds a trailing button (e.g. Undo) and keeps
/// the snack up a little longer so it's reachable.
void showAppSnack(
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  IconData? icon,
  SnackKind kind = SnackKind.normal,
}) {
  final messenger = scaffoldMessengerKey.currentState;
  if (messenger == null) return;
  final hasAction = actionLabel != null && onAction != null;

  void show() {
    final (chipBg, chipFg) = _chipColors(messenger.context, kind);

    // Replace, don't queue: removeCurrentSnackBar is instant, so the new
    // message shows immediately instead of waiting out the previous one's
    // exit animation (the old hideCurrentSnackBar path felt "stuck").
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        // Tighter than the Material default so the bar stays compact.
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        content: Row(
          children: [
            if (icon != null) ...[
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: chipBg,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 15, color: chipFg),
              ),
              const SizedBox(width: 10),
            ],
            // Color comes from snackBarTheme.contentTextStyle (onSurface).
            Expanded(child: Text(message)),
          ],
        ),
        duration: Duration(seconds: hasAction ? 5 : 3),
        // Every notification is dismissable two ways: a trailing close button
        // (shown even alongside an Undo action) and a downward swipe
        // (SnackBar's default dismissDirection).
        showCloseIcon: true,
        action: hasAction
            ? SnackBarAction(
                label: actionLabel,
                onPressed: () {
                  // Dismiss immediately on Undo so the confirmation doesn't
                  // linger after the user has already acted on it.
                  messenger.hideCurrentSnackBar();
                  onAction();
                },
              )
            : null,
      ),
    );
  }

  // Callers fire this from dispose() while a popped route unmounts, which
  // happens mid-frame with the tree locked — showSnackBar's setState would
  // assert. Defer to the end of the in-flight frame in that case.
  if (WidgetsBinding.instance.schedulerPhase == SchedulerPhase.idle) {
    show();
  } else {
    WidgetsBinding.instance.addPostFrameCallback((_) => show());
  }
}

/// (background, foreground) for the leading icon chip. Danger/normal ride the
/// scheme's container roles (already tuned per brightness); success and
/// warning have no scheme slot, so they carry hand-picked tints that stay
/// legible on the elevated surface in both modes.
(Color, Color) _chipColors(BuildContext context, SnackKind kind) {
  final scheme = Theme.of(context).colorScheme;
  final light = scheme.brightness == Brightness.light;
  return switch (kind) {
    SnackKind.danger => (scheme.errorContainer, scheme.onErrorContainer),
    SnackKind.normal => (
      scheme.secondaryContainer,
      scheme.onSecondaryContainer,
    ),
    SnackKind.success => light
        ? (const Color(0xFFD5EFDD), const Color(0xFF0E5A2B))
        : (const Color(0xFF163521), const Color(0xFF9BE0AE)),
    SnackKind.warning => light
        ? (const Color(0xFFFBE9C7), const Color(0xFF7A5300))
        : (const Color(0xFF3A2E12), const Color(0xFFF3C778)),
  };
}
