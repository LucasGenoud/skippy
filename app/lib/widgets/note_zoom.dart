import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../util/motion.dart';

/// How small a note gets when dragged a screen's width.
const double _dragMinScale = 0.6;

/// Corners a dragged note takes on, so it reads as a card being carried.
const double _dragCornerRadius = 20;

/// Dims the grid behind a note that is opening, closing or being dragged.
const double _scrimAlpha = 0.32;

/// A note with no card to return to shrinks to this while it fades out.
const double _looseScale = 0.85;

/// The editor fades in over the middle of the morph and the card face
/// fades out ahead of it, so the two never read as a double exposure.
const Interval _pageFade = Interval(0.3, 0.75);
const Interval _faceFade = Interval(0.0, 0.3);
const Interval _colorFade = Interval(0.0, 0.4);
const Interval _looseFade = Interval(0.0, 0.6);

/// A fullscreen note that grows out of where it was opened and can be
/// carried back with the finger, like iOS's zoom transition:
///
///   open     card ──morph──▶ fullscreen
///   drag     fullscreen ──follows the finger, shrinking──▶ held
///   release  held ──morph──▶ card, or springs back to fullscreen
///
/// The page stays laid out at full size and is only scaled, so nothing
/// reflows during the gesture. The gesture itself belongs to the page, which
/// reports it through [startDrag], [updateDrag] and [endDrag].
class NoteZoomRoute extends ModalRoute<void> {
  /// A note opened from somewhere with no card to grow out of: a
  /// notification, the chat, a board column. It fades in and, when carried
  /// away, fades out where it is released.
  NoteZoomRoute({required this._builder, super.settings}) : _source = null;

  NoteZoomRoute._fromSource(_NoteZoomState source)
    : _builder = source.widget.openBuilder,
      _source = source,
      super(settings: source.widget.routeSettings);

  final WidgetBuilder _builder;
  final _NoteZoomState? _source;

  /// The source's bounds in the navigator, null once it has left the tree.
  Rect? _origin;

  /// Finger travel since the drag began; null when the note is not held.
  final ValueNotifier<Offset?> _held = ValueNotifier(null);
  Offset _anchor = Offset.zero;
  Offset _dragBase = Offset.zero;

  /// Where the note was let go, which the closing morph starts from.
  Rect? _released;
  double _releasedScrim = 0;
  double _releasedRadius = 0;

  AnimationController? _settle;
  Offset? _settleFrom;
  CurvedAnimation? _curved;
  final GlobalKey _pageKey = GlobalKey();

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  bool get opaque => true;

  @override
  Duration get transitionDuration => Motion.slow;

  RenderBox? get _navigatorBox {
    final box = navigator?.context.findRenderObject();
    return box is RenderBox && box.hasSize ? box : null;
  }

  @override
  TickerFuture didPush() {
    _measureOrigin();
    _source?._setHidden(true);
    animation!.addStatusListener(_onStatus);
    return super.didPush();
  }

  @override
  bool didPop(void result) {
    final held = _held.value;
    final box = _navigatorBox;
    if (held != null && box != null) {
      _released = _heldRect(box.size, held);
      _releasedScrim = _heldScrim(box.size, held);
      _releasedRadius = _heldRadius(box.size, held);
    }
    _settle?.stop();
    _settleFrom = null;
    _held.value = null;
    // The grid only lays out again once this route stops covering it.
    SchedulerBinding.instance.addPostFrameCallback((_) => _measureOrigin());
    return super.didPop(result);
  }

