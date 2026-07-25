import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// App-level guard for the fragile moments around a trip to the background.
///
/// Two things happen on the way out, both once per backgrounding:
///
/// * [onBackground] runs (the app flushes pending note edits — iOS hands a
///   suspended app only a short grace period and may kill it outright);
/// * on mobile, the focused field is unfocused. iOS suspends the app with
///   the text-input session still live, and on return that session is often
///   stale — the keyboard sticks around or typing goes dead entirely
///   (flutter/flutter#138403 and friends). Closing the editing session
///   before suspension sidesteps the whole family; the note itself is
///   already saved, so nothing is lost but the caret.
///
/// On the way back in, [onForeground] runs once — a suspended app's sockets
/// and timers are dead, so whoever owns the network wants to know.
class BackgroundGuard extends StatefulWidget {
  final VoidCallback? onBackground;

  /// Called on `resumed`, and only after an actual trip to the background —
  /// never for the `inactive` blips that a control-center swipe or an
  /// incoming call produce.
  final VoidCallback? onForeground;
  final Widget child;

  const BackgroundGuard({
    super.key,
    this.onBackground,
    this.onForeground,
    required this.child,
  });

  @override
  State<BackgroundGuard> createState() => _BackgroundGuardState();
}

class _BackgroundGuardState extends State<BackgroundGuard>
    with WidgetsBindingObserver {
  /// `hidden` and `paused` both fire on the way out; act on the first only.
  bool _wentBackground = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final background =
        state == AppLifecycleState.hidden || state == AppLifecycleState.paused;
    if (!background) {
      // `inactive` is also on the path out (and fires on its own for
      // interruptions that never suspend the app), so only `resumed` after a
      // real trip counts as coming back.
      if (_wentBackground && state == AppLifecycleState.resumed) {
        _wentBackground = false;
        widget.onForeground?.call();
      }
      return;
    }
    if (_wentBackground) return;
    _wentBackground = true;

    widget.onBackground?.call();

    // Only mobile suspends apps; on web/desktop a hidden window keeps its
    // caret, and unfocusing there would cost it for no benefit.
    final mobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android);
    if (mobile) FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
