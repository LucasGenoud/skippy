import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/notes_store.dart';
import '../theme.dart';
import 'form_dialog.dart';

/// What the sheet asked the search box to do.
sealed class SearchFilterResult {
  const SearchFilterResult();
}

/// Append this token to the query.
class InsertFilter extends SearchFilterResult {
  final String token;
  const InsertFilter(this.token);
}

/// Save what is currently in the box as a smart view.
class SaveAsSmartView extends SearchFilterResult {
  const SaveAsSmartView();
}

/// The search box's cheat sheet: every operator, one tap to insert.
///
/// Operators are only useful if you know they exist, and a text field advertises
/// nothing. This is the discovery surface, so it lists the real vocabulary
/// rather than a curated sample, and doubles as the way into a smart view.
class SearchFiltersSheet extends StatelessWidget {
  /// What the box holds right now; an empty one has nothing to save.
  final String query;

  const SearchFiltersSheet({super.key, required this.query});

  static Future<SearchFilterResult?> show(
    BuildContext context, {
    required String query,
  }) {
    final store = context.read<NotesStore>();
    return showAdaptiveSelectionSurface<SearchFilterResult>(
      context,
      isScrollControlled: true,
      builder: (_) => ChangeNotifierProvider.value(
        value: store,
        child: SearchFiltersSheet(query: query),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Only labels of the open workspace: a `label:` chip for a name that isn't
    // in this workspace would insert a filter that matches nothing.
    final labels = context.watch<NotesStore>().labels;

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
            child: Row(
              children: [
                Icon(Icons.tune, color: scheme.onSurfaceVariant, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Search filters',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Combine them with words to narrow a search. '
                'Put a minus in front to exclude, as in -is:pinned.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              children: [
                if (labels.isNotEmpty)
                  _Group(
                    title: 'Labels',
                    tokens: [
                      for (final label in labels) _quoted('label', label.name),
                    ],
                  ),
                const _Group(
                  title: 'State',
                  tokens: [
                    'is:pinned',
                    'is:archived',
                    'is:trashed',
                    'is:shared',
                    'is:open',
                    'is:done',
                  ],
                ),
                const _Group(
                  title: 'Contents',
                  tokens: [
                    'has:reminder',
                    'has:attachment',
                    'has:image',
                    'has:audio',
                    'has:link',
                    'label:none',
                  ],
                ),
                const _Group(
                  title: 'Kind',
                  tokens: [
                    'kind:text',
                    'kind:checklist',
                    'kind:markdown',
                    'kind:audio',
                  ],
                ),
                const _Group(
                  title: 'Color',
                  tokens: [
                    'color:red',
                    'color:yellow',
                    'color:green',
                    'color:blue',
                  ],
                ),
              ],
            ),
          ),
          Divider(height: 1, color: hairlineColor(scheme)),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    query.trim().isEmpty
                        ? 'Build a search to save it as a smart view'
                        : query.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFamily: query.trim().isEmpty ? null : 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: query.trim().isEmpty
                      ? null
                      : () =>
                            Navigator.of(context).pop(const SaveAsSmartView()),
                  icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                  label: const Text('Save as smart view'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// `label:name`, quoted when the name has a space in it, which is exactly
  /// what the parser needs to keep it as one value.
  static String _quoted(String field, String value) =>
      value.contains(' ') ? '$field:"$value"' : '$field:$value';
}

class _Group extends StatelessWidget {
  final String title;
  final List<String> tokens;

  const _Group({required this.title, required this.tokens});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 1.1,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final token in tokens)
                ActionChip(
                  label: Text(token),
                  labelStyle: theme.textTheme.bodySmall,
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      Navigator.of(context).pop(InsertFilter(token)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
