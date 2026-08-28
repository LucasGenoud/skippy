import 'package:flutter/material.dart';

import '../theme.dart';
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

  /// Left to the theme by default, which paints a sheet and a dialog on the
  /// same paper. Overriding it makes this surface look unlike every other
  /// modal in the app, so only do it for one that means something different.
  Color? backgroundColor,
  bool isScrollControlled = false,
  bool showDragHandle = true,
  double maxWidth = 480,
}) {
  final dismissalDuration = Motion.overlayDismissalDuration(context);
  final Future<T?> result;
  if (isNarrowScreen(context)) {
    result = showModalBottomSheet<T>(
      context: context,
      backgroundColor: backgroundColor,
      isScrollControlled: isScrollControlled,
      showDragHandle: showDragHandle,
      useSafeArea: true,
      builder: (context) => _ModalPresentation(
        // The drag handle already holds the space a dialog has to pad for.
        sheet: showDragHandle,
        child: builder(context),
      ),
    );
  } else {
    result = showDialog<T>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: backgroundColor,
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: _ModalPresentation(sheet: false, child: builder(context)),
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
      return AppDialog(
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
                      padding: const EdgeInsets.fromLTRB(
                        kModalInset,
                        kModalInset,
                        kModalInset,
                        kModalInset + kSpaceSm,
                      ),
                      child: content,
                    )
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(
                        kModalInset,
                        kModalInset,
                        kModalInset,
                        kSpaceSm,
                      ),
                      child: content,
                    ),
            ),
            AnimatedPadding(
              duration: Motion.fast,
              curve: Motion.standard,
              padding: EdgeInsets.fromLTRB(
                kModalInset,
                kSpaceSm,
                kModalInset,
                kSpaceSm + MediaQuery.viewInsetsOf(context).bottom,
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

/// Whether the modal around this subtree arrived as a bottom sheet.
///
/// The two presentations need different top padding — a sheet's drag handle
/// already stands where a dialog has to pad — and the same content is used for
/// both, so [ModalHeader] reads it here rather than making every caller guess.
class _ModalPresentation extends InheritedWidget {
  final bool sheet;

  const _ModalPresentation({required this.sheet, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ModalPresentation>()?.sheet ??
      isNarrowScreen(context);

  @override
  bool updateShouldNotify(_ModalPresentation oldWidget) =>
      oldWidget.sheet != sheet;
}

/// Whether the modal around this subtree is a bottom sheet rather than a
/// centred dialog. For content that has to be laid out differently in the two,
/// a strip that scrolls under a thumb but wraps in a box.
bool modalIsSheet(BuildContext context) => _ModalPresentation.of(context);

/// Every dialog in the app, so none of them has to restate the padding.
///
/// A plain [AlertDialog] is Material's 24 all round, which is not the inset
/// the app's sheets use; going through one widget is what keeps a confirmation
/// and a picker looking like the same product.
class AppDialog extends StatelessWidget {
  final Widget? icon;
  final Widget title;
  final Widget content;
  final List<Widget> actions;
  final bool scrollable;

  const AppDialog({
    super.key,
    this.icon,
    required this.title,
    required this.content,
    this.actions = const [],
    this.scrollable = false,
  });

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: icon,
    iconPadding: kModalTitlePadding,
    title: title,
    // Read here rather than frozen into the theme: text geometry (the sizes)
    // is localized into the theme only once a `Theme` is built, so the same
    // style taken at theme-construction time arrives without a font size.
    titleTextStyle: Theme.of(context).textTheme.titleLarge,
    titlePadding: icon == null
        ? kModalTitlePadding
        : const EdgeInsets.fromLTRB(kModalInset, kSpaceLg, kModalInset, 0),
    content: content,
    contentPadding: kModalContentPadding,
    actions: actions,
    scrollable: scrollable,
  );
}

/// The title block of a hand-rolled modal: a title, optionally an icon beside
/// it, a one-line explanation under it, and a close button on the right.
///
/// Matches [AppDialog]'s title exactly — same inset, same [TextTheme.titleLarge]
/// — so a picker built out of a Column reads as the same kind of surface as a
/// dialog built out of an [AlertDialog].
class ModalHeader extends StatelessWidget {
  final String title;

  /// One line of explanation under the title. Anything longer belongs in the
  /// body, where it can scroll.
  final String? subtitle;
  final IconData? icon;

  /// Shown as an X on the right. Worth it on a surface with no other way out
  /// (a picker whose actions all commit something); a dialog that ends in
  /// Cancel/Done should leave this null rather than offer two.
  final VoidCallback? onClose;

  const ModalHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sheet = _ModalPresentation.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        kModalInset,
        // A sheet's drag handle has already left this space.
        sheet ? kSpaceXs : kModalInset,
        // The close button carries its own padding; without it the title row
        // would end further from the edge than the body below it starts.
        onClose == null ? kModalInset : kModalInset - kSpaceSm,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: kCompactIconSize,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: kSpaceMd),
              ],
              Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
              if (onClose != null)
                IconButton(
                  tooltip: 'Close',
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
          if (subtitle case final subtitle?)
            Padding(
              padding: const EdgeInsets.only(top: kSpaceXs),
              child: Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The action row of a hand-rolled modal, inset to match [AppDialog]'s.
class ModalFooter extends StatelessWidget {
  final List<Widget> children;

  /// Lay the actions out in a column instead of a trailing row. For a footer
  /// whose buttons are full-width choices rather than Cancel/Done.
  final bool stacked;

  const ModalFooter({super.key, required this.children, this.stacked = false});

  @override
  Widget build(BuildContext context) => Padding(
    // The full inset, unlike a dialog's action row: a footer here can hold
    // text as well as buttons, and text that starts 8px inside the body above
    // it is the misalignment this whole file exists to stop. A sheet keeps a
    // little more under it, where the primary action would otherwise finish
    // level with the bottom of a short phone.
    padding: EdgeInsets.fromLTRB(
      kModalInset,
      kSpaceMd,
      kModalInset,
      _ModalPresentation.of(context) ? kModalInset + kSpaceMd : kModalInset,
    ),
    child: stacked
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          )
        : Row(mainAxisAlignment: MainAxisAlignment.end, children: children),
  );
}

/// Body padding for a hand-rolled modal's scrolling middle: the shared edge on
/// both sides, the header gap on top (a [ModalHeader] sits above it), and the
/// full inset at the bottom, or a smaller one when a [ModalFooter] follows and
/// brings its own.
EdgeInsets modalBodyPadding({bool hasFooter = false}) => EdgeInsets.fromLTRB(
  kModalInset,
  kModalHeaderGap,
  kModalInset,
  hasFooter ? kSpaceSm : kModalInset,
);
