import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Moves the modal editor between two sizes, floating and full window, by
/// laying it out at every size in between.
///
/// The target is measured by laying the child out with the box's own
/// constraints; while [progress] runs from 0 to 1 the child is then laid out
/// again, tight, at the size between where the box was when [expanded]
/// flipped and that target:
///
/// ```text
///   flip      from = size on screen
///   frame     target = child.layout(constraints)
///             size   = lerp(from, target, progress)
///             child.layout(tight(size))
/// ```
///
/// Two layouts a frame, but only for the length of a toggle. At rest the box
/// is its child's size, so the floating editor still follows the note as it
/// grows. An [AnimatedSize] cannot shrink here: the smaller constraints
/// arrive in the same frame as the toggle and clamp it at once.
class EditorResizeBox extends SingleChildRenderObjectWidget {
  final bool expanded;

  /// 0 when [expanded] has just flipped, 1 at rest. Already eased.
  final double progress;

  const EditorResizeBox({
    super.key,
    required this.expanded,
    required this.progress,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderEditorResize(expanded: expanded, progress: progress);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderEditorResize)
      ..expanded = expanded
      ..progress = progress;
  }
}

class _RenderEditorResize extends RenderProxyBox {
  _RenderEditorResize({required this._expanded, required this._progress});

  bool _expanded;
  set expanded(bool value) {
    if (value == _expanded) {
      return;
    }
    _expanded = value;
    // Start from what is on screen, mid-toggle included, so a second
    // toggle turns around instead of jumping.
    _from = hasSize ? size : null;
    markNeedsLayout();
  }

  double _progress;
  set progress(double value) {
    if (value == _progress) {
      return;
    }
    _progress = value;
    markNeedsLayout();
  }

  /// Size when [expanded] last flipped; null once the box has settled.
  Size? _from;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }

    child.layout(constraints, parentUsesSize: true);
    final from = _from;
    if (from == null || _progress >= 1) {
      _from = null;
      size = child.size;
      return;
    }

    size = constraints.constrain(Size.lerp(from, child.size, _progress)!);
    child.layout(BoxConstraints.tight(size), parentUsesSize: true);
  }
}