  @override
  void dispose() {
    final source = _source;
    if (source != null && source._hidden) {
      SchedulerBinding.instance.addPostFrameCallback(
        (_) => source._setHidden(false),
      );
    }
    _settle?.dispose();
    _curved?.dispose();
    _held.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) {
      _source?._setHidden(false);
    }
  }

  void _measureOrigin() {
    final box = _navigatorBox;
    if (_source == null || box == null) {
      return;
    }
    _origin = _source._rectIn(box);
  }

  /// The finger came down on the page at [globalPosition] and is carrying it.
  void startDrag(Offset globalPosition) {
    final box = _navigatorBox;
    if (box == null || !isCurrent || !animation!.isCompleted) {
      return;
    }

    // A new drag during a spring back picks the note up where it is.
    _settle?.stop();
    _settleFrom = null;
    _dragBase = _held.value ?? Offset.zero;
    if (_held.value == null) {
      _anchor = box.globalToLocal(globalPosition);
    }

    navigator!.didStartUserGesture();
    // Let the grid paint behind the shrinking note.
    overlayEntries.first.opaque = false;
    _held.value = _dragBase;
    SchedulerBinding.instance.addPostFrameCallback((_) => _measureOrigin());
  }

  /// [travel] is the finger's offset from where this drag began.
  void updateDrag(Offset travel) {
    if (_held.value == null) {
      return;
    }
    final next = _dragBase + travel;
    _held.value = Offset(math.max(0, next.dx), next.dy);
  }

  /// Closes the note from where it is held, or settles it back.
  Future<void> endDrag({required bool dismiss}) async {
    final held = _held.value;
    if (held == null) {
      return;
    }
    navigator!.didStopUserGesture();

    if (dismiss) {
      // Goes through the page's PopScope like any other close.
      await navigator!.maybePop();
      if (!isActive) {
        return;
      }
    }
    _springBack(_held.value ?? held);
  }

  void _springBack(Offset from) {
    final settle = _settle ??=
        AnimationController(vsync: navigator!, duration: Motion.base)
          ..addListener(_onSettle)
          ..addStatusListener(_onSettleStatus);
    _settleFrom = from;
    settle.forward(from: 0);
  }

  void _onSettle() {
    final from = _settleFrom;
    if (from == null) {
      return;
    }
    _held.value = Offset.lerp(
      from,
      Offset.zero,
      Motion.emphasized.transform(_settle!.value),
    );
  }

  void _onSettleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _settleFrom == null) {
      return;
    }
    _settleFrom = null;
    _held.value = null;
    if (animation!.isCompleted && overlayEntries.isNotEmpty) {
      overlayEntries.first.opaque = true;
    }
  }

  double _dragProgress(Size size, Offset held) =>
      (held.distance / size.width).clamp(0.0, 1.0);

  /// The note shrinks about the point the finger holds, so that point stays
  /// under the finger: p ↦ anchor + held + scale·(p − anchor).
  Rect _heldRect(Size size, Offset held) {
    final scale = 1 - (1 - _dragMinScale) * _dragProgress(size, held);
    return Rect.fromLTWH(
      _anchor.dx * (1 - scale) + held.dx,
      _anchor.dy * (1 - scale) + held.dy,
      size.width * scale,
      size.height * scale,
    );
  }

  double _heldScrim(Size size, Offset held) =>
      _scrimAlpha * (1 - _dragProgress(size, held));

  // Corners round off early in the drag, then hold.
  double _heldRadius(Size size, Offset held) =>
      _dragCornerRadius * (_dragProgress(size, held) * 4).clamp(0.0, 1.0);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => KeyedSubtree(key: _pageKey, child: _builder(context));

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = _curved ??= CurvedAnimation(
      parent: animation,
      curve: Motion.emphasized,
      reverseCurve: Motion.emphasized.flipped,
    );
    return LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: Listenable.merge([curved, _held]),
        builder: (context, _) => _frame(context, constraints.biggest, child),
      ),
    );
  }

  Widget _frame(BuildContext context, Size size, Widget page) {
    final full = Offset.zero & size;
    final t = animation!.value;
    final held = _held.value;
    final resting = held == null && animation!.isCompleted;
    final reduced = Motion.reduced(context);
    final source = _source;
    final origin = reduced ? null : _origin;
    final openColor = Theme.of(context).colorScheme.surface;

    Rect rect;
    double scrim;
    double radius;
    var fade = 1.0;
    var pageOpacity = 1.0;
    var faceOpacity = 0.0;
    var color = source?.widget.openColor ?? openColor;

    if (held != null) {
      rect = _heldRect(size, held);
      scrim = _heldScrim(size, held);
      radius = _heldRadius(size, held);
    } else {
      final c = _curved!.value;
      final end = _released ?? full;
      final start = origin ?? _loose(end, reduced);
      rect = Rect.lerp(start, end, c)!;
      scrim = (_released == null ? _scrimAlpha : _releasedScrim) * c;
      radius = lerpDouble(
        origin == null ? _dragCornerRadius : source!._radius,
        _released == null ? 0 : _releasedRadius,
        c,
      )!;
      if (origin == null) {
        fade = _looseFade.transform(t);
      } else {
        pageOpacity = _pageFade.transform(t);
        faceOpacity = 1 - _faceFade.transform(t);
        color = Color.lerp(
          source!.widget.closedColor,
          color,
          _colorFade.transform(t),
        )!;
      }
    }

    final scale = rect.width / size.width;
    final boxHeight = rect.height / scale;
    final face = faceOpacity > 0 && source != null && source.mounted
        ? Positioned(
            left: 0,
            top: 0,
            right: 0,
            child: Opacity(
              opacity: faceOpacity,
              child: FittedBox(
                fit: BoxFit.fitWidth,
                alignment: Alignment.topLeft,
                child: SizedBox.fromSize(
                  size: origin!.size,
                  child: Material(
                    type: MaterialType.transparency,
                    child: source.widget.closedBuilder(context, () {}),
                  ),
                ),
              ),
            ),
          )
        : const SizedBox.shrink();

    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: resting ? 0 : scrim),
            ),
          ),
        ),
        Positioned.fill(
          child: Transform(
            transform: Matrix4.translationValues(rect.left, rect.top, 0)
              ..scaleByDouble(scale, scale, 1, 1),
            child: Opacity(
              opacity: fade,
              child: IgnorePointer(
                // A held note keeps the pointer its drag arrived on.
                ignoring: !resting && held == null,
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: size.width,
                  maxWidth: size.width,
                  minHeight: boxHeight,
                  maxHeight: boxHeight,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(radius / scale),
                    clipBehavior: resting ? Clip.none : Clip.antiAlias,
                    child: ColoredBox(
                      color: color,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          face,
                          OverflowBox(
                            alignment: Alignment.topLeft,
                            minWidth: size.width,
                            maxWidth: size.width,
                            minHeight: size.height,
                            maxHeight: size.height,
                            child: Opacity(opacity: pageOpacity, child: page),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Where a note with no card to return to starts from or ends at.
  Rect _loose(Rect rect, bool reduced) {
    if (reduced) {
      return rect;
    }
    return Rect.fromCenter(
      center: rect.center,
      width: rect.width * _looseScale,
      height: rect.height * _looseScale,
    );
  }
}

/// A card or button that opens [openBuilder] in a [NoteZoomRoute] grown out
/// of itself. It hides while the note is open, so the note visibly leaves
/// its slot and returns to it.
class NoteZoom extends StatefulWidget {
  const NoteZoom({
    super.key,
    required this.closedBuilder,
    required this.openBuilder,
    required this.closedColor,
    required this.openColor,
    required this.closedShape,
    this.closedElevation = 0,
    this.routeSettings,
  });

  /// The resting face. `open` pushes the note.
  final Widget Function(BuildContext context, VoidCallback open) closedBuilder;
  final WidgetBuilder openBuilder;
  final Color closedColor;
  final Color openColor;
  final RoundedRectangleBorder closedShape;
  final double closedElevation;
  final RouteSettings? routeSettings;

  @override
  State<NoteZoom> createState() => _NoteZoomState();
}

class _NoteZoomState extends State<NoteZoom> {
  bool _hidden = false;

  double get _radius => widget.closedShape.borderRadius
      .resolve(Directionality.of(context))
      .topLeft
      .x;

  void _setHidden(bool hidden) {
    if (!mounted || _hidden == hidden) {
      return;
    }
    setState(() => _hidden = hidden);
  }

  Rect? _rectIn(RenderBox ancestor) {
    if (!mounted) {
      return null;
    }
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) {
      return null;
    }
    return MatrixUtils.transformRect(
      box.getTransformTo(ancestor),
      Offset.zero & box.size,
    );
  }

  void _open() => Navigator.of(context).push(NoteZoomRoute._fromSource(this));

  @override
  Widget build(BuildContext context) {
    return Visibility(
      visible: !_hidden,
      maintainSize: true,
      maintainState: true,
      maintainAnimation: true,
      child: Material(
        color: widget.closedColor,
        elevation: widget.closedElevation,
        shape: widget.closedShape,
        clipBehavior: Clip.antiAlias,
        child: widget.closedBuilder(context, _open),
      ),
    );
  }
}
