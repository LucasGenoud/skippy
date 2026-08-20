import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../util/motion.dart';

/// A horizontal swipe across a note card that archives it, in either
/// direction.
///
/// Touch only. On a phone the card is the whole target: there is no hover row
/// of actions to reach for, and the menu behind a long press is three taps
/// away from archiving. Both directions do the same thing on purpose — the
/// gesture means "get this off the grid", and giving the two sides different
/// jobs would make the user aim before they swipe. It reverses for a note that
/// is already archived, so the archive view can put one back.
class SwipeToArchive extends StatefulWidget {
  /// False on the platforms and views where the gesture doesn't apply; the
  /// child is then returned untouched, with no gesture recognizer competing
  /// for the pointer.
  final bool enabled;

  /// Drives the direction of the action, not of the gesture: an archived note
  /// swipes back out of the archive.
  final bool archived;

  final VoidCallback onArchive;

  /// Fires true while the card is off its slot and false once it has settled
  /// back or gone. Layouts that stack their children (see [AnimatedMasonry])
  /// use it to paint this card above its neighbours for the duration.
  final ValueChanged<bool>? onActive;

  final Widget child;

  const SwipeToArchive({
    super.key,
    required this.enabled,
    required this.archived,
    required this.onArchive,
    required this.child,
    this.onActive,
  });

  @override
  State<SwipeToArchive> createState() => _SwipeToArchiveState();
}

