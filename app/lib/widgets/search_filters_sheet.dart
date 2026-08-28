import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/notes_store.dart';
import '../theme.dart';
import '../util/motion.dart';
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
///
/// Every chip has three states, not two. "Notes with no link" is as ordinary a
/// question as "notes with a link", so each filter can also be excluded, and a
/// tap cycles off -> match -> exclude. The chip's own text is the token it
/// stands for and rewrites itself to the negative spelling (`hasnot:link`),
/// which is what teaches the operator: the sheet is the only place the query
/// language is ever spelled out.
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

  void _cycle(String token) {
    final next = cycleSearchFilter(controller.text, token);
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
              const ModalHeader(
                icon: Icons.tune,
                title: 'Search filters',
                subtitle:
                    'Tap to match, again to exclude, again to clear. Every '
                    'filter you pick narrows the search further, and typing '
                    'words narrows it more.',
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: modalBodyPadding(hasFooter: true),
                  children: [
                    if (labels.isNotEmpty)
                      _Group(
                        title: 'Labels',
                        tokens: [
                          for (final label in labels)
                            _quoted('label', label.name),
                        ],
                        query: query,
                        onCycle: _cycle,
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
                      onCycle: _cycle,
                    ),
                    _Group(
                      title: 'Contents',
                      tokens: const [
                        'has:reminder',
                        'has:attachment',
                        'has:image',
                        'has:audio',
                        'has:link',
                        'has:label',
                      ],
                      query: query,
                      onCycle: _cycle,
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
                      onCycle: _cycle,
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
                      onCycle: _cycle,
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: hairlineColor(scheme)),
              ModalFooter(
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

  /// Positive tokens only; the negative of each is derived, so a group never
  /// has to list a filter twice.
  final List<String> tokens;
  final String query;
  final ValueChanged<String> onCycle;

  const _Group({
    required this.title,
    required this.tokens,
    required this.query,
    required this.onCycle,
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
                _FilterCycleChip(
                  token: token,
                  query: query,
                  onCycle: () => onCycle(token),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What one chip is currently asking of the search.
enum _Cycle { off, matching, excluding }

/// A filter chip that cycles off -> match -> exclude on tap.
///
/// The exclusion is a peer of the match rather than a mode hidden behind a
/// long press or a second control: it costs no extra hit target, which is what
/// keeps the sheet usable one-thumbed on a phone.
class _FilterCycleChip extends StatelessWidget {
  /// The positive form, e.g. `has:link`.
  final String token;
  final String query;
  final VoidCallback onCycle;

  const _FilterCycleChip({
    required this.token,
    required this.query,
    required this.onCycle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final excluded = negateSearchFilter(token);
    final state = searchQueryHas(query, token)
        ? _Cycle.matching
        : searchQueryHas(query, excluded)
        ? _Cycle.excluding
        : _Cycle.off;
    final excluding = state == _Cycle.excluding;
    final shown = excluding ? excluded : token;

    // Exclusion gets its own wash rather than the selected one, so "with" and
    // "without" are told apart at a glance and not only by reading the three
    // letters in the middle of the token.
    final duration = Motion.reduced(context) ? Duration.zero : Motion.fast;
    final selectedColor = excluding
        ? excludedFilterColor(scheme)
        : scheme.secondaryContainer;

    return TweenAnimationBuilder<Color?>(
      // The fill has to move between the two containers, because a chip that
      // is already selected keeps its selection animation at rest and would
      // otherwise change colour in one frame.
      tween: ColorTween(end: selectedColor),
      duration: duration,
      curve: Motion.standard,
      builder: (context, fill, _) => FilterChip(
        label: AnimatedSize(
          duration: duration,
          curve: Motion.standard,
          alignment: Alignment.centerLeft,
          child: AnimatedSwitcher(
            duration: duration,
            switchInCurve: Motion.standard,
            switchOutCurve: Motion.standard,
            child: Text(
              shown,
              key: ValueKey(shown),
              // Read out as words: a screen reader saying "hasnot colon link"
              // explains nothing.
              semanticsLabel: excluding ? 'Excluding $token' : token,
            ),
          ),
        ),
        labelStyle: theme.textTheme.bodySmall,
        tooltip: switch (state) {
          _Cycle.off => 'Match $token',
          _Cycle.matching => 'Exclude instead',
          _Cycle.excluding => 'Clear',
        },
        visualDensity: VisualDensity.compact,
        selected: state != _Cycle.off,
        selectedColor: fill,
        showCheckmark: !excluding,
        avatar: excluding
            ? Icon(Icons.block, size: 16, color: scheme.error)
            : null,
        onSelected: (_) => onCycle(),
      ),
    );
  }
}
