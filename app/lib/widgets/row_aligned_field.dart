import 'package:flutter/material.dart';

/// Where a [ListTile]'s title starts, measured from its leading edge, after a
/// 24px icon and the default gap.
const double kRowTitleInset = 40;

/// The gap Material 3 leaves between a field's prefix icon and its text
/// (`prefixToInputGap` in Flutter's input decorator).
const double _prefixToTextGap = 4;

/// The gap an avatar of [radius] needs so the title after it starts at
/// [kRowTitleInset], like a row led by an icon.
double avatarTitleGap(double radius) => kRowTitleInset - radius * 2;

/// A text field's decoration for a field set among list rows: its [icon] on
/// the rows' icon column and its text on their title column. [indent] is how
/// far in the rows' content starts from the field's edge.
InputDecoration rowAlignedFieldDecoration({
  required String hint,
  required IconData icon,
  double indent = 0,
}) {
  // A row's icon is 24px wide; this one is smaller, so centre it on that.
  const iconSize = 20.0;
  const rowIconSize = 24.0;
  return InputDecoration(
    hintText: hint,
    isDense: true,
    prefixIconConstraints: BoxConstraints.tightFor(
      width: indent + kRowTitleInset - _prefixToTextGap,
    ),
    prefixIcon: Padding(
      padding: EdgeInsetsDirectional.only(
        start: indent + (rowIconSize - iconSize) / 2,
      ),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Icon(icon, size: iconSize),
      ),
    ),
  );
}
