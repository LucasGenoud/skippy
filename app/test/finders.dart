import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/widgets/app_icon_button.dart';

/// A button by what it says it does: a [Tooltip]'s message, or the label of
/// an [AppIconButton], which on a touch screen carries no tooltip widget.
Finder findAction(String label) => find.byWidgetPredicate(
  (widget) =>
      (widget is Tooltip && widget.message == label) ||
      (widget is AppIconButton && widget.tooltip == label),
  description: 'action "$label"',
);
