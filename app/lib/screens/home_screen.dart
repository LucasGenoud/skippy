import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/dropped_file.dart';
import '../models/note.dart';
import '../models/saved_view.dart';
import '../models/share_link.dart';
import '../state/note_collection.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../theme.dart';
import '../util/motion.dart';
import '../util/platform.dart';
import '../util/search_query.dart';
import '../util/snack.dart';
import '../widgets/app_drawer.dart';
import '../widgets/board/board_view.dart';
import '../widgets/board/move_to_stage_sheet.dart';
import '../widgets/collection_settings.dart';
import '../widgets/color_picker.dart';
import '../widgets/empty_state.dart';
import '../widgets/file_drop.dart';
import '../widgets/form_dialog.dart';
import '../widgets/home_fabs.dart';
import '../widgets/home_top_bar.dart';
import '../widgets/labels_sheet.dart';
import '../widgets/masonry.dart';
import '../widgets/note_actions.dart';
import '../widgets/note_card.dart';
import '../widgets/note_zoom.dart';
import '../widgets/page_header.dart';
import '../widgets/public_link_dialog.dart';
import '../widgets/quick_add_bar.dart';
import '../widgets/reminders/reminders_view.dart';
import '../widgets/saved_view_dialog.dart';
import '../widgets/screen_width.dart';
import '../widgets/search_filters_sheet.dart';
import '../widgets/search_query_controller.dart';
import '../widgets/share_dialog.dart';
import '../widgets/shortcut_help.dart';
import '../widgets/skeleton.dart';
import 'editor_screen.dart';
import '../widgets/sync_pill.dart';

/// What one build of the home screen shows, worked out once in `build` and
/// handed to the pieces that draw it.
typedef _HomeView = ({
  NoteSections sections,
  bool searching,
  bool collectionView,
  bool semanticAvailable,
  bool semanticActive,
  bool semanticLoading,
  bool dragEnabled,
  GridDensity density,
  GridWidth gridWidth,
});

