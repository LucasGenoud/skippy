import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../state/drawing.dart';
import '../../theme.dart';
import '../../util/motion.dart';
import '../../util/snack.dart';
import 'drawing_painter.dart';

/// Pen sizes, in drawing units.
const List<double> _penWidths = [4, 8, 16];

/// Colours a stroke can take besides the theme-following ink.
const List<int> _penColors = [0xE5484D, 0xF76B15, 0x30A46C, 0x0090FF, 0x8E4EC6];

/// How close a sample has to move from the last one to be recorded, in
/// drawing units. A pen reports far more often than a line needs.
const double _minSampleGap = 2;

/// The eraser's reach around the pointer, in drawing units.
const double _eraserRadius = 14;

/// Free sheet kept under the lowest stroke, so there is always somewhere to
/// carry on drawing and the canvas grows as the sketch does.
const double _roomBelow = 250;

/// The sheet grows by whole steps of this many drawing units, so a stroke
/// near the bottom adds a page rather than nudging the editor taller after
/// every line.
const double _growStep = 500;

/// Size of one tool button and the inset that keeps its shape off the tray's
/// edge.
const double _toolSize = 36;
const double _trayInset = 4;

enum _Tool { pen, eraser }

/// The editor's drawing surface: a tool tray over a sheet that records pen,
/// touch and mouse strokes. Each finished stroke or erase is handed to
/// [onChanged] whole, so one gesture is one undo step.
class DrawingCanvas extends StatefulWidget {
  final Drawing drawing;
  final ValueChanged<Drawing>? onChanged;

  const DrawingCanvas({super.key, required this.drawing, this.onChanged});

  @override
  State<DrawingCanvas> createState() => _DrawingCanvasState();
}

class _DrawingCanvasState extends State<DrawingCanvas> {
  final _live = ValueNotifier<Stroke?>(null);
  final _livePoints = <Offset>[];
  var _tool = _Tool.pen;
  var _width = _penWidths[1];
  int? _color;

  /// The drawing while an erase is in progress, shown at once and handed on
  /// when the gesture ends.
  Drawing? _erasing;

  /// Where the eraser last was, so the next sample erases the path between.
  Offset? _eraserAt;

  double _scale = 1;

  /// The tallest the sheet has been while open, in drawing units. It never
  /// shrinks under the pen: erasing the lowest stroke keeps the page.
  double _sheetHeight = 0;

  bool get _readOnly => widget.onChanged == null;

  Drawing get _shown => _erasing ?? widget.drawing;

  @override
  void dispose() {
    _live.dispose();
    super.dispose();
  }

  Offset _toDrawing(Offset local) => local / _scale;

  void _onStart(DragStartDetails details) {
    final point = _toDrawing(details.localPosition);
    if (_tool == _Tool.eraser) {
      _erasing = widget.drawing;
      _eraserAt = point;
      _erase(point);
      return;
    }
    _livePoints
      ..clear()
      ..add(point);
    _live.value = Stroke(color: _color, width: _width, points: [point]);
  }

  void _onUpdate(DragUpdateDetails details) {
    final point = _toDrawing(details.localPosition);
    if (_tool == _Tool.eraser) {
      _erase(point);
      return;
    }
    if ((point - _livePoints.last).distance < _minSampleGap) {
      return;
    }
    _livePoints.add(point);
    _live.value = Stroke(
      color: _color,
      width: _width,
      points: List.of(_livePoints),
    );
  }

  void _onEnd() {
    if (_tool == _Tool.eraser) {
      final erased = _erasing;
      setState(() => _erasing = null);
      if (erased != null && !identical(erased, widget.drawing)) {
        widget.onChanged?.call(erased);
      }
      return;
    }

    final points = simplifyStroke(_livePoints);
    _live.value = null;
    if (points.isEmpty) {
      return;
    }
    final next = widget.drawing.add(
      Stroke(color: _color, width: _width, points: points),
    );
    if (next.encode().length > kMaxDrawingChars) {
      showAppSnack('This drawing is full. Start another note.');
      return;
    }
    widget.onChanged?.call(next);
  }

