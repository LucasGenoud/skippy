import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../util/motion.dart';

/// A number that rolls to its new value like an odometer instead of snapping.
///
/// Only the digits that change move. Each one rolls on a single strip: the
/// old digit leaves as the new one arrives on the same eased progress, so the
/// two never drift apart or leave the slot empty. Counting up rolls upward,
/// counting down rolls downward. A digit gained or lost opens or closes its
/// slot in step with the roll, so the width never jumps:
///
///   9 -> 10    tens:  (none) -> 1   slot grows from nothing
///              ones:  9      -> 0   rolls
class RollingCount extends StatefulWidget {
  final int count;
  final TextStyle? style;

  const RollingCount({super.key, required this.count, this.style});

  @override
  State<RollingCount> createState() => _RollingCountState();
}

class _RollingCountState extends State<RollingCount>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.base,
  );
  late final Animation<double> _progress = CurvedAnimation(
    parent: _controller,
    curve: Motion.emphasized,
  );
  late int _from = widget.count;

  @override
  void didUpdateWidget(RollingCount oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.count == widget.count) {
      return;
    }

    _from = oldWidget.count;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Equal-width digits, so a roll never nudges its neighbours.
    return DefaultTextStyle.merge(
      style: (widget.style ?? const TextStyle()).copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      child: AnimatedBuilder(
        animation: _progress,
        builder: (context, _) {
          if (!_controller.isAnimating || Motion.reduced(context)) {
            return Text('${widget.count}');
          }

          return _rolling(_progress.value);
        },
      ),
    );
  }

  Widget _rolling(double t) {
    final from = '$_from';
    final to = '${widget.count}';
    final direction = widget.count > _from ? 1.0 : -1.0;
    final slots = math.max(from.length, to.length);

    // Digits line up from the right; a missing one reads as empty.
    String digitAt(String number, int slot) {
      final index = number.length - slots + slot;
      return index < 0 ? '' : number[index];
    }

    return Semantics(
      label: to,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        textDirection: TextDirection.ltr,
        children: [
          for (var slot = 0; slot < slots; slot++)
            _digit(digitAt(from, slot), digitAt(to, slot), t, direction),
        ],
      ),
    );
  }

  Widget _digit(String from, String to, double t, double direction) {
    if (from == to) {
      return Text(to);
    }

    final width = from.isEmpty
        ? t
        : to.isEmpty
        ? 1 - t
        : 1.0;
    return ClipRect(
      child: Align(
        alignment: Alignment.centerRight,
        widthFactor: width,
        heightFactor: 1,
        child: Stack(
          alignment: Alignment.center,
          children: [
            _strip(from, -direction * t, 1 - t),
            _strip(to, direction * (1 - t), t),
          ],
        ),
      ),
    );
  }

  Widget _strip(String digit, double offset, double opacity) =>
      FractionalTranslation(
        translation: Offset(0, offset),
        child: Opacity(opacity: opacity, child: Text(digit)),
      );
}
