import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Reports the child's laid-out size, so parents can position children by
/// their real measured heights (used by the masonry grid and the animated
/// checklist).
class MeasureSize extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onChange;
  const MeasureSize({super.key, required this.onChange, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderMeasureSize(onChange);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderMeasureSize renderObject,
  ) {
    renderObject.onChange = onChange;
  }
}

class RenderMeasureSize extends RenderProxyBox {
  ValueChanged<Size> onChange;
  Size? _reported;

  RenderMeasureSize(this.onChange);

  @override
  void performLayout() {
    super.performLayout();
    if (_reported != size) {
      _reported = size;
      final reported = size;
      WidgetsBinding.instance.addPostFrameCallback((_) => onChange(reported));
    }
  }
}
