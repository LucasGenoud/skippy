import 'package:flutter/material.dart';

import '../theme.dart';

/// A menu entry's text: what it is, and a few grey words on what it does,
/// on one line. The hint gives way first when the menu is narrow.
///
///   Duplicate  Make a copy
///   Delete     Move to trash
class MenuLabel extends StatelessWidget {
  final String label;
  final String? hint;

  /// Tints the label, used to flag a destructive entry.
  final Color? color;

  const MenuLabel(this.label, {super.key, this.hint, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = this.hint;
    return Row(
      children: [
        Flexible(
          // Short of room, the label keeps the larger share.
          flex: hint == null ? 1 : 3,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: color == null ? null : TextStyle(color: color),
          ),
        ),
        if (hint != null) ...[
          const SizedBox(width: kSpaceSm),
          Flexible(
            flex: 2,
            child: Text(
              hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
