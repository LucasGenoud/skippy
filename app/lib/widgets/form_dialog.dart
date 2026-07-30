import 'package:flutter/material.dart';

import '../util/motion.dart';

/// Phone-sized viewport, matching the breakpoint the home screen uses.
bool isNarrowScreen(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 600;

/// Presents a short list of choices as a bottom sheet on phones and a compact
/// centered surface on wide layouts. This keeps thumb-friendly actions near
/// the bottom on mobile without stretching a small picker across a web
/// viewport.
Future<T?> showAdaptiveSelectionSurface<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  Color? backgroundColor,
  bool isScrollControlled = false,
  bool showDragHandle = true,
  double maxWidth = 480,
}) {
  final color =
      backgroundColor ?? Theme.of(context).colorScheme.surfaceContainer;
  final dismissalDuration = Motion.overlayDismissalDuration(context);
  final Future<T?> result;
  if (isNarrowScreen(context)) {
    result = showModalBottomSheet<T>(
      context: context,
      backgroundColor: color,
      isScrollControlled: isScrollControlled,
      showDragHandle: showDragHandle,
      useSafeArea: true,
      builder: builder,
    );
  } else {
    result = showDialog<T>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: color,
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: builder(context),
        ),
      ),
    );
  }
  return result.then((value) async {
    await Future<void>.delayed(dismissalDuration);
    return value;
  });
}

/// Presents a [FormDialog] the way the viewport wants it: a centred dialog on
/// wide screens, a pushed full-screen page on phones, where a floating box
/// with several text fields fights the keyboard and wastes the screen.
Future<T?> showFormDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) async {
  final dismissalDuration = Motion.overlayDismissalDuration(context);
  final T? result;
  if (isNarrowScreen(context)) {
    result = await Navigator.of(context).push<T>(
      MaterialPageRoute(
        builder: (context) =>
            _FormDialogMode(fullScreen: true, child: builder(context)),
        fullscreenDialog: true,
      ),
    );
  } else {
    result = await showDialog<T>(
      context: context,
      builder: (context) =>
          _FormDialogMode(fullScreen: false, child: builder(context)),
    );
  }
  await Future<void>.delayed(dismissalDuration);
  return result;
}

/// How the enclosing route was opened. [FormDialog] obeys this rather than
/// re-measuring, so rotating a phone to landscape, which crosses the width
/// threshold, can't leave a page route rendering a floating dialog.
class _FormDialogMode extends InheritedWidget {
  final bool fullScreen;

  const _FormDialogMode({required this.fullScreen, required super.child});

  static bool? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FormDialogMode>()?.fullScreen;

  @override
  bool updateShouldNotify(_FormDialogMode oldWidget) =>
      oldWidget.fullScreen != fullScreen;
}

/// A settings form rendered as an [AlertDialog] on wide screens and as a
/// full-screen page on phones (close button in the app bar, [actions] pinned
/// to the bottom above the keyboard).
///
/// Only worth it for editors with input in them; short confirmations are fine
/// as plain dialogs everywhere.
class FormDialog extends StatelessWidget {
  final Widget title;
  final Widget content;

  /// Width of the dialog body on wide screens; ignored full-screen.
  final double width;

  /// Buttons for the dialog footer, in the usual cancel-then-confirm order.
  final List<Widget> actions;

  /// Whether [content] needs to be wrapped in a scroll view. Pass false when
  /// it scrolls internally (e.g. to keep a row pinned below the scrolling
  /// part).
  final bool scrollable;

  const FormDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.width = 420,
    this.scrollable = true,
  });

  @override
  Widget build(BuildContext context) {
    // The fallback covers a FormDialog shown outside [showFormDialog].
    if (!(_FormDialogMode.of(context) ?? isNarrowScreen(context))) {
      return AlertDialog(
        title: title,
        content: SizedBox(width: width, child: content),
        actions: actions,
        scrollable: scrollable,
      );
    }
    // In a `fullscreenDialog` route the app bar's leading button is a close
    // "X" automatically, so Cancel in [actions] is a second way out, not the
    // only one.
    // A persistent footer is laid out below the keyboard on some mobile
    // embedders. Keep the action row inside the page instead and pad it by
    // the live keyboard inset, so the primary action never disappears while
    // naming a workspace (or editing any other form).
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: title),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: scrollable
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      child: content,
                    )
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: content,
                    ),
            ),
            AnimatedPadding(
              duration: Motion.fast,
              curve: Motion.standard,
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                8 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: actions,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