/// How the grid fills the width it is given: the gutter either side, the
/// widest the cards may spread, and how many columns fit in between.
typedef _GridMetrics = ({double pad, double maxWidth, int columns});

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ViewSelection _selection = ViewSelection.notes;
  String? _shownWorkspaceId;
  String _query = '';
  bool _listMode = false;
  bool _isSidebarOpen = true;
  final Set<String> _selectedNoteIds = {};
  bool _selectionMode = false;
  final _selectionModeNotifier = ValueNotifier(false);
  // Paints a background behind the `label:`/`is:` operators, and is what
  // the filter sheet edits while it stays open.
  final _searchController = SearchQueryController();
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

  /// When focus falls back to the route's own scope, a dismissed editor
  /// dialog, a collapsed quick-add, nothing inside the page is focused any
  /// more, so pick focus back up to keep the keyboard shortcuts live. Scopes
  /// of other routes, or the drawer's, never match the home route's scope.
  void _reclaimFocus() {
    if (!mounted) return;
    if (FocusManager.instance.primaryFocus == FocusScope.of(context)) {
      _pageFocus.requestFocus();
    }
  }

  /// The state's own context sits above the Scaffold, so Scaffold.of()
  /// can't reach it, open the drawer through a key instead.
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Card heights every grid this screen builds starts from, so going back
  /// to a collection or view lays its cards out where they settled before.
  final _cardHeights = MasonryHeights();

  void _toggleSidebar() {
    if (!ScreenWidth.isAtLeast(context, kWideBreakpoint)) {
      _scaffoldKey.currentState?.openDrawer();
    } else {
      setState(() => _isSidebarOpen = !_isSidebarOpen);
    }
  }

  // Semantic search: ranked ids from the server, refreshed as you type. The
  // on/off preference is persisted in settings so it survives an app restart.
  bool get _semantic => context.read<SettingsStore>().semanticRanking;
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
    _selectionModeNotifier.dispose();
    super.dispose();
  }

  /// What match highlighting should tint: the free text of the box, without
  /// its `label:`/`is:` operators. Those are structure rather than words, and
  /// tinting them would light up unrelated runs of text inside the cards.
  String get _highlightQuery => parseSearchQuery(_effectiveQuery).text;

  void _onQueryChanged(String q) {
    setState(() => _query = q);
    _scheduleSemantic();
  }

  void _toggleSemantic() {
    final settings = context.read<SettingsStore>();
    settings.setSemanticRanking(!settings.semanticRanking);
    _scheduleSemantic();
  }

  /// What the embedder should actually be asked to rank: the words, without
  /// the operators. Sending `is:pinned` to a semantic endpoint asks it to find
  /// notes that read like the string "is:pinned", which is meaningless.
  String get _semanticText => parseSearchQuery(_effectiveQuery).text.trim();

  void _scheduleSemantic() {
    _semanticDebounce?.cancel();
    if (!_semantic || _semanticText.isEmpty) {
      setState(() {
        _semanticIds = null;
        _semanticBusy = false;
      });
      return;
    }
    // Show the loading state right away (spinner in the bar, skeleton in the
    // body on a first search) rather than only once the debounce fires, the
    // user toggled/typed, so results are on their way.
    setState(() => _semanticBusy = true);
    _semanticDebounce = Timer(const Duration(milliseconds: 350), () async {
      final query = _semanticText;
      try {
        final notes = await context.read<NotesStore>().semanticSearch(query);
        if (!mounted || _semanticText != query) return;
        setState(() => _semanticIds = [for (final n in notes) n.id]);
      } on ApiException catch (e) {
        if (!mounted) return;
        if (e.statusCode == 503) {
          setState(() {
            _semanticAvailable = false;
            _semanticIds = null;
          });
          showAppSnack('Semantic search is not enabled on this server');
        }
      } catch (_) {
        // Network hiccup: keep whatever results we had.
      } finally {
        // Only the fetch for the query still in the box clears the loading
        // state, a superseded fetch finishing must not switch off the
        // spinner/skeleton while the newer search is still on its way.
        if (mounted && _semanticText == query) {
          setState(() => _semanticBusy = false);
        }
      }
    });
  }

  void _selectView(ViewSelection selection) {
    // A new view starts at its top, not at whatever depth the last one was
    // scrolled to. Picking the view already shown glides back up instead.
    if (_scrollController.hasClients) {
      if (selection == _selection) {
        _scrollController.animateTo(
          0,
          duration: Motion.reduced(context) ? Duration.zero : Motion.slow,
          curve: Motion.emphasized,
        );
      } else {
        _scrollController.jumpTo(0);
      }
    }

    context.read<NotesStore>().rememberWorkspaceView(selection);
    setState(() {
      _selection = selection;
      _query = '';
      _searchController.clear();
      _selectionMode = false;
      _selectedNoteIds.clear();
    });
    _selectionModeNotifier.value = false;
  }

  void _cancelSelection() {
    setState(() {
      _selectionMode = false;
      _selectedNoteIds.clear();
    });
    _selectionModeNotifier.value = false;
  }

  void _toggleNoteSelection(String id, bool selected) {
    setState(() {
      if (selected) {
        _selectionMode = true;
        _selectedNoteIds.add(id);
      } else {
        _selectedNoteIds.remove(id);
      }
      // An empty selection has nothing to act on: deselecting the last note
      // leaves the mode instead of stranding the user in an inert action bar.
      _selectionMode = _selectedNoteIds.isNotEmpty;
    });
    _selectionModeNotifier.value = _selectionMode;
  }

  void _toggleSelectAll(Iterable<Note> visibleNotes) {
    final ids = {for (final note in visibleNotes) note.id};
    setState(() {
      if (ids.isNotEmpty && ids.every(_selectedNoteIds.contains)) {
        _selectedNoteIds.removeAll(ids);
      } else {
        _selectedNoteIds.addAll(ids);
      }
      _selectionMode = _selectedNoteIds.isNotEmpty;
    });
    _selectionModeNotifier.value = _selectionMode;
  }

  List<Note> _selectedNotes(NotesStore store) => [
    for (final id in _selectedNoteIds)
      if (store.noteById(id) case final Note note) note,
  ];

  Future<void> _addLabelToSelected(NotesStore store) =>
      LabelsSheet.showForNotes(
        context,
        _selectedNotes(store).map((note) => note.id),
      );

  /// Bulk-file the selection into a column, then leave selection mode, the
  /// selection was a means to the move, not a state to stay in.
  Future<void> _moveSelectedToStage(NotesStore store) async {
    await MoveToStageSheet.showForNotes(
      context,
      _selectedNotes(store).map((note) => note.id),
    );
    if (mounted) _cancelSelection();
  }

  Future<void> _setColorForSelected(NotesStore store) => ColorPickerSheet.show(
    context,
    selected: () {
      final colors = {for (final note in _selectedNotes(store)) note.color};
      return colors.length == 1 ? colors.single : 'default';
    },
    onSelect: (color) {
      for (final note in _selectedNotes(store)) {
        store.setColor(note.id, color);
      }
    },
  );

  void _setPinnedForSelected(NotesStore store, bool pinned) {
    final notes = _selectedNotes(store);
    for (final note in notes) {
      if (note.pinned != pinned) store.togglePin(note.id);
    }
  }

  Future<void> _shareSelected(NotesStore store) => BulkShareDialog.show(
    context,
    _selectedNotes(store).map((note) => note.id),
  );

  void _setArchivedForSelected(NotesStore store, bool archived) {
    final notes = _selectedNotes(
      store,
    ).where((note) => note.archived != archived).toList();
    for (final note in notes) {
      store.setArchived(note.id, archived);
    }
    _cancelSelection();
  }

  Future<void> _restoreSelected(NotesStore store) async {
    final notes = _selectedNotes(store).where((note) => note.trashed).toList();
    for (final note in notes) {
      if (!mounted) {
        return;
      }
      await CollectionPicker.restore(context, note.id);
    }
    _cancelSelection();
  }

  void _trashSelected(NotesStore store) {
    final notes = _selectedNotes(
      store,
    ).where((note) => store.canTrash(note.id)).toList();
    final skipped = _selectedNoteIds.length - notes.length;
    for (final note in notes) {
      store.moveToTrash(note.id);
    }
    _cancelSelection();
    if (notes.isNotEmpty) {
      showAppSnack(
        '${notes.length} ${notes.length == 1 ? 'note' : 'notes'} moved to Trash${skipped > 0 ? '; shared notes were skipped' : ''}',
        icon: Icons.delete_outline,
        kind: SnackKind.danger,
        actionLabel: 'Undo',
        onAction: () {
          for (final note in notes) {
            store.restoreFromTrash(note.id);
          }
        },
      );
    } else if (skipped > 0) {
      showAppSnack(
        'Only note owners can move notes to Trash',
        icon: Icons.error_outline,
        kind: SnackKind.warning,
      );
    }
  }

  /// Labels a note composed right now should start with: the label being
  /// filtered on, so it stays in view instead of dropping out of the list the
  /// moment it's written. Empty in every other view.
  Set<String> get _composeLabelIds =>
      _selection.view == NoteView.label && _selection.labelId != null
      ? {_selection.labelId!}
      : const {};

  // Keyboard shortcut callbacks. The bindings are [_homeShortcuts];
  // widgets/shortcut_help.dart and the README document the full set.
  void _newNote(NoteKind kind) {
    if (context.read<NotesStore>().activeCollection == null) {
      CollectionSettings.show(context);
      return;
    }
    openNoteEditor(
      context,
      kind: kind,
      labelIds: _composeLabelIds,
      openFullscreen: () => Navigator.of(context).push(
        NoteZoomRoute(
          builder: (_) => EditorScreen(kind: kind, labelIds: _composeLabelIds),
        ),
      ),
    );
  }

  void _focusSearch() => _searchFocus.requestFocus();

  /// Escape backs out of whatever the screen is currently "in": selection
  /// mode first (it's the more modal of the two), then the search.
  void _escape() {
    if (_selectionMode) {
      _cancelSelection();
      _pageFocus.requestFocus();
      return;
    }
    _clearSearch();
  }

  void _clearSearch() {
    _searchController.clear();
    _onQueryChanged('');
    _pageFocus.requestFocus();
  }

  /// The cheat sheet of search operators, and the way from a search you like
  /// to a smart view that keeps it.
  ///
  /// The sheet toggles filters on the controller directly and stays open, so
  /// this only handles what it wants done after it closes.
  Future<void> _openSearchFilters() async {
    final result = await SearchFiltersSheet.show(
      context,
      controller: _searchController,
      onChanged: _onQueryChanged,
    );
    if (!mounted) return;
    switch (result) {
      case SaveAsSmartView():
        await _saveSearchAsView(_query);
      case null:
        // Back to the box they were just building, caret at the end.
        if (_query.trim().isNotEmpty) _searchFocus.requestFocus();
    }
  }

  /// What publishing "this view" would put on the internet, or null when the
  /// open view is not publishable.
  ///
  /// Archive, trash, reminders and smart views are all deliberately excluded.
  /// The first three are private housekeeping, and a smart view is a query
  /// this account holds, not a thing the server can resolve for a stranger.
  /// Workspaces the user only belongs to are excluded too: publishing a whole
  /// view exposes every member's notes, so it stays the owner's call, which
  /// the server enforces independently.
  PublicLinkTarget? _shareViewTarget(NotesStore store) {
    final workspace = store.activeWorkspace;
    if (workspace == null) return null;
    if (!workspace.isOwnedBy(store.currentUserId)) return null;
    switch (_selection.view) {
      case NoteView.notes:
        return PublicLinkTarget(
          target: ShareTarget.notes,
          workspaceId: workspace.id,
          collectionId: store.activeCollection?.id,
          title: store.activeCollection?.name ?? workspace.name,
          scopeDescription:
              'Anyone with the link can read every live note in '
              '"${store.activeCollection?.name ?? workspace.name}", including notes other members wrote. '
              'Archived and trashed notes stay private.',
        );
      case NoteView.board:
        return PublicLinkTarget(
          target: ShareTarget.board,
          workspaceId: workspace.id,
          collectionId: store.activeCollection?.id,
          title: '${store.activeCollection?.name ?? workspace.name} board',
          scopeDescription:
              'Anyone with the link can read the board of '
              '"${store.activeCollection?.name ?? workspace.name}": its columns and the cards in them, '
              'including cards other members wrote.',
        );
      case NoteView.label:
        final label = store.labelById(_selection.labelId!);
        if (label == null) return null;
        return PublicLinkTarget(
          target: ShareTarget.label,
          labelId: label.id,
          collectionId: store.activeCollection?.id,
          title: label.name,
          scopeDescription:
              'Anyone with the link can read every live note labelled '
              '"${label.name}" in this collection, including notes other members wrote.',
        );
      case NoteView.reminders:
      case NoteView.archive:
      case NoteView.trash:
      case NoteView.smart:
        return null;
    }
  }

  Future<void> _shareCurrentView(NotesStore store) async {
    final target = _shareViewTarget(store);
    if (target == null) return;
    await PublicLinkDialog.show(context, target: target, api: store.api);
  }

  /// Saves [query] as a smart view and opens it, so the sidebar entry the user
  /// just made is the thing they end up looking at.
  Future<void> _saveSearchAsView(String query) async {
    final saved = await SavedViewDialog.show(context, initialQuery: query);
    if (!mounted || saved == null) return;
    _selectView(ViewSelection.smart(saved.id));
    showAppSnack('Smart view saved', icon: Icons.bookmark_added_outlined);
  }

  String _viewTitle(NotesStore store) => switch (_selection.view) {
    NoteView.notes ||
    NoteView.board => store.activeCollection?.name ?? 'Collections',
    NoteView.reminders => 'Reminders',
    NoteView.archive => 'Archive',
    NoteView.trash => 'Trash',
    NoteView.label => store.labelById(_selection.labelId!)?.name ?? '',
    NoteView.smart => _savedView?.name ?? 'Smart view',
  };

  /// The saved view the current selection points at, or null when the
  /// selection is anything else (or points at a view that has since been
  /// deleted, on this device or another one).
  SavedView? get _savedView {
    final id = _selection.savedViewId;
    if (id == null) return null;
    return context.read<NotesStore>().savedViewById(id);
  }

  /// What actually filters the grid: the open smart view's saved query with
  /// whatever is typed in the box appended. Terms are ANDed, so typing narrows
  /// a smart view further rather than replacing it.
  String get _effectiveQuery => _queryFor(context.read<NotesStore>());

  String _queryFor(NotesStore store) {
    final label = _selection.view == NoteView.label
        ? store.labelById(_selection.labelId!)
        : null;
    final saved = label == null
        ? (_selection.view == NoteView.smart
              ? store.savedViewById(_selection.savedViewId!)?.query
              : null)
        : 'label:"${label.name}"';
    if (saved == null || saved.isEmpty) return _query;
    if (_query.trim().isEmpty) return saved;
    return '$saved $_query';
  }

  /// Files dropped anywhere on the grid become one new note (web only).
  Future<void> _createNoteFromDrop(List<DroppedFile> files) async {
    final store = context.read<NotesStore>();
    final accepted = withinUploadLimit(files);
    if (accepted.isEmpty) return;
    final labelIds = _composeLabelIds;
    final id = await store.createNoteWithFiles(accepted, labelIds: labelIds);
    if (id == null) {
      showAppSnack(
        "Couldn't upload the dropped files",
        icon: Icons.error_outline,
        kind: SnackKind.danger,
      );
    }
  }

  void _confirmEmptyTrash(NotesStore store) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
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
      showAppSnack(
        'Trash emptied',
        icon: Icons.delete_sweep_outlined,
        kind: SnackKind.danger,
      );
    }
  }

  ViewSelection _primaryView(NotesStore store) =>
      store.activeCollection?.layout == 'board'
      ? ViewSelection.board
      : ViewSelection.notes;

  bool _viewIsAvailable(ViewSelection selection, NotesStore store) =>
      switch (selection.view) {
        NoteView.notes => store.activeCollection?.layout != 'board',
        NoteView.board => store.activeCollection?.layout == 'board',
        NoteView.label => store.labels.any(
          (label) => label.id == selection.labelId,
        ),
        // A smart view deleted on another device leaves this one pointing at
        // nothing; treat that like a deleted label and fall back to the grid.
        NoteView.smart =>
          context.read<NotesStore>().savedViewById(selection.savedViewId!) !=
              null,
        NoteView.reminders || NoteView.archive || NoteView.trash => true,
      };

  /// Each workspace reopens its own last navigation destination. Shared
  /// setting changes and deleted labels can invalidate that destination; in
  /// those cases use the remaining primary view and remember the fallback.
  void _reconcileWorkspaceView(NotesStore store) {
    final workspace = store.activeWorkspace;
    if (workspace == null) return;
    final workspaceChanged = _shownWorkspaceId != workspace.id;
    // Another workspace is another grid; open it at the top. Deferred because
    // this runs during build.
    if (workspaceChanged && _shownWorkspaceId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      });
    }
    final remembered = store.lastWorkspaceView(workspace.id);
    final candidate = workspaceChanged && remembered != null
        ? remembered
        : _selection;
    final target = _viewIsAvailable(candidate, store)
        ? candidate
        : _primaryView(store);
    _shownWorkspaceId = workspace.id;
    if (target == _selection) {
      if (workspaceChanged && remembered == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && store.activeWorkspaceId == workspace.id) {
            store.rememberWorkspaceView(target);
          }
        });
      }
      return;
    }
    // Runs before build reads the selection, so the first frame already
    // shows the workspace's own view rather than building a grid to drop.
    _selection = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && store.activeWorkspaceId == workspace.id) {
        store.rememberWorkspaceView(target);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<NotesStore>();
    _reconcileWorkspaceView(store);
    final viewState = context.select(
      (NotesStore s) => (
        sections: s.notesFor(_selection, _queryFor(s), display: true),
        loading: s.loading,
        offline: s.offline,
      ),
    );
    final settings = context.select(
      (SettingsStore s) => (
        semanticSearchAvailable: s.semanticSearchAvailable,
        semanticRanking: s.semanticRanking,
        gridDensity: s.gridDensity,
        gridWidth: s.gridWidth,
      ),
    );
    _listMode = store.activeCollection?.layout == 'list';
    final collectionView = ![
      NoteView.archive,
      NoteView.trash,
      NoteView.reminders,
    ].contains(_selection.view);
    // Only offer semantic search when the server supports it and the user
    // hasn't turned it off.
    final semanticAvailable =
        _semanticAvailable && settings.semanticSearchAvailable;
    final searching = _query.trim().isNotEmpty;
    // Semantic mode replaces keyword *ranking* with the server's, not the
    // query's filters: `label:work sourdough` still has to mean notes labelled
    // work, so the ranked ids run through the same rules as the typed path and
    // only supply the order. It also needs words to rank, so a query that is
    // nothing but operators stays on the keyword path.
    final semanticActive =
        _semantic &&
        semanticAvailable &&
        _semanticText.isNotEmpty &&
        (_selection.view == NoteView.notes ||
            _selection.view == NoteView.board);
    final rankedIds = _semanticIds;
    final canReorder =
        !searching &&
        store.sortMode == SortMode.custom &&
        (_selection.view == NoteView.notes ||
            _selection.view == NoteView.archive);
    final view = (
      sections: semanticActive && rankedIds != null
          ? _rankedSections(
              store,
              rankedIds,
              collectionView ? store.collectionScope : store.workspaceScope,
            )
          : viewState.sections,
      searching: searching,
      collectionView: collectionView,
      semanticAvailable: semanticAvailable,
      semanticActive: semanticActive,
      // Loading indicator in the results area while the first semantic search
      // is in flight (no ranked results to show yet). On a refine the previous
      // results stay put and only the in-bar spinner signals the fetch, so the
      // grid doesn't flash a skeleton on every keystroke.
      semanticLoading: semanticActive && _semanticBusy && rankedIds == null,
      // Trash never reorders, but a card can still be dragged out of it onto
      // a collection, which restores it there.
      dragEnabled:
          canReorder || _selectionMode || _selection.view == NoteView.trash,
      density: settings.gridDensity,
      gridWidth: settings.gridWidth,
    );

    return Shortcuts(
      shortcuts: _homeShortcuts,
      child: Actions(
        actions: _shortcutActions(store),
        child: Focus(
          focusNode: _pageFocus,
          autofocus: true,
          child: FileDropArea(
            hint: 'Drop files to create a note',
            onFiles: _createNoteFromDrop,
            child: GestureDetector(
              excludeFromSemantics: true,
              onTap: () => _pageFocus.requestFocus(),
              child: Scaffold(
                key: _scaffoldKey,
                drawer: AppDrawer(selection: _selection, onSelect: _selectView),
                // The note-creation FABs live inside the body (not the
                // Scaffold's floatingActionButton slot) so a floating SnackBar
                // sits at the bottom instead of floating above this tall FAB
                // column. Still in the body, so the drawer scrim covers them
                // like a normal FAB.
                body: Column(
                  children: [
                    _topBar(store, view),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: hairlineColor(Theme.of(context).colorScheme),
                    ),
                    Expanded(
                      // Home-indicator and landscape-notch insets; the top one
                      // is already consumed by the bar above.
                      child: SafeArea(
                        top: false,
                        child: Row(
                          children: [
                            if (ScreenWidth.isAtLeast(context, kWideBreakpoint))
                              AppSidebar(
                                isOpen: _isSidebarOpen,
                                selection: _selection,
                                selectedNoteIds: _selectedNoteIds,
                                onSelectionFiled: _cancelSelection,
                                onSelect: _selectView,
                              ),
                            Expanded(
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: _viewBody(store, view),
                                  ),
                                  // Beside the new-note button, centred on
                                  // it; phones keep the offline banner.
                                  if (ScreenWidth.isAtLeast(
                                    context,
                                    kWideBreakpoint,
                                  ))
                                    const Positioned(
                                      right: 16 + 56 + kSpaceMd,
                                      bottom: 16 + 14,
                                      child: SyncPill(),
                                    ),
                                  if (store.activeCollection != null)
                                    Positioned(
                                      right: 16,
                                      bottom: 16,
                                      child: NewNoteFabs(
                                        labelIds: _composeLabelIds,
                                      ),
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

  /// The semantic results for the open view: the server's ranking, put
  /// through the same filters as a typed query.
  NoteSections _rankedSections(
    NotesStore store,
    List<String> rankedIds,
    WorkspaceScope scope,
  ) => NoteSections(
    const [],
    filterNotes(
      notes: [
        for (final id in rankedIds)
          if (store.displayNoteById(id) case final Note note) note,
      ],
      labels: store.labels,
      selection: _selection,
      // Filters only: the ranking already answered the words.
      query: parseSearchQuery(_effectiveQuery).filtersOnly,
      currentUserId: store.currentUserId,
      scope: scope,
    ),
  );

  Map<Type, Action<Intent>> _shortcutActions(NotesStore store) => {
    _NewNoteIntent: _HomeAction<_NewNoteIntent>(
      onInvoke: (intent) => _newNote(intent.kind),
    ),
    _FocusSearchIntent: _HomeAction<_FocusSearchIntent>(
      onInvoke: (_) => _focusSearch(),
    ),
    _EscapeIntent: _HomeAction<_EscapeIntent>(onInvoke: (_) => _escape()),
    _ToggleLayoutIntent: _HomeAction<_ToggleLayoutIntent>(
      onInvoke: (_) =>
          CollectionSettings.show(context, collection: store.activeCollection),
    ),
    _ShortcutHelpIntent: _HomeAction<_ShortcutHelpIntent>(
      onInvoke: (_) => showShortcutHelp(context),
    ),
  };

  /// The band across the top: search while browsing, bulk actions while notes
  /// are selected.
  Widget _topBar(NotesStore store, _HomeView view) {
    // Paint the status-bar/notch area in the bar's own surface color and keep
    // its content below the top inset (a bare SafeArea would leave a
    // scaffold-colored strip up there).
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        bottom: false,
        child: Padding(
          // Desktop has no status bar to hold the bar off the window's top
          // edge, so it gets breathing room here instead, matched on the
          // bottom so the bar sits centered in the space above the divider
          // rather than pinned to it.
          padding: EdgeInsets.symmetric(
            vertical: ScreenWidth.isAtLeast(context, kWideBreakpoint) ? 6 : 0,
          ),
          child: HomeTopBar(
            controller: _searchController,
            focusNode: _searchFocus,
            semantic: _semantic,
            semanticAvailable: view.semanticAvailable,
            semanticBusy: _semanticBusy,
            onQuery: _onQueryChanged,
            onToggleSemantic: _toggleSemantic,
            onOpenFilters: _openSearchFilters,
            onShareView: _shareViewTarget(store) == null
                ? null
                : () => _shareCurrentView(store),
            onToggleSidebar: _toggleSidebar,
            selection: _selectionMode ? _selectionActions(store, view) : null,
            title: _viewTitle(store),
          ),
        ),
      ),
    );
  }

  SelectionActions _selectionActions(NotesStore store, _HomeView view) {
    final selected = _selectedNotes(store);
    final visibleNotes = [...view.sections.pinned, ...view.sections.others];
    return SelectionActions(
      count: _selectedNoteIds.length,
      allSelected:
          visibleNotes.isNotEmpty &&
          visibleNotes.every((note) => _selectedNoteIds.contains(note.id)),
      pinSelected:
          selected.isNotEmpty && !selected.every((note) => note.pinned),
      archiveSelected: _selection.view != NoteView.archive,
      canArchive: _selection.view != NoteView.trash,
      canRestore: _selection.view == NoteView.trash,
      canTrash: _selection.view != NoteView.trash,
      canMoveToStage: _selection.view == NoteView.board,
      onCancel: _cancelSelection,
      onToggleSelectAll: () => _toggleSelectAll(visibleNotes),
      onArchive: () =>
          _setArchivedForSelected(store, _selection.view != NoteView.archive),
      onRestore: () => _restoreSelected(store),
      onTrash: () => _trashSelected(store),
      onAddLabel: () => _addLabelToSelected(store),
      onMoveToStage: () => _moveSelectedToStage(store),
      onSetColor: () => _setColorForSelected(store),
      onPin: () => _setPinnedForSelected(
        store,
        _selectedNotes(store).any((note) => !note.pinned),
      ),
      onShare: () => _shareSelected(store),
    );
  }

  /// What fills the area beside the sidebar. The board and the reminders lay
  /// their notes out their own way; every other view is the grid.
  Widget _viewBody(NotesStore store, _HomeView view) {
    // The board is a horizontal container of independently scrolling columns,
    // so it replaces the sliver stack rather than nesting an opposing scroll
    // inside it.
    if (view.collectionView && store.activeCollection?.layout == 'board') {
      return BoardView(
        query: _effectiveQuery,
        rankedIds: view.semanticActive ? _semanticIds?.toSet() : null,
        selectionMode: _selectionMode,
        selectedIds: _selectedNoteIds,
        onSelectionChanged: _toggleNoteSelection,
        onToggleColumnSelection: _toggleSelectAll,
      );
    }
    // Reminders fall on days rather than in a grid, so they get an agenda and
    // a calendar of their own.
    if (_selection.view == NoteView.reminders) {
      return RemindersView(query: _effectiveQuery);
    }
    return _notesGrid(store, view);
  }

  Widget _notesGrid(NotesStore store, _HomeView view) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final compact = width < kWideBreakpoint;
        final grid = _gridMetrics(width, view.density, view.gridWidth);
        final scheme = Theme.of(context).colorScheme;
        return RefreshIndicator(
          // refresh, not load: the indicator draws its own spinner, so
          // flipping `loading` would swap the grid for skeletons under the
          // user's finger.
          onRefresh: store.refresh,
          edgeOffset: 16,
          color: scheme.primary,
          backgroundColor: scheme.surfaceContainerHigh,
          elevation: 2,
          child: CustomScrollView(
            controller: _scrollController,
            // Phones keep pull-to-refresh available even when the list is
            // short. On desktop, forcing that physics makes a fully visible
            // grid move despite having nowhere to scroll.
            physics: compact ? const AlwaysScrollableScrollPhysics() : null,
            slivers: [
              const SliverToBoxAdapter(child: SizedBox(height: kSpaceLg)),
              _offlineBannerSliver(store),
              // Inline quick add: wide screens, in the views you compose into
              // (all notes, or a label, where it files the note for you).
              if (!compact &&
                  !view.searching &&
                  (_selection.view == NoteView.notes ||
                      _selection.view == NoteView.label))
                _quickAddSliver(store),
              // Wide, the top bar names the view, so only Trash keeps a
              // header here, for its notice and "Empty trash".
              if (!view.collectionView &&
                  _viewTitle(store).isNotEmpty &&
                  (!HomeTopBar.showsTitle(context) ||
                      _selection.view == NoteView.trash))
                _alignedToGrid(
                  _ViewHeader(
                    title: _viewTitle(store),
                    isTrash: _selection.view == NoteView.trash,
                    hasTrashedNotes: view.sections.others.isNotEmpty,
                    onEmptyTrash: () => _confirmEmptyTrash(store),
                  ),
                  grid,
                ),
              // Phones need clearance for their overlaid FAB stack. Desktop
              // keeps only the ordinary bottom gutter; the inline composer is
              // primary there, and a permanent 200px tail made short grids
              // scroll for no visible reason.
              ..._resultSlivers(
                store,
                view,
                grid,
                bottomGap: compact ? 200 : 16,
              ),
            ],
          ),
        );
      },
    );
  }

  /// How the grid fills [width]: a wider gutter on a roomy window, cards
  /// capped at the chosen grid width (one readable column in list mode), and
  /// as many columns as fit the density's card width.
  _GridMetrics _gridMetrics(
    double width,
    GridDensity density,
    GridWidth gridWidth,
  ) {
    final pad = width >= 900 ? 32.0 : 16.0;
    final maxWidth = _listMode ? 600.0 : gridWidth.maxWidth;
    final usable = math.min(width - pad * 2, maxWidth);
    final columns = _listMode
        ? 1
        : (usable / density.targetWidth).floor().clamp(2, density.maxColumns);
    return (pad: pad, maxWidth: maxWidth, columns: columns);
  }

  /// Always present so going on/offline grows/shrinks the banner smoothly
  /// instead of jolting the grid below it.
  Widget _offlineBannerSliver(NotesStore store) {
    return SliverToBoxAdapter(
      child: AnimatedSize(
        duration: Motion.base,
        curve: Motion.emphasized,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: Motion.base,
          switchInCurve: Motion.standard,
          switchOutCurve: Motion.standard,
          child: store.offline
              ? _OfflineBanner(onRetry: store.retryNow)
              : const SizedBox(width: double.infinity),
        ),
      ),
    );
  }

  Widget _quickAddSliver(NotesStore store) {
    return SliverToBoxAdapter(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: store.activeCollection == null
                ? FilledButton.icon(
                    onPressed: () => CollectionSettings.show(context),
                    icon: const Icon(Icons.add),
                    label: const Text('Create a collection'),
                  )
                : QuickAddBar(labelIds: _composeLabelIds),
          ),
        ),
      ),
    );
  }

  /// The notes themselves, or what stands in for them: skeletons while they
  /// load, an empty state when there are none. [bottomGap] is the clearance
  /// left under the last card.
  List<Widget> _resultSlivers(
    NotesStore store,
    _HomeView view,
    _GridMetrics grid, {
    required double bottomGap,
  }) {
    if (store.loading || view.semanticLoading) {
      return [
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: grid.maxWidth),
              child: Padding(
                padding: EdgeInsets.fromLTRB(grid.pad, 8, grid.pad, 0),
                child: NotesSkeleton(columns: grid.columns),
              ),
            ),
          ),
        ),
      ];
    }

    final sections = view.sections;
    if (sections.isEmpty) {
      return [
        SliverFillRemaining(hasScrollBody: false, child: _emptyState(view)),
      ];
    }

    return [
      if (sections.pinned.isNotEmpty) ...[
        _sectionLabel('Pinned', grid),
        _grid(store, sections.pinned, grid, view, section: 'pinned'),
        if (sections.others.isNotEmpty) _sectionLabel('Others', grid),
      ],
      _grid(store, sections.others, grid, view, section: 'others'),
      // Fill unused space without extending it.
      SliverFillRemaining(
        hasScrollBody: false,
        child: SizedBox(height: bottomGap),
      ),
    ];
  }

  /// What an empty view says, and the one step it offers out of it.
  Widget _emptyState(_HomeView view) {
    if (view.searching) {
      return const EmptyState(
        icon: Icons.search_off,
        message: 'No matching notes',
      );
    }

    final (icon, message) = switch (_selection.view) {
      NoteView.notes => (
        Icons.sticky_note_2_outlined,
        'Notes you add appear here',
      ),
      NoteView.board => (
        Icons.view_kanban_outlined,
        'Notes you add appear here',
      ),
      NoteView.reminders => (
        Icons.notifications_outlined,
        'Notes with reminders appear here',
      ),
      NoteView.archive => (
        Icons.archive_outlined,
        'Your archived notes appear here',
      ),
      NoteView.trash => (Icons.delete_outline, 'No notes in Trash'),
      NoteView.label => (Icons.label_outline, 'No notes with this label yet'),
      NoteView.smart => (
        Icons.filter_alt_outlined,
        'No notes match this smart view',
      ),
    };

    switch (_selection.view) {
      // A smart view is a query, so the way out of an empty one is to go and
      // look at the notes, not to write a note that probably won't match it.
      case NoteView.smart || NoteView.archive || NoteView.trash:
        return EmptyState(
          icon: icon,
          message: message,
          actionLabel: 'Browse notes',
          actionIcon: Icons.sticky_note_2_outlined,
          onAction: () => _selectView(_primaryView(context.read<NotesStore>())),
        );
      case NoteView.notes ||
          NoteView.board ||
          NoteView.reminders ||
          NoteView.label:
        return EmptyState(
          icon: icon,
          message: message,
          actionLabel: 'Create note',
          onAction: () => _newNote(NoteKind.text),
          showBrandMark: _selection.view == NoteView.notes,
        );
    }
  }

  /// Wrap a header-like widget (section label, view header) so its edges line
  /// up with the grid's cards: same outer pad and same max width cap,
  /// centered the same way, so it tracks the grid's left edge whether the grid
  /// fills the area or sits centered within a narrower band.
  Widget _alignedToGrid(Widget child, _GridMetrics grid) {
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: grid.pad),
      sliver: SliverToBoxAdapter(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: grid.maxWidth),
            // Fill the capped width (unlike the grid's masonry, a bare Text
            // would shrink to its content and then get centered), so the child
            // left-aligns to the grid's left edge.
            child: SizedBox(width: double.infinity, child: child),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text, _GridMetrics grid) {
    return _alignedToGrid(
      Padding(
        // 8px inset from the card's left edge, matching the view header.
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: Text(
          text.toUpperCase(),
          style: sectionLabelStyle(Theme.of(context)),
        ),
      ),
      grid,
    );
  }

  Widget _grid(
    NotesStore store,
    List<Note> notes,
    _GridMetrics grid,
    _HomeView view, {
    required String section,
  }) {
    final query = _highlightQuery;
    Widget tile(Note note) => NoteTile(
      key: ValueKey(note.id),
      note: note,
      showCollection: _selection.view == NoteView.archive,
      query: query,
      selectionMode: _selectionMode,
      selectionModeListenable: isTouchPrimaryPlatform
          ? null
          : _selectionModeNotifier,
      selected: _selectedNoteIds.contains(note.id),
      onSelectionChanged: (selected) => _toggleNoteSelection(note.id, selected),
      swipeToArchive: true,
    );

    // Lists without custom order can build only nearby cards. Masonry keeps
    // selected-card drags available even when reordering is disabled.
    final customOrder =
        store.sortMode == SortMode.custom &&
        _query.trim().isEmpty &&
        (_selection.view == NoteView.notes ||
            _selection.view == NoteView.archive);
    if (_listMode && !customOrder) {
      return SliverPadding(
        key: ValueKey('grid-$section'),
        padding: EdgeInsets.symmetric(horizontal: grid.pad),
        sliver: SliverList.builder(
          key: ValueKey((section, _selection)),
          itemCount: notes.length,
          findChildIndexCallback: (key) {
            final index = notes.indexWhere((note) => ValueKey(note.id) == key);
            return index < 0 ? null : index;
          },
          itemBuilder: (context, index) => Padding(
            key: ValueKey(notes[index].id),
            padding: EdgeInsets.only(bottom: index == notes.length - 1 ? 0 : 8),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: grid.maxWidth),
                child: SizedBox(
                  width: double.infinity,
                  child: tile(notes[index]),
                ),
              ),
            ),
          ),
        ),
      );
    }
    final reduced = Motion.reduced(context);
    return SliverPadding(
      // Keyed so the grid keeps its place, and its cross-fade, when the
      // pinned section above it comes or goes.
      key: ValueKey('grid-$section'),
      padding: EdgeInsets.symmetric(horizontal: grid.pad),
      sliver: SliverToBoxAdapter(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: grid.maxWidth),
            // Another view, collection or workspace is another grid. The old
            // one is already laid out, so fading it out as one layer costs a
            // repaint; retiring its cards one by one inside the new grid
            // relaid out both on every frame of the switch.
            child: AnimatedSwitcher(
              duration: reduced ? Duration.zero : Motion.base,
              reverseDuration: reduced ? Duration.zero : Motion.fast,
              switchInCurve: Motion.standard,
              switchOutCurve: Motion.standard,
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topCenter,
                children: [...previous, ?current],
              ),
              child: AnimatedMasonry(
                // Reset layout when switching views so unrelated cards do not
                // glide from the previous view's positions.
                key: ValueKey(
                  '$section-${_selection.view}-${_selection.labelId}-'
                  '${store.activeWorkspaceId}-${store.activeCollection?.id}',
                ),
                heights: _cardHeights,
                notes: notes,
                columns: grid.columns,
                spacing: 8,
                dragEnabled: view.dragEnabled,
                draggableIds: _selectionMode ? _selectedNoteIds : null,
                reorderGroupIds: customOrder ? _selectedNoteIds : const {},
                dragFeedbackLabel: _selectionMode && _selectedNoteIds.length > 1
                    ? 'Move ${_selectedNoteIds.length} cards'
                    : null,
                scrollController: _scrollController,
                // A sidebar drop owns the gesture; crossing grid tiles on the
                // way there must not also persist an incidental reorder.
                onReorder: (reorder) {
                  if (reorder.acceptedByTarget || !customOrder) {
                    return MasonryReorderDecision.restore;
                  }
                  store.reorder(reorder.orderedIds);
                  return MasonryReorderDecision.keep;
                },
                onStationaryLongPress: (id) =>
                    _toggleNoteSelection(id, !_selectedNoteIds.contains(id)),
                // Desktop card chrome observes the mode; its body only changes
                // when that card's own selection changes.
                itemBuildKey: (note) => Object.hash(
                  query,
                  isTouchPrimaryPlatform ? _selectionMode : null,
                  _selectedNoteIds.contains(note.id),
                ),
                itemBuilder: (context, note) => tile(note),
              ),
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
    return PageHeader(
      title: HomeTopBar.showsTitle(context) ? null : title,
      subtitle: isTrash ? 'Notes in Trash are deleted after 7 days' : null,
      trailing: isTrash && hasTrashedNotes
          ? TextButton.icon(
              onPressed: onEmptyTrash,
              icon: const Icon(Icons.delete_forever_outlined, size: 20),
              label: const Text('Empty trash'),
            )
          : null,
    );
  }
}

