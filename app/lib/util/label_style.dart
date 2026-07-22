import 'package:flutter/material.dart';

import '../models/note.dart';
import '../state/settings_store.dart';

/// Presentation for labels: a curated icon set and colour resolution.
///
/// Labels carry an optional colour (hex) and an optional [icon] key. The key
/// indexes [kLabelIcons] — a *fixed, curated* set rather than the full Material
/// catalogue, so the values stay `const` and Flutter's icon tree-shaking keeps
/// working (a searchable full-catalogue picker would defeat it and bloat the
/// web bundle). An unset or unknown key falls back to the default label glyph.

/// The default glyph shown when a label has no custom icon — the same one the
/// app used before labels gained icons.
const IconData kDefaultLabelIcon = Icons.label_outline;

/// Curated icon set, keyed by a stable string persisted with the label. Add
/// entries here to grow the picker; never rename a key (it would orphan labels
/// that reference it — they'd just fall back to the default).
const Map<String, IconData> kLabelIcons = {
  'star': Icons.star_outline,
  'flag': Icons.flag_outlined,
  'favorite': Icons.favorite_outline,
  'bookmark': Icons.bookmark_outline,
  'work': Icons.work_outline,
  'home': Icons.home_outlined,
  'person': Icons.person_outline,
  'group': Icons.group_outlined,
  'school': Icons.school_outlined,
  'shopping': Icons.shopping_cart_outlined,
  'restaurant': Icons.restaurant_outlined,
  'travel': Icons.flight_outlined,
  'fitness': Icons.fitness_center_outlined,
  'health': Icons.favorite_border,
  'money': Icons.attach_money_outlined,
  'idea': Icons.lightbulb_outline,
  'code': Icons.code_outlined,
  'bug': Icons.bug_report_outlined,
  'book': Icons.menu_book_outlined,
  'music': Icons.music_note_outlined,
  'movie': Icons.movie_outlined,
  'photo': Icons.photo_camera_outlined,
  'game': Icons.sports_esports_outlined,
  'pets': Icons.pets_outlined,
  'nature': Icons.eco_outlined,
  'gift': Icons.card_giftcard_outlined,
  'event': Icons.event_outlined,
  'call': Icons.call_outlined,
  'mail': Icons.mail_outline,
  'priority': Icons.priority_high_outlined,
  'bolt': Icons.bolt_outlined,
};

/// The [IconData] for a label's [icon] key, defaulting to [kDefaultLabelIcon].
IconData labelIconFor(String? key) =>
    key == null ? kDefaultLabelIcon : (kLabelIcons[key] ?? kDefaultLabelIcon);

/// The [IconData] for a whole [Label].
IconData labelIcon(Label label) => labelIconFor(label.icon);

/// A label's resolved colour, or [fallback] (typically `onSurfaceVariant`) when
/// it has no custom colour or the stored hex is malformed.
Color labelColor(Label label, Color fallback) =>
    PaletteEntry.hexToColor(label.color) ?? fallback;
