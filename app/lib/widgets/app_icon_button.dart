import 'package:flutter/material.dart';

import '../theme.dart';
import '../util/motion.dart';
import '../util/platform.dart';

/// An icon button for toolbars that are built often, like the editor's.
///
/// Material's [IconButton] with a tooltip is ~56 widgets (ink, focus, hover,
/// tooltip overlay) and about ten times the build cost of this. On a touch
/// screen none of that machinery is seen: a tooltip only shows on a long press
/// and nothing hovers or takes keyboard focus. So touch gets a plain button
/// that says what it does to screen readers, and desktop keeps [IconButton]
/// for its hover tooltip and keyboard focus.
class AppIconButton extends StatelessWidget {
  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const AppIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (!isTouchPrimaryPlatform) {
      return IconButton(icon: icon, tooltip: tooltip, onPressed: onPressed);
    }
    return _TouchIconButton(icon: icon, label: tooltip, onPressed: onPressed);
  }
}

class _TouchIconButton extends StatefulWidget {
  /// The visible pad behind the icon while it is pressed, inside the larger
  /// tap target, matching [IconButton]'s 40 px state layer.
  static const double _padSize = 40;

  /// Material's pressed state layer.
  static const double _pressedAlpha = 0.10;

  /// A disabled control's icon, as Material dims it.
  static const double _disabledAlpha = 0.38;

  final Widget icon;
  final String label;
  final VoidCallback? onPressed;

  const _TouchIconButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  State<_TouchIconButton> createState() => _TouchIconButtonState();
}

class _TouchIconButtonState extends State<_TouchIconButton> {
  bool _pressed = false;

  void _setPressed(bool pressed) {
    if (_pressed == pressed) {
      return;
    }
    setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = widget.onPressed != null;

    // Same colour an IconButton would take here: an app bar hands its own
    // through IconButtonTheme.
    final style = IconButtonTheme.of(context).style;
    final color = enabled
        ? style?.foregroundColor?.resolve(const {}) ?? scheme.onSurfaceVariant
        : style?.foregroundColor?.resolve(const {WidgetState.disabled}) ??
              scheme.onSurface.withValues(
                alpha: _TouchIconButton._disabledAlpha,
              );
    final target = theme.visualDensity
        .effectiveConstraints(
          const BoxConstraints(
            minWidth: kMinInteractiveDimension,
            minHeight: kMinInteractiveDimension,
          ),
        )
        .smallest;

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onTap: widget.onPressed,
        child: SizedBox.fromSize(
          size: target,
          child: Center(
            child: AnimatedContainer(
              duration: Motion.reduced(context) ? Duration.zero : Motion.fast,
              curve: Motion.standard,
              width: _TouchIconButton._padSize,
              height: _TouchIconButton._padSize,
              decoration: BoxDecoration(
                borderRadius: kBorderRadius,
                color: _pressed
                    ? scheme.onSurface.withValues(
                        alpha: _TouchIconButton._pressedAlpha,
                      )
                    : scheme.onSurface.withValues(alpha: 0),
              ),
              child: IconTheme.merge(
                data: IconThemeData(color: color, size: 24),
                child: Center(child: widget.icon),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