  void _erase(Offset point) {
    final current = _erasing ?? widget.drawing;
    final next = current.eraseAlong(_eraserAt ?? point, point, _eraserRadius);
    _eraserAt = point;
    if (!identical(next, current)) {
      setState(() => _erasing = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = scheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_readOnly) ...[
          _toolTray(scheme),
          const SizedBox(height: kSpaceSm),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            _scale = constraints.maxWidth / kDrawingWidth;
            final height = _sheetHeightFor(_shown);
            final sheet = DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: kBorderRadius,
                border: Border.all(color: hairlineColor(scheme)),
              ),
              child: AnimatedContainer(
                duration: Motion.base,
                curve: Motion.standard,
                height: height * _scale,
                child: ClipRRect(
                  borderRadius: kBorderRadius,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      RepaintBoundary(
                        child: CustomPaint(
                          painter: DrawingPainter(drawing: _shown, ink: ink),
                        ),
                      ),
                      CustomPaint(
                        painter: LiveStrokePainter(stroke: _live, ink: ink),
                      ),
                    ],
                  ),
                ),
              ),
            );
            if (_readOnly) {
              return sheet;
            }
            return MouseRegion(
              cursor: _tool == _Tool.pen
                  ? SystemMouseCursors.precise
                  : SystemMouseCursors.basic,
              child: RawGestureDetector(
                behavior: HitTestBehavior.opaque,
                gestures: {
                  _EagerPanRecognizer:
                      GestureRecognizerFactoryWithHandlers<_EagerPanRecognizer>(
                        _EagerPanRecognizer.new,
                        (recognizer) => recognizer
                          ..onStart = _onStart
                          ..onUpdate = _onUpdate
                          ..onEnd = ((_) => _onEnd())
                          ..onCancel = _onEnd,
                      ),
                },
                child: sheet,
              ),
            );
          },
        ),
      ],
    );
  }

  /// The sheet's height for [drawing]: at least [kDrawingMinHeight], grown
  /// in [_growStep]s to keep [_roomBelow] under the lowest stroke, and never
  /// less than it has already been.
  double _sheetHeightFor(Drawing drawing) {
    final needed = drawing.contentHeight + _roomBelow;
    var height = math.max(kDrawingMinHeight, _sheetHeight);
    while (height < needed) {
      height += _growStep;
    }
    _sheetHeight = height;
    return height;
  }

  Widget _toolTray(ColorScheme scheme) {
    final pen = _tool == _Tool.pen;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: toolbarTrayColor(scheme),
          borderRadius: kCardBorderRadius,
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(_trayInset),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final width in _penWidths)
                _ToolButton(
                  tooltip: 'Pen size ${_penWidths.indexOf(width) + 1}',
                  selected: pen && _width == width,
                  onPressed: () => setState(() {
                    _tool = _Tool.pen;
                    _width = width;
                  }),
                  child: _Dot(size: 4 + width / 2, color: _inkOf(scheme)),
                ),
              // The eraser sits with the pens, ahead of the colours, so it
              // stays in reach when a phone scrolls the tray.
              _divider(scheme),
              _ToolButton(
                tooltip: 'Eraser',
                selected: !pen,
                onPressed: () => setState(() => _tool = _Tool.eraser),
                child: Icon(
                  Icons.cleaning_services_outlined,
                  size: kCompactIconSize,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              _divider(scheme),
              _ToolButton(
                tooltip: 'Ink',
                selected: pen && _color == null,
                onPressed: () => setState(() {
                  _tool = _Tool.pen;
                  _color = null;
                }),
                child: _Dot(size: 18, color: scheme.onSurface),
              ),
              for (final color in _penColors)
                _ToolButton(
                  tooltip: 'Colour',
                  selected: pen && _color == color,
                  onPressed: () => setState(() {
                    _tool = _Tool.pen;
                    _color = color;
                  }),
                  child: _Dot(size: 18, color: Color(0xFF000000 | color)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Color _inkOf(ColorScheme scheme) =>
      _color == null ? scheme.onSurface : Color(0xFF000000 | _color!);

  Widget _divider(ColorScheme scheme) => Container(
    width: 1,
    height: _toolSize / 2,
    margin: const EdgeInsets.symmetric(horizontal: kSpaceXs),
    color: hairlineColor(scheme),
  );
}

/// A pan that claims the pointer the moment it lands, so drawing on the sheet
/// never scrolls the note underneath it.
class _EagerPanRecognizer extends PanGestureRecognizer {
  _EagerPanRecognizer() : super(supportedDevices: null);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }

  @override
  String get debugDescription => 'eager pan';
}

class _ToolButton extends StatelessWidget {
  final String tooltip;
  final bool selected;
  final VoidCallback onPressed;
  final Widget child;

  const _ToolButton({
    required this.tooltip,
    required this.selected,
    required this.onPressed,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        label: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: AnimatedContainer(
              duration: Motion.fast,
              curve: Motion.standard,
              width: _toolSize,
              height: _toolSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(kCardRadius - _trayInset),
                color: selected
                    ? scheme.primary.withValues(alpha: 0.14)
                    : Colors.transparent,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final double size;
  final Color color;

  const _Dot({required this.size, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
