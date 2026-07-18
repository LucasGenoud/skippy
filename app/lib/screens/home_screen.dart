import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../widgets/home_fabs.dart';
import '../widgets/home_top_bar.dart';
import '../widgets/masonry.dart';
import '../widgets/note_card.dart';
import '../widgets/quick_add_bar.dart';
import '../widgets/shortcut_help.dart';
import '../widgets/skeleton.dart';
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
  bool _isSidebarOpen = true;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _scrollController = ScrollController();

  /// Holds focus whenever nothing else does: the Shortcuts above it only see
  /// key events while something in their subtree is focused, so without this
  /// node the bindings would go dead on a freshly loaded page.
  final _pageFocus = FocusNode(
    skipTraversal: true,
    debugLabel: 'home-shortcuts',
  );

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_reclaimFocus);
  }

  /// When focus falls back to the route's own scope — a dismissed editor
  /// dialog, a collapsed quick-add — nothing inside the page is focused any
  /// more, so pick focus back up to keep the keyboard shortcuts live. Scopes
  /// of other routes, or the drawer's, never match the home route's scope.
  void _reclaimFocus() {
    if (!mounted) return;
    if (FocusManager.instance.primaryFocus == FocusScope.of(context)) {
      _pageFocus.requestFocus();
    }
  }

  /// The state's own context sits above the Scaffold, so Scaffold.of()
  /// can't reach it — open the drawer through a key instead.
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  void _toggleSidebar() {
    if (MediaQuery.sizeOf(context).width < 600) {
      _scaffoldKey.currentState?.openDrawer();
    } else {
      setState(() => _isSidebarOpen = !_isSidebarOpen);
    }
  }

  // Semantic search: ranked ids from the server, refreshed as you type.
  bool _semantic = false;
  bool _semanticAvailable = true;
  List<String>? _semanticIds;
  bool _semanticBusy = false;
  Timer? _semanticDebounce;

  @override
  void dispose() {
    FocusManager.instance.removeListener(_reclaimFocus);
    _semanticDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _pageFocus.dispose();
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
      setState(() {
        _semanticIds = null;
        _semanticBusy = false;
      });
      return;
    }
    // Show the loading state right away (spinner in the bar, skeleton in the
    // body on a first search) rather than only once the debounce fires — the
    // user toggled/typed, so results are on their way.
    setState(() => _semanticBusy = true);
    _semanticDebounce = Timer(const Duration(milliseconds: 350), () async {
      final query = _query.trim();
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
        // Only the fetch for the query still in the box clears the loading
        // state — a superseded fetch finishing must not switch off the
        // spinner/skeleton while the newer search is still on its way.
        if (mounted && _query.trim() == query) {
          setState(() => _semanticBusy = false);
        }
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

  // Keyboard shortcut callbacks. The bindings live in build();
  // widgets/shortcut_help.dart and the README document the full set.
  void _newNote(NoteKind kind) => openNoteEditor(
    context,
    kind: kind,
    openFullscreen: () => Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => EditorScreen(kind: kind))),
  );

  void _focusSearch() => _searchFocus.requestFocus();

  void _clearSearch() {
    _searchController.clear();
    _onQueryChanged('');
    _pageFocus.requestFocus();
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
    final settings = context.watch<SettingsStore>();
    // Only offer semantic search when the server supports it and the user
    // hasn't turned it off.
    final semanticAvailable =
        _semanticAvailable && settings.semanticSearchAvailable;
    final searching = _query.trim().isNotEmpty;
    // Semantic mode replaces keyword filtering with the server's ranking.
    final semanticActive =
        _semantic &&
        semanticAvailable &&
        searching &&
        _selection.view == NoteView.notes;
    final sections = semanticActive && _semanticIds != null
        ? NoteSections(const [], [
            for (final id in _semanticIds!)
              if (store.noteById(id) case final Note note)
                if (!note.trashed && !note.archived) note,
          ])
        : store.notesFor(_selection, _query);
    // Loading indicator in the results area while the first semantic search
    // is in flight (no ranked results to show yet). On a refine the previous
    // results stay put and only the in-bar spinner signals the fetch, so the
    // grid doesn't flash a skeleton on every keystroke.
    final semanticLoading =
        semanticActive && _semanticBusy && _semanticIds == null;
    final dragEnabled =
        !searching &&
        store.sortMode == SortMode.custom &&
        (_selection.view == NoteView.notes ||
            _selection.view == NoteView.archive);

    // Keyboard shortcuts (web/desktop), Keep-style. Printable keys use
    // CharacterActivator so they match what the keystroke actually produced
    // on any layout ("/" is Shift+7 on Swiss keyboards), and _HomeAction
    // suppresses them while a text field has focus — the event then falls
    // through unhandled and the letter is typed instead of firing a shortcut.
    // Chords and Escape (whileTyping: true) stay live during typing; the
    // quick-add bar consumes its own Escape before it ever bubbles up here.
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        CharacterActivator('c'): _NewNoteIntent(NoteKind.text),
        CharacterActivator('n'): _NewNoteIntent(NoteKind.text),
        CharacterActivator('l'): _NewNoteIntent(NoteKind.checklist),
        CharacterActivator('m'): _NewNoteIntent(NoteKind.markdown),
        CharacterActivator('/'): _FocusSearchIntent(),
        CharacterActivator('?'): _ShortcutHelpIntent(),
        SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _FocusSearchIntent(whileTyping: true),
        SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _FocusSearchIntent(whileTyping: true),
        SingleActivator(LogicalKeyboardKey.keyG, control: true):
            _ToggleLayoutIntent(whileTyping: true),
        SingleActivator(LogicalKeyboardKey.keyG, meta: true):
            _ToggleLayoutIntent(whileTyping: true),
        SingleActivator(LogicalKeyboardKey.escape): _ClearSearchIntent(
          whileTyping: true,
        ),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _NewNoteIntent: _HomeAction<_NewNoteIntent>(
            onInvoke: (intent) => _newNote(intent.kind),
          ),
          _FocusSearchIntent: _HomeAction<_FocusSearchIntent>(
            onInvoke: (_) => _focusSearch(),
          ),
          _ClearSearchIntent: _HomeAction<_ClearSearchIntent>(
            onInvoke: (_) => _clearSearch(),
          ),
          _ToggleLayoutIntent: _HomeAction<_ToggleLayoutIntent>(
            onInvoke: (_) => setState(() => _listMode = !_listMode),
          ),
          _ShortcutHelpIntent: _HomeAction<_ShortcutHelpIntent>(
            onInvoke: (_) => showShortcutHelp(context),
          ),
        },
        child: Focus(
          focusNode: _pageFocus,
          autofocus: true,
          child: FileDropArea(
            hint: 'Drop files to create a note',
            onFiles: _createNoteFromDrop,
            child: GestureDetector(
              onTap: () => _pageFocus.requestFocus(),
              child: Scaffold(
                key: _scaffoldKey,
                drawer: AppDrawer(selection: _selection, onSelect: _selectView),
                // The note-creation FABs live inside the body (not the Scaffold's
                // floatingActionButton slot) so a floating SnackBar sits at the
                // bottom instead of floating above this tall FAB column. Still in
                // the body, so the drawer scrim covers them like a normal FAB.
                body: Column(
                  children: [
                    // Paint the status-bar/notch area in the bar's own surface
                    // color and keep its content below the top inset (a bare
                    // SafeArea would leave a scaffold-colored strip up there).
                    ColoredBox(
                      color: Theme.of(context).colorScheme.surface,
                      child: SafeArea(
                        bottom: false,
                        child: HomeTopBar(
                          controller: _searchController,
                          focusNode: _searchFocus,
                          listMode: _listMode,
                          semantic: _semantic,
                          semanticAvailable: semanticAvailable,
                          semanticBusy: _semanticBusy,
                          onQuery: _onQueryChanged,
                          onToggleSemantic: _toggleSemantic,
                          onToggleLayout: () =>
                              setState(() => _listMode = !_listMode),
                          onToggleSidebar: _toggleSidebar,
                        ),
                      ),
                    ),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    Expanded(
                      // Home-indicator and landscape-notch insets; the top one
                      // is already consumed by the bar above.
                      child: SafeArea(
                        top: false,
                        child: Row(
                          children: [
                            if (MediaQuery.sizeOf(context).width >= 600)
                              AppSidebar(
                                isOpen: _isSidebarOpen,
                                selection: _selection,
                                onSelect: _selectView,
                              ),
                            Expanded(
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: LayoutBuilder(
                                      builder: (context, constraints) {
                                        final width = constraints.maxWidth;
                                        final horizontalPad = width >= 900
                                            ? 32.0
                                            : 16.0;
                                        final contentWidth =
                                            width - horizontalPad * 2;
                                        final gridMaxWidth = _listMode
                                            ? 600.0
                                            : 1400.0;
                                        final effectiveWidth =
                                            contentWidth > gridMaxWidth
                                            ? gridMaxWidth
                                            : contentWidth;
                                        final columns = _listMode
                                            ? 1
                                            : (effectiveWidth / 250)
                                                  .floor()
                                                  .clamp(2, 5);

                                        return RefreshIndicator(
                                          onRefresh: store.load,
                                          edgeOffset: 16,
                                          child: CustomScrollView(
                                            controller: _scrollController,
                                            physics:
                                                const AlwaysScrollableScrollPhysics(),
                                            slivers: [
                                              const SliverToBoxAdapter(
                                                child: SizedBox(height: 16),
                                              ),
                                              if (store.offline)
                                                SliverToBoxAdapter(
                                                  child: _OfflineBanner(
                                                    onRetry: store.retryNow,
                                                  ),
                                                ),
                                              // Keep-style quick add: wide screens, main notes view only.
                                              if (_selection ==
                                                      ViewSelection.notes &&
                                                  !searching &&
                                                  width >= 600)
                                                SliverToBoxAdapter(
                                                  child: Center(
                                                    child: ConstrainedBox(
                                                      constraints:
                                                          const BoxConstraints(
                                                            maxWidth: 600,
                                                          ),
                                                      child: const Padding(
                                                        padding:
                                                            EdgeInsets.fromLTRB(
                                                              16,
                                                              4,
                                                              16,
                                                              24,
                                                            ),
                                                        child: QuickAddBar(),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              if (_viewTitle(store).isNotEmpty)
                                                SliverToBoxAdapter(
                                                  child: _ViewHeader(
                                                    title: _viewTitle(store),
                                                    isTrash:
                                                        _selection.view ==
                                                        NoteView.trash,
                                                    hasTrashedNotes: sections
                                                        .others
                                                        .isNotEmpty,
                                                    onEmptyTrash: () =>
                                                        _confirmEmptyTrash(
                                                          store,
                                                        ),
                                                  ),
                                                ),
                                              if (store.loading ||
                                                  semanticLoading)
                                                SliverToBoxAdapter(
                                                  child: Center(
                                                    child: ConstrainedBox(
                                                      constraints:
                                                          BoxConstraints(
                                                            maxWidth:
                                                                gridMaxWidth,
                                                          ),
                                                      child: Padding(
                                                        padding:
                                                            EdgeInsets.fromLTRB(
                                                              horizontalPad,
                                                              8,
                                                              horizontalPad,
                                                              0,
                                                            ),
                                                        child: NotesSkeleton(
                                                          columns: columns,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                )
                                              else if (sections.isEmpty)
                                                SliverFillRemaining(
                                                  hasScrollBody: false,
                                                  child: EmptyState(
                                                    icon: searching
                                                        ? Icons.search_off
                                                        : _emptyIcon,
                                                    message: searching
                                                        ? 'No matching notes'
                                                        : _emptyMessage,
                                                  ),
                                                )
                                              else ...[
                                                if (sections
                                                    .pinned
                                                    .isNotEmpty) ...[
                                                  _sectionLabel(
                                                    context,
                                                    'Pinned',
                                                    horizontalPad,
                                                  ),
                                                  _grid(
                                                    store,
                                                    sections.pinned,
                                                    columns,
                                                    horizontalPad,
                                                    gridMaxWidth,
                                                    dragEnabled,
                                                    section: 'pinned',
                                                  ),
                                                  if (sections
                                                      .others
                                                      .isNotEmpty)
                                                    _sectionLabel(
                                                      context,
                                                      'Others',
                                                      horizontalPad,
                                                    ),
                                                ],
                                                _grid(
                                                  store,
                                                  sections.others,
                                                  columns,
                                                  horizontalPad,
                                                  gridMaxWidth,
                                                  dragEnabled,
                                                  section: 'others',
                                                ),
                                                const SliverToBoxAdapter(
                                                  child: SizedBox(height: 200),
                                                ),
                                              ],
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  const Positioned(
                                    right: 16,
                                    bottom: 16,
                                    child: NewNoteFabs(),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
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
    bool dragEnabled, {
    required String section,
  }) {
    final query = _query.trim();
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      sliver: SliverToBoxAdapter(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: AnimatedMasonry(
              // Re-key per view so switching Notes/Archive/Trash/label replays
              // the staggered entrance.
              key: ValueKey(
                '$section-${_selection.view}-${_selection.labelId}',
              ),
              notes: notes,
              columns: columns,
              spacing: 8,
              dragEnabled: dragEnabled,
              scrollController: _scrollController,
              onReorder: store.reorder,
              itemBuilder: (context, note) =>
                  NoteTile(key: ValueKey(note.id), note: note, query: query),
            ),
          ),
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

// ---------------------------------------------------------------------------
// Keyboard shortcut intents. `whileTyping` marks bindings that may also fire
// while a text field has focus (modifier chords, Escape); printable keys
// leave it false so their action stays disabled during typing and the
// keystroke falls through to the field.

abstract class _HomeIntent extends Intent {
  const _HomeIntent({this.whileTyping = false});

  final bool whileTyping;
}

class _NewNoteIntent extends _HomeIntent {
  const _NewNoteIntent(this.kind);

  final NoteKind kind;
}

class _FocusSearchIntent extends _HomeIntent {
  const _FocusSearchIntent({super.whileTyping});
}

class _ClearSearchIntent extends _HomeIntent {
  const _ClearSearchIntent({super.whileTyping});
}

class _ToggleLayoutIntent extends _HomeIntent {
  const _ToggleLayoutIntent({super.whileTyping});
}

class _ShortcutHelpIntent extends _HomeIntent {
  const _ShortcutHelpIntent();
}

/// Runs a home-screen shortcut unless the binding defers to an active text
/// field. A disabled action leaves the key event unhandled, which is what
/// lets the character reach the field instead of being swallowed.
class _HomeAction<T extends _HomeIntent> extends CallbackAction<T> {
  _HomeAction({required super.onInvoke});

  @override
  bool isEnabled(T intent) => intent.whileTyping || !_editingText;

  static bool get _editingText =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>() !=
      null;
}