class _SwipeToArchiveState extends State<SwipeToArchive>
    with SingleTickerProviderStateMixin {
  /// How far across its own width a card has to travel to commit. Capped in
  /// pixels as well, so the wide card of a one-column list doesn't ask for a
  /// drag halfway across the screen.
  static const double _commitFraction = 0.35;
  static const double _maxCommitDistance = 120;

  /// A flick past this (px/s) commits from wherever it is, the same threshold
  /// Material's own dismissible uses.
  static const double _minFlingVelocity = 700;

  /// Where in its travel the card starts fading. Below this it stays solid, so
  /// an exploratory drag looks like a card being held, not one dissolving.
  static const double _fadeFrom = 0.55;

  /// Signed fraction of the card's width that the card is offset by.
  ///
  /// Built in [initState] rather than lazily: a disabled swipe never touches
  /// it, and a `late` field would then be initialised for the first time by
  /// [dispose], while the element is already deactivated.
  late final AnimationController _move;

  double _width = 0;
  double _height = 0;

  /// Where the finger grabbed the card, so the revealed icon comes up beside
  /// it rather than in the middle of a tall note.
  double _pointerY = 0;
  bool _dragging = false;
  bool _armed = false;

  /// Whether the card is on its way out (or coming back from it), as opposed
  /// to being carried by a finger. The panel behind it fades with it then, so
  /// the slot empties instead of flashing a bare block of accent for the frame
  /// between the card leaving and the tile going with it.
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _move = AnimationController(
      vsync: this,
      value: 0,
      lowerBound: -1,
      upperBound: 1,
      duration: Motion.base,
    );
  }

  @override
  void dispose() {
    _move.dispose();
    super.dispose();
  }

  double get _commitDistance =>
      math.min(_width * _commitFraction, _maxCommitDistance);

  Duration _duration(Duration d) => Motion.reduced(context) ? Duration.zero : d;

  void _onStart(DragStartDetails details) {
    final size = context.size;
    if (size == null || size.width == 0) return;
    _width = size.width;
    _height = size.height;
    _pointerY = details.localPosition.dy;
    _dragging = true;
    _armed = false;
    widget.onActive?.call(true);
  }

  void _onUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    _move.value = (_move.value + (details.primaryDelta ?? 0) / _width).clamp(
      -1.0,
      1.0,
    );
    final armed = _move.value.abs() * _width >= _commitDistance;
    if (armed == _armed) return;
    _armed = armed;
    // Only on the way in: the click says "let go now and it's archived", and
    // repeating it on the way back out would turn a hesitant drag into a
    // rattle.
    if (armed) HapticFeedback.selectionClick();
  }

  void _onEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    final travelled = _move.value * _width;
    final velocity = details.primaryVelocity ?? 0;
    final flung =
        velocity.abs() >= _minFlingVelocity &&
        travelled != 0 &&
        velocity.sign == travelled.sign;
    if (travelled.abs() >= _commitDistance || flung) {
      _commit(travelled.sign);
    } else {
      _settleBack();
    }
  }

  void _onCancel() {
    if (!_dragging) return;
    _dragging = false;
    _settleBack();
  }

  Future<void> _settleBack() async {
    await _move.animateTo(
      0,
      duration: _duration(Motion.fast),
      curve: Motion.standard,
    );
    if (mounted) widget.onActive?.call(false);
  }

  Future<void> _commit(double direction) async {
    setState(() => _leaving = true);
    await _move.animateTo(
      direction == 0 ? 1 : direction,
      duration: _duration(Motion.base),
      curve: Motion.emphasized,
    );
    if (!mounted) return;
    widget.onArchive();
    // Most views drop the note as it is archived and take this card with it,
    // which is the whole point of the gesture. A view that holds on to it (a
    // label lists its archived notes, so does a reminder) leaves this widget
    // mounted, and a card parked off its slot would read as a hole in the
    // grid. One frame is what the store's rebuild needs to say which happened;
    // if the card is still here afterwards, slide it back into place.
    await SchedulerBinding.instance.endOfFrame;
    if (!mounted) return;
    await _move.animateTo(
      0,
      duration: _duration(Motion.base),
      curve: Motion.emphasized,
    );
    if (!mounted) return;
    setState(() => _leaving = false);
    widget.onActive?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return GestureDetector(
      onHorizontalDragStart: _onStart,
      onHorizontalDragUpdate: _onUpdate,
      onHorizontalDragEnd: _onEnd,
      onHorizontalDragCancel: _onCancel,
      child: AnimatedBuilder(
        animation: _move,
        builder: (context, child) {
          final value = _move.value;
          final travelled = value.abs();
          final opacity = travelled <= _fadeFrom
              ? 1.0
              : (1 - (travelled - _fadeFrom) / (1 - _fadeFrom)).clamp(0.0, 1.0);
          // A fixed number of children, always: the card keeps its element
          // (and with it the open-container transition and everything the
          // body has resolved) instead of being re-inflated at both ends of
          // every swipe.
          return Stack(
            children: [
              Positioned.fill(
                child: Opacity(
                  opacity: _leaving ? opacity : 1,
                  child: _ArchiveReveal(
                    // The panel reaches full strength exactly when releasing
                    // would archive, so the colour is the affordance.
                    progress: _commitDistance == 0
                        ? 0
                        : (travelled * _width / _commitDistance).clamp(
                            0.0,
                            1.0,
                          ),
                    toTrailing: value > 0,
                    archived: widget.archived,
                    pointerY: _pointerY,
                    height: _height,
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset(value * _width, 0),
                child: Opacity(opacity: opacity, child: child),
              ),
            ],
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// What sits under a card being swiped: the accent panel and its icon.
///
/// [progress] runs 0 to 1 as the card approaches the point where letting go
/// archives it, and everything here is a function of it — the panel warms from
/// the quiet accent wash to the accent itself and the icon grows into place,
/// so the gesture is legible before the finger lifts.
class _ArchiveReveal extends StatelessWidget {
  static const double _chip = 40;

  final double progress;

  /// Which edge the card is uncovering: it slid right, so the panel shows on
  /// the left.
  final bool toTrailing;
  final bool archived;
  final double pointerY;
  final double height;

  const _ArchiveReveal({
    required this.progress,
    required this.toTrailing,
    required this.archived,
    required this.pointerY,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    if (progress <= 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    // Held back by a cubic so the panel stays the quiet wash through an
    // exploratory drag and then warms decisively over the last stretch: a
    // linear ramp is halfway to the accent by the halfway mark, which reads as
    // armed well before releasing would do anything.
    final warmth = Curves.easeInCubic.transform(progress);
    final panel = Color.lerp(
      scheme.secondaryContainer,
      scheme.primaryContainer,
      warmth,
    )!;
    final ink = Color.lerp(
      scheme.onSecondaryContainer,
      scheme.onPrimaryContainer,
      warmth,
    )!;
    // Beside the finger rather than centred: a long note's middle can be a
    // screen away from the hand that is swiping it.
    final top = math.max(0.0, math.min(pointerY - _chip / 2, height - _chip));
    return ClipRRect(
      borderRadius: kBorderRadius,
      child: ColoredBox(
        color: panel,
        child: Stack(
          children: [
            Positioned(
              top: top,
              left: toTrailing ? 0 : null,
              right: toTrailing ? null : 0,
              width: _chip + 12,
              height: _chip,
              child: Center(
                child: Transform.scale(
                  scale: 0.7 + 0.3 * progress,
                  child: Icon(
                    archived
                        ? Icons.unarchive_outlined
                        : Icons.archive_outlined,
                    size: 22,
                    color: ink,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
