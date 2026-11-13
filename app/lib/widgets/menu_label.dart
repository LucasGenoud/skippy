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
      mainAxisSize: MainAxisSize.min,
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

/// One popup-menu row: a 20px icon, then its label. The same shape as an
/// anchored menu's [MenuItemButton], so every menu in the app reads alike.
/// A null [icon] keeps the slot, so labels line up beside rows that have one.
class MenuRow extends StatelessWidget {
  final IconData? icon;
  final String label;
  final String? hint;

  /// Tints icon and label, used to flag a destructive entry.
  final Color? color;

  const MenuRow({
    super.key,
    required this.icon,
    required this.label,
    this.hint,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: kCompactIconSize,
          child: icon == null
              ? null
              : Icon(
                  icon,
                  size: kCompactIconSize,
                  color:
                      color ?? Theme.of(context).colorScheme.onSurfaceVariant,
                ),
        ),
        const SizedBox(width: kSpaceMd),
        Flexible(child: MenuLabel(label, hint: hint, color: color)),
      ],
    );
  }
}