/// Shown once an outage is confirmed: says what the user is looking at (their
/// own cached notes), that edits aren't lost, and offers an immediate retry
/// rather than leaving them to wait out the background one.
class _OfflineBanner extends StatefulWidget {
  final Future<void> Function() onRetry;
  const _OfflineBanner({required this.onRetry});

  @override
  State<_OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends State<_OfflineBanner> {
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } finally {
      // The banner is gone the moment the retry succeeds, so guard the setState.
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: kBorderRadius,
      ),
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: kSpaceMd),
          Expanded(
            child: Text(
              "Can't reach the server, showing your saved notes. "
              'Changes sync when the connection is back.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          TextButton(
            onPressed: _retrying ? null : _retry,
            child: AnimatedSwitcher(
              duration: Motion.fast,
              switchInCurve: Motion.standard,
              switchOutCurve: Motion.standard,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: animation, child: child),
              ),
              child: _retrying
                  ? const SizedBox(
                      key: ValueKey('retrying'),
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Retry', key: ValueKey('retry')),
            ),
          ),
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

// Printable keys use CharacterActivator so they match what the keystroke
// actually produced on any layout ("/" is Shift+7 on Swiss keyboards), and
// _HomeAction suppresses them while a text field has focus, the event then
// falls through unhandled and the letter is typed instead of firing a
// shortcut. Chords and Escape (whileTyping: true) stay live during typing; the
// quick-add bar consumes its own Escape before it ever bubbles up here.
const _homeShortcuts = <ShortcutActivator, Intent>{
  CharacterActivator('c'): _NewNoteIntent(NoteKind.text),
  CharacterActivator('n'): _NewNoteIntent(NoteKind.text),
  CharacterActivator('l'): _NewNoteIntent(NoteKind.checklist),
  CharacterActivator('m'): _NewNoteIntent(NoteKind.markdown),
  CharacterActivator('/'): _FocusSearchIntent(),
  CharacterActivator('?'): _ShortcutHelpIntent(),
  SingleActivator(LogicalKeyboardKey.keyK, control: true): _FocusSearchIntent(
    whileTyping: true,
  ),
  SingleActivator(LogicalKeyboardKey.keyK, meta: true): _FocusSearchIntent(
    whileTyping: true,
  ),
  SingleActivator(LogicalKeyboardKey.keyG, control: true): _ToggleLayoutIntent(
    whileTyping: true,
  ),
  SingleActivator(LogicalKeyboardKey.keyG, meta: true): _ToggleLayoutIntent(
    whileTyping: true,
  ),
  SingleActivator(LogicalKeyboardKey.escape): _EscapeIntent(whileTyping: true),
};

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

class _EscapeIntent extends _HomeIntent {
  const _EscapeIntent({super.whileTyping});
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
