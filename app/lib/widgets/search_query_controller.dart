import 'package:flutter/material.dart';

import '../util/search_query.dart';

/// The search box's controller, which paints a tinted background behind the
/// `label:`/`is:` operators in the text.
///
/// A query mixes two different things: words to look for and filters that
/// narrow the set. Without the tint they read as one undifferentiated string,
/// and it is not obvious that `is:pinned` did anything at all. Styling happens
/// in [buildTextSpan] on the real editing controller (the same approach as
/// `LinkifyingController` in the editor), so the field stays fully editable:
/// the caret, selection, and autocorrect all behave normally, which a
/// read-only overlay of chips would break.
class SearchQueryController extends TextEditingController {
  SearchQueryController({super.text});

  /// Replace the whole query, keeping the caret at the end.
  ///
  /// Used by the filter sheet, which edits the query while the field itself is
  /// not focused. Notifies listeners like any other programmatic edit; callers
  /// that need the search to re-run must still tell the screen, since a
  /// `TextField`'s `onChanged` only fires for typing.
  void setQuery(String next) {
    value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final tokens = tokenizeSearchQuery(text);
    final filters = tokens.where((t) => t.isFilter).toList();
    if (filters.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final base = style ?? const TextStyle();
    final filterStyle = base.copyWith(
      backgroundColor: scheme.secondaryContainer,
      color: scheme.onSecondaryContainer,
      fontWeight: FontWeight.w500,
    );

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final token in filters) {
      if (token.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, token.start)));
      }
      spans.add(TextSpan(text: token.raw, style: filterStyle));
      cursor = token.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return TextSpan(style: base, children: spans);
  }
}
