import 'dart:async';

import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/dropped_file.dart';
import '../models/note.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/mime.dart';
import '../util/snack.dart';
import '../widgets/app_drawer.dart';
import '../widgets/empty_state.dart';
import '../widgets/file_drop.dart';
import '../widgets/masonry.dart';
import '../widgets/note_card.dart';
import '../widgets/quick_add_bar.dart';
import 'editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ViewSelection _selection = ViewSelection.notes;
  String _query = '';
  late bool _listMode = context.read<SettingsStore>().defaultListMode;
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  // Semantic search: ranked ids from the server, refreshed as you type.
  bool _semantic = false;
  bool _semanticAvailable = true;
  List<String>? _semanticIds;
  bool _semanticBusy = false;
  Timer? _semanticDebounce;

  @override
  void dispose() {
    _semanticDebounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String q) {
    setState(() => _query = q);
    _scheduleSemantic();
  }

  void _toggleSemantic() {
    setState(() => _semantic = !_semantic);
    _scheduleSemantic();
  }

  void _scheduleSemantic() {
    _semanticDebounce?.cancel();
    if (!_semantic || _query.trim().isEmpty) {
      setState(() => _semanticIds = null);
      return;
    }
    _semanticDebounce = Timer(const Duration(milliseconds: 350), () async {
      final query = _query.trim();
      setState(() => _semanticBusy = true);
      try {
        final notes = await context.read<NotesStore>().semanticSearch(query);
        if (!mounted || _query.trim() != query) return;
        setState(() => _semanticIds = [for (final n in notes) n.id]);
      } on ApiException catch (e) {
        if (!mounted) return;
        if (e.statusCode == 503) {
          setState(() {
            _semanticAvailable = false;
            _semantic = false;
            _semanticIds = null;
          });
          showAppSnack('Semantic search is not enabled on this server');
        }
      } catch (_) {
        // Network hiccup: keep whatever results we had.
      } finally {
        if (mounted) setState(() => _semanticBusy = false);
      }
    });
  }

  void _selectView(ViewSelection selection) {
    setState(() {
      _selection = selection;
      _query = '';
      _searchController.clear();
    });
  }

  String _viewTitle(NotesStore store) => switch (_selection.view) {
    NoteView.notes => '',
    NoteView.reminders => 'Reminders',
    NoteView.archive => 'Archive',
    NoteView.trash => 'Trash',
    NoteView.label => store.labelById(_selection.labelId!)?.name ?? '',
  };

  /// Files dropped anywhere on the grid become one new note (web only).
  Future<void> _createNoteFromDrop(List<DroppedFile> files) async {
    final store = context.read<NotesStore>();
    final accepted = [
      for (final f in files)
        if (f.bytes.length <= maxUploadBytes) f,
    ];
    if (accepted.length != files.length) {
      showAppSnack('Files are limited to 25 MB');
    }
    if (accepted.isEmpty) return;
    final id = await store.createNoteWithFiles(accepted);
    if (id == null) {
      showAppSnack("Couldn't upload the dropped files");
    } else if (_selection != ViewSelection.notes) {
      showAppSnack('Note created in Notes');
    }
  }

  void _confirmEmptyTrash(NotesStore store) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Empty trash?'),
        content: const Text('All notes in Trash will be permanently deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Empty trash'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      store.emptyTrash();
      showAppSnack('Trash emptied');
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final searching = _query.trim().isNotEmpty;
    // Semantic mode replaces keyword filtering with the server's ranking.
    final semanticActive =
        _semantic && searching && _selection.view == NoteView.notes;
    final sections = semanticActive && _semanticIds != null
        ? NoteSections(const [], [
            for (final id in _semanticIds!)
              if (store.noteById(id) case final Note note)
                if (!note.trashed && !note.archived) note,
          ])
        : store.notesFor(_selection, _query);
    final dragEnabled =
        !searching &&
        store.sortMode == SortMode.custom &&
        (_selection.view == NoteView.notes ||
            _selection.view == NoteView.archive);

    return FileDropArea(
      hint: 'Drop files to create a note',
      onFiles: _createNoteFromDrop,
      child: Scaffold(
        drawer: AppDrawer(selection: _selection, onSelect: _selectView),
        floatingActionButton: const _NewNoteFabs(),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final horizontalPad = width >= 900 ? 32.0 : 16.0;
            final contentWidth = width - horizontalPad * 2;
            final gridMaxWidth = _listMode ? 600.0 : 1400.0;
            final effectiveWidth = contentWidth > gridMaxWidth
                ? gridMaxWidth
                : contentWidth;
            final columns = _listMode
                ? 1
                : (effectiveWidth / 250).floor().clamp(2, 5);

            return RefreshIndicator(
              onRefresh: store.load,
              edgeOffset: 80,
              child: CustomScrollView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverAppBar(
                    floating: true,
                    snap: true,
                    toolbarHeight: 72,
                    automaticallyImplyLeading: false,
                    titleSpacing: horizontalPad,
                    title: _SearchBar(
                      controller: _searchController,
                      listMode: _listMode,
                      semantic: _semantic,
                      semanticAvailable: _semanticAvailable,
                      semanticBusy: _semanticBusy,
                      onQuery: _onQueryChanged,
                      onToggleSemantic: _toggleSemantic,
                      onToggleLayout: () =>
                          setState(() => _listMode = !_listMode),
                    ),
                  ),
                  if (store.offline)
                    SliverToBoxAdapter(
                      child: _OfflineBanner(onRetry: store.retryNow),
                    ),
                  // Keep-style quick add: wide screens, main notes view only.
                  if (_selection == ViewSelection.notes &&
                      !searching &&
                      width >= 600)
                    SliverToBoxAdapter(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 600),
                          child: const Padding(
                            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: QuickAddBar(),
                          ),
                        ),
                      ),
                    ),
                  if (_viewTitle(store).isNotEmpty)
                    SliverToBoxAdapter(
                      child: _ViewHeader(
                        title: _viewTitle(store),
                        isTrash: _selection.view == NoteView.trash,
                        hasTrashedNotes: sections.others.isNotEmpty,
                        onEmptyTrash: () => _confirmEmptyTrash(store),
                      ),
                    ),
                  if (store.loading)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (sections.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: EmptyState(
                        icon: searching ? Icons.search_off : _emptyIcon,
                        message: searching
                            ? 'No matching notes'
                            : _emptyMessage,
                      ),
                    )
                  else ...[
                    if (sections.pinned.isNotEmpty) ...[
                      _sectionLabel(context, 'Pinned', horizontalPad),
                      _grid(
                        store,
                        sections.pinned,
                        columns,
                        horizontalPad,
                        gridMaxWidth,
                        dragEnabled,
                      ),
                      if (sections.others.isNotEmpty)
                        _sectionLabel(context, 'Others', horizontalPad),
                    ],
                    _grid(
                      store,
                      sections.others,
                      columns,
                      horizontalPad,
                      gridMaxWidth,
                      dragEnabled,
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 120)),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  IconData get _emptyIcon => switch (_selection.view) {
    NoteView.notes => Icons.lightbulb_outline,
    NoteView.reminders => Icons.notifications_outlined,
    NoteView.archive => Icons.archive_outlined,
    NoteView.trash => Icons.delete_outline,
    NoteView.label => Icons.label_outline,
  };

  String get _emptyMessage => switch (_selection.view) {
    NoteView.notes => 'Notes you add appear here',
    NoteView.reminders => 'Notes with reminders appear here',
    NoteView.archive => 'Your archived notes appear here',
    NoteView.trash => 'No notes in Trash',
    NoteView.label => 'No notes with this label yet',
  };

  Widget _sectionLabel(BuildContext context, String text, double pad) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(pad + 8, 12, pad, 8),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            letterSpacing: 1.2,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _grid(
    NotesStore store,
    List<Note> notes,
    int columns,
    double pad,
    double maxWidth,
    bool dragEnabled,
  ) {
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      sliver: SliverToBoxAdapter(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: AnimatedMasonry(
              notes: notes,
              columns: columns,
              spacing: 8,
              dragEnabled: dragEnabled,
              scrollController: _scrollController,
              onReorder: store.reorder,
              itemBuilder: (context, note) =>
                  NoteTile(key: ValueKey(note.id), note: note),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final bool listMode;
  final bool semantic;
  final bool semanticAvailable;
  final bool semanticBusy;
  final ValueChanged<String> onQuery;
  final VoidCallback onToggleSemantic;
  final VoidCallback onToggleLayout;

  const _SearchBar({
    required this.controller,
    required this.listMode,
    required this.semantic,
    required this.semanticAvailable,
    required this.semanticBusy,
    required this.onQuery,
    required this.onToggleSemantic,
    required this.onToggleLayout,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isNarrow = MediaQuery.sizeOf(context).width < 480;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(28),
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.menu),
              tooltip: 'Menu',
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: onQuery,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Search your notes',
                  border: InputBorder.none,
                  isCollapsed: true,
                ),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) => value.text.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Clear search',
                      onPressed: () {
                        controller.clear();
                        onQuery('');
                      },
                    ),
            ),
            if (semanticAvailable)
              semanticBusy
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 14),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      icon: Icon(
                        Icons.auto_awesome,
                        color: semantic
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      tooltip: semantic
                          ? 'Semantic search on — results ranked by meaning'
                          : 'Search by meaning',
                      onPressed: onToggleSemantic,
                    ),
            const _SortButton(),
            IconButton(
              icon: Icon(
                listMode
                    ? Icons.grid_view_outlined
                    : Icons.view_agenda_outlined,
              ),
              tooltip: listMode ? 'Grid view' : 'List view',
              onPressed: onToggleLayout,
            ),
            if (!isNarrow)
              IconButton(
                icon: Icon(
                  Theme.of(context).brightness == Brightness.light
                      ? Icons.dark_mode_outlined
                      : Icons.light_mode_outlined,
                ),
                tooltip: Theme.of(context).brightness == Brightness.light
                    ? 'Dark theme'
                    : 'Light theme',
                onPressed: () => context.read<SettingsStore>().toggleTheme(
                  Theme.of(context).brightness,
                ),
              ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

class _ViewHeader extends StatelessWidget {
  final String title;
  final bool isTrash;
  final bool hasTrashedNotes;
  final VoidCallback onEmptyTrash;

  const _ViewHeader({
    required this.title,
    required this.isTrash,
    required this.hasTrashedNotes,
    required this.onEmptyTrash,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              if (isTrash && hasTrashedNotes)
                TextButton.icon(
                  onPressed: onEmptyTrash,
                  icon: const Icon(Icons.delete_forever_outlined, size: 20),
                  label: const Text('Empty trash'),
                ),
            ],
          ),
          if (isTrash)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Notes in Trash are deleted after 7 days',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  final VoidCallback onRetry;
  const _OfflineBanner({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              "Can't reach the server — changes will sync automatically",
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// Sort control: Keep's "Sort by" options. Anything but custom order
/// disables drag-to-reorder (positions stay untouched).
class _SortButton extends StatelessWidget {
  const _SortButton();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    return PopupMenuButton<SortMode>(
      icon: const Icon(Icons.swap_vert),
      tooltip: 'Sort by',
      initialValue: store.sortMode,
      onSelected: store.setSortMode,
      itemBuilder: (context) => [
        for (final (mode, label) in [
          (SortMode.custom, 'Custom order'),
          (SortMode.edited, 'Recently edited'),
          (SortMode.newest, 'Recently added'),
          (SortMode.oldest, 'Oldest first'),
        ])
          CheckedPopupMenuItem(
            value: mode,
            checked: store.sortMode == mode,
            child: Text(label),
          ),
      ],
    );
  }
}

/// FABs that morph into the editor via container transform: a mini one for a
/// new checklist, the main one for a new text note.
class _NewNoteFabs extends StatelessWidget {
  const _NewNoteFabs();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget fab({
      required double size,
      required IconData icon,
      required Color color,
      required Color onColor,
      required NoteKind kind,
      required String tooltip,
    }) {
      return Tooltip(
        message: tooltip,
        child: OpenContainer<void>(
          transitionDuration: const Duration(milliseconds: 320),
          transitionType: ContainerTransitionType.fade,
          closedElevation: 4,
          closedColor: color,
          middleColor: scheme.surface,
          openColor: scheme.surface,
          closedShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(size >= 56 ? 16 : 12),
          ),
          closedBuilder: (context, open) => SizedBox(
            width: size,
            height: size,
            child: Icon(icon, size: size / 2, color: onColor),
          ),
          openBuilder: (context, close) =>
              EditorScreen(noteId: null, kind: kind),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        fab(
          size: 44,
          icon: Icons.article_outlined,
          color: scheme.surfaceContainerHigh,
          onColor: scheme.onSurfaceVariant,
          kind: NoteKind.markdown,
          tooltip: 'New markdown note',
        ),
        const SizedBox(height: 12),
        fab(
          size: 44,
          icon: Icons.check_box_outlined,
          color: scheme.surfaceContainerHigh,
          onColor: scheme.onSurfaceVariant,
          kind: NoteKind.checklist,
          tooltip: 'New checklist',
        ),
        const SizedBox(height: 12),
        fab(
          size: 56,
          icon: Icons.add,
          color: scheme.primaryContainer,
          onColor: scheme.onPrimaryContainer,
          kind: NoteKind.text,
          tooltip: 'New note',
        ),
      ],
    );
  }
}
