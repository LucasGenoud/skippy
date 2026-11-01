import 'package:flutter/material.dart';

import '../../theme.dart';

/// The drawn checkbox of a checklist row that is shown rather than edited:
/// the card preview, version history, a public share. It matches the
/// editor's [Checkbox] through the theme's `checkboxTheme`: an outlined
/// rounded square that fills with the accent once checked.
class CheckMark extends StatelessWidget {
  final bool checked;
  final double size;

  const CheckMark({super.key, required this.checked, this.size = 18});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: checked ? scheme.primaryContainer : null,
        borderRadius: kCheckBorderRadius,
        border: Border.all(
          color: checked ? scheme.primaryContainer : scheme.onSurfaceVariant,
          width: 1.5,
        ),
      ),
      child: checked
          ? Icon(
              Icons.check_rounded,
              size: size - 4,
              color: scheme.onPrimaryContainer,
            )
          : null,
    );
  }
}
