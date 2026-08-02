import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/notes_store.dart';
import '../theme.dart';
import '../util/search_query.dart';
import 'form_dialog.dart';
import 'search_query_controller.dart';

/// What the sheet asked the search box to do once it closes. Filter toggling
/// is not in here: the sheet edits the query directly and stays open, so
/// several filters can be picked in one visit.
sealed class SearchFilterResult {
  const SearchFilterResult();
}

/// Save what is currently in the box as a smart view.
class SaveAsSmartView extends SearchFilterResult {
  const SaveAsSmartView();
}

/// The search box's cheat sheet: every operator, tapped on and off.
///
/// Operators are only useful if you know they exist, and a text field
/// advertises nothing. This is the discovery surface, so it lists the real
/// vocabulary rather than a curated sample, and doubles as the way into a
/// smart view.
///
/// It writes straight to the box's controller and does NOT close on a tap:
/// narrowing a search usually takes more than one filter, and a sheet that
/// dismissed itself each time would have to be reopened for every one of them.
class SearchFiltersSheet extends StatelessWidget {
  /// The live search box. Chips reflect it and toggle against it.
  final SearchQueryController controller;

  /// Tells the screen the query moved. A `TextField`'s own `onChanged` never
  /// fires for a programmatic edit, so without this the grid would not refilter.
  final ValueChanged<String> onChanged;

  const SearchFiltersSheet({
    super.key,
    required this.controller,
    required this.onChanged,
  });

  static Future<SearchFilterResult?> show(
    BuildContext context, {
    required SearchQueryController controller,
    required ValueChanged<String> onChanged,
  }) {
    final store = context.read<NotesStore>();
    return showAdaptiveSelectionSurface<SearchFilterResult>(
      context,
      isScrollControlled: true,
      builder: (_) => ChangeNotifierProvider.value(
        value: store,
        child: SearchFiltersSheet(controller: controller, onChanged: onChanged),
      ),
    );
  }

  void _toggle(String token) {
    final next = toggleSearchFilter(controller.text, token);
    controller.setQuery(next);
    onChanged(next);
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
      // Rebuilds on every edit, whether it came from a chip here or from the
      // field behind the sheet, so the selected chips are never stale.
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final query = controller.text;
          return Column(
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
                    'Tap to add or remove. Every filter you pick narrows the '
                    'search further, and typing words narrows it more.',
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
                          for (final label in labels)
                            _quoted('label', label.name),
                        ],
                        query: query,
                        onToggle: _toggle,
                      ),
                    _Group(
                      title: 'State',
                      tokens: const [
                        'is:pinned',
                        'is:archived',
                        'is:trashed',
                        'is:shared',
                        'is:open',
                        'is:done',
                      ],
                      query: query,
                      onToggle: _toggle,
                    ),
                    _Group(
                      title: 'Contents',
                      tokens: const [
                        'has:reminder',
                        'has:attachment',
                        'has:image',
                        'has:audio',
                        'has:link',
                        'label:none',
                      ],
                      query: query,
                      onToggle: _toggle,
                    ),
                    _Group(
                      title: 'Kind',
                      tokens: const [
                        'kind:text',
                        'kind:checklist',
                        'kind:markdown',
                        'kind:audio',
                      ],
                      query: query,
                      onToggle: _toggle,
                    ),
                    _Group(
                      title: 'Color',
                      tokens: const [
                        'color:red',
                        'color:yellow',
                        'color:green',
                        'color:blue',
                      ],
                      query: query,
                      onToggle: _toggle,
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
                      // On a phone the sheet covers the search box, so the
                      // query it is editing has to be visible from in here.
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
                          : () => Navigator.of(
                              context,
                            ).pop(const SaveAsSmartView()),
                      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                      label: const Text('Save as smart view'),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
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
  final String query;
  final ValueChanged<String> onToggle;

  const _Group({
    required this.title,
    required this.tokens,
    required this.query,
    required this.onToggle,
  });

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
                FilterChip(
                  label: Text(token),
                  labelStyle: theme.textTheme.bodySmall,
                  visualDensity: VisualDensity.compact,
                  selected: searchQueryHas(query, token),
                  onSelected: (_) => onToggle(token),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
