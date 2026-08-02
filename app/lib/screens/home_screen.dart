import 'dart:async';

import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/dropped_file.dart';
import '../models/note.dart';
import '../models/saved_view.dart';
import '../models/share_link.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/mime.dart';
import '../util/motion.dart';
import '../util/search_query.dart';
import '../util/snack.dart';
import '../widgets/app_drawer.dart';
import '../widgets/board/board_view.dart';
import '../widgets/board/move_to_stage_sheet.dart';
import '../widgets/color_picker.dart';
import '../widgets/empty_state.dart';
import '../widgets/file_drop.dart';
import '../widgets/home_fabs.dart';
import '../widgets/home_top_bar.dart';
import '../widgets/labels_sheet.dart';
import '../widgets/masonry.dart';
import '../widgets/note_card.dart';
import '../widgets/public_link_dialog.dart';
import '../widgets/quick_add_bar.dart';
import '../widgets/saved_view_dialog.dart';
import '../widgets/search_filters_sheet.dart';
import '../widgets/search_query_controller.dart';
import '../widgets/share_dialog.dart';
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
  String? _shownWorkspaceId;
  String _query = '';
  late bool _listMode = context.read<SettingsStore>().defaultListMode;
  bool _isSidebarOpen = true;
  final Set<String> _selectedNoteIds = {};
  bool _selectionMode = false;
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

  void _toggleSidebar() {
    if (MediaQuery.sizeOf(context).width < 600) {
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
    // body on a first search) rather than only once the debounce fires, the
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
        if (mounted && _query.trim() == query) {
          setState(() => _semanticBusy = false);
        }
      }
    });
  }

  void _selectView(ViewSelection selection) {
    context.read<NotesStore>().rememberWorkspaceView(selection);
    setState(() {
      _selection = selection;
      _query = '';
      _searchController.clear();
      _selectionMode = false;
      _selectedNoteIds.clear();
    });
  }

  void _cancelSelection() => setState(() {
    _selectionMode = false;
    _selectedNoteIds.clear();
  });

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

  void _restoreSelected(NotesStore store) {
    final notes = _selectedNotes(store).where((note) => note.trashed).toList();
    for (final note in notes) {
      store.restoreFromTrash(note.id);
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

  // Keyboard shortcut callbacks. The bindings live in build();
  // widgets/shortcut_help.dart and the README document the full set.
  /// Labels a note composed right now should start with: the label being
  /// filtered on, so it stays in view instead of dropping out of the list the
  /// moment it's written. Empty in every other view.
  Set<String> get _composeLabelIds =>
      _selection.view == NoteView.label && _selection.labelId != null
      ? {_selection.labelId!}
      : const {};

  void _newNote(NoteKind kind) => openNoteEditor(
    context,
    kind: kind,
    labelIds: _composeLabelIds,
    openFullscreen: () => Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditorScreen(kind: kind, labelIds: _composeLabelIds),
      ),
    ),
  );

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
          title: workspace.name,
          scopeDescription:
              'Anyone with the link can read every live note in '
              '"${workspace.name}", including notes other members wrote. '
              'Archived and trashed notes stay private.',
        );
      case NoteView.board:
        return PublicLinkTarget(
          target: ShareTarget.board,
          workspaceId: workspace.id,
          title: '${workspace.name} board',
          scopeDescription:
              'Anyone with the link can read the board of '
              '"${workspace.name}": its columns and the cards in them, '
              'including cards other members wrote.',
        );
      case NoteView.label:
        final label = store.labelById(_selection.labelId!);
        if (label == null) return null;
        return PublicLinkTarget(
          target: ShareTarget.label,
          labelId: label.id,
          title: label.name,
          scopeDescription:
              'Anyone with the link can read every live note labelled '
              '"${label.name}", including notes other members wrote.',
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
    NoteView.notes => '',
    NoteView.board => 'Board',
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
    return context.read<SettingsStore>().savedViewById(id);
  }

  /// What actually filters the grid: the open smart view's saved query with
  /// whatever is typed in the box appended. Terms are ANDed, so typing narrows
  /// a smart view further rather than replacing it.
  String get _effectiveQuery {
    final saved = _savedView?.query;
    if (saved == null || saved.isEmpty) return _query;
    if (_query.trim().isEmpty) return saved;
    return '$saved $_query';
  }

  /// Files dropped anywhere on the grid become one new note (web only).
  Future<void> _createNoteFromDrop(List<DroppedFile> files) async {
    final store = context.read<NotesStore>();
    final accepted = [
      for (final f in files)
        if (f.bytes.length <= maxUploadBytes) f,
    ];
    if (accepted.length != files.length) {
      showAppSnack(
        'Files are limited to 25 MB',
        icon: Icons.error_outline,
        kind: SnackKind.warning,
      );
    }
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
      showAppSnack(
        'Trash emptied',
        icon: Icons.delete_sweep_outlined,
        kind: SnackKind.danger,
      );
    }
  }

  ViewSelection _primaryView(NotesStore store) =>
      store.activeWorkspace?.notesEnabled ?? true
      ? ViewSelection.notes
      : ViewSelection.board;

  bool _viewIsAvailable(ViewSelection selection, NotesStore store) =>
      switch (selection.view) {
        NoteView.notes => store.activeWorkspace?.notesEnabled ?? true,
        NoteView.board => store.activeWorkspace?.boardEnabled ?? true,
        NoteView.label => store.labels.any(
          (label) => label.id == selection.labelId,
        ),
        // A smart view deleted on another device leaves this one pointing at
        // nothing; treat that like a deleted label and fall back to the grid.
        NoteView.smart =>
          context.read<SettingsStore>().savedViewById(selection.savedViewId!) !=
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
    // Called from build; defer so the reset lands in its own frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || store.activeWorkspaceId != workspace.id) return;
      store.rememberWorkspaceView(target);
      setState(() => _selection = target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NotesStore>();
    final settings = context.watch<SettingsStore>();
    _reconcileWorkspaceView(store);
    final wideLayout = MediaQuery.sizeOf(context).width >= 600;
    // Only offer semantic search when the server supports it and the user
    // hasn't turned it off.
    final semanticAvailable =
        _semanticAvailable && settings.semanticSearchAvailable;
    final searching = _query.trim().isNotEmpty;
    // Semantic mode replaces keyword filtering with the server's ranking.
    // The board ranks the same way the grid does; it just keeps the ranked
    // cards in their columns instead of flattening them into a result list.
    final semanticActive =
        _semantic &&
        semanticAvailable &&
        searching &&
        (_selection.view == NoteView.notes ||
            _selection.view == NoteView.board);
    final sections = semanticActive && _semanticIds != null
        ? NoteSections(const [], [
            for (final id in _semanticIds!)
              if (store.noteById(id) case final Note note)
                if (!note.trashed && !note.archived) note,
          ])
        : store.notesFor(_selection, _effectiveQuery);
    final visibleNotes = [...sections.pinned, ...sections.others];
    // Loading indicator in the results area while the first semantic search
    // is in flight (no ranked results to show yet). On a refine the previous
    // results stay put and only the in-bar spinner signals the fetch, so the
    // grid doesn't flash a skeleton on every keystroke.
    final semanticLoading =
        semanticActive && _semanticBusy && _semanticIds == null;
    final dragEnabled =
        !_selectionMode &&
        !searching &&
        store.sortMode == SortMode.custom &&
        (_selection.view == NoteView.notes ||
            _selection.view == NoteView.archive);

    // Keyboard shortcuts (web/desktop). Printable keys use
    // CharacterActivator so they match what the keystroke actually produced
    // on any layout ("/" is Shift+7 on Swiss keyboards), and _HomeAction
    // suppresses them while a text field has focus, the event then falls
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
        SingleActivator(LogicalKeyboardKey.escape): _EscapeIntent(
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
          _EscapeIntent: _HomeAction<_EscapeIntent>(onInvoke: (_) => _escape()),
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
                        child: Padding(
                          // Desktop has no status bar to hold the bar off the
                          // window's top edge, so it gets breathing room here
                          // instead, matched on the bottom so the bar sits
                          // centered in the space above the divider rather
                          // than pinned to it.
                          padding: EdgeInsets.symmetric(
                            vertical: wideLayout ? 6 : 0,
                          ),
                          child: HomeTopBar(
                            controller: _searchController,
                            focusNode: _searchFocus,
                            listMode: _listMode,
                            semantic: _semantic,
                            semanticAvailable: semanticAvailable,
                            semanticBusy: _semanticBusy,
                            onQuery: _onQueryChanged,
                            onToggleSemantic: _toggleSemantic,
                            onOpenFilters: _openSearchFilters,
                            onShareView: _shareViewTarget(store) == null
                                ? null
                                : () => _shareCurrentView(store),
                            onToggleLayout: () =>
                                setState(() => _listMode = !_listMode),
                            onToggleSidebar: _toggleSidebar,
                            selectionMode: _selectionMode,
                            selectedCount: _selectedNoteIds.length,
                            allSelected:
                                visibleNotes.isNotEmpty &&
                                visibleNotes.every(
                                  (note) => _selectedNoteIds.contains(note.id),
                                ),
                            canArchive: _selection.view != NoteView.trash,
                            archiveSelected:
                                _selection.view != NoteView.archive,
                            pinSelected:
                                _selectedNotes(store).isNotEmpty &&
                                !_selectedNotes(
                                  store,
                                ).every((note) => note.pinned),
                            canRestore: _selection.view == NoteView.trash,
                            canTrash: _selection.view != NoteView.trash,
                            onCancelSelection: _cancelSelection,
                            onToggleSelectAll: () =>
                                _toggleSelectAll(visibleNotes),
                            onArchiveSelected: () => _setArchivedForSelected(
                              store,
                              _selection.view != NoteView.archive,
                            ),
                            onRestoreSelected: () => _restoreSelected(store),
                            onTrashSelected: () => _trashSelected(store),
                            onAddLabelSelected: () =>
                                _addLabelToSelected(store),
                            onMoveToStageSelected: () =>
                                _moveSelectedToStage(store),
                            canMoveToStage: _selection.view == NoteView.board,
                            onSetColorSelected: () =>
                                _setColorForSelected(store),
                            onPinSelected: () => _setPinnedForSelected(
                              store,
                              _selectedNotes(store).any((note) => !note.pinned),
                            ),
                            onShareSelected: () => _shareSelected(store),
                          ),
                        ),
                      ),
                    ),
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
                            if (MediaQuery.sizeOf(context).width >= 600)
                              AppSidebar(
                                isOpen: _isSidebarOpen,
                                selection: _selection,
                                onSelect: _selectView,
                              ),
                            Expanded(
                              child: Stack(
                                children: [
                                  // The board is a horizontal container of
                                  // independently scrolling columns, so it
                                  // replaces the sliver stack rather than
                                  // nesting an opposing scroll inside it.
                                  if (_selection.view == NoteView.board)
                                    Positioned.fill(
                                      child: BoardView(
                                        query: _query,
                                        rankedIds:
                                            semanticActive &&
                                                _semanticIds != null
                                            ? _semanticIds!.toSet()
                                            : null,
                                        selectionMode: _selectionMode,
                                        selectedIds: _selectedNoteIds,
                                        onSelectionChanged:
                                            _toggleNoteSelection,
                                      ),
                                    )
                                  else
                                    Positioned.fill(
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          final width = constraints.maxWidth;
                                          final horizontalPad = width >= 900
                                              ? 32.0
                                              : 16.0;
                                          final contentWidth =
                                              width - horizontalPad * 2;
                                          final density = settings.gridDensity;
                                          final gridMaxWidth = _listMode
                                              ? 600.0
                                              : settings.gridWidth.maxWidth;
                                          final effectiveWidth =
                                              contentWidth > gridMaxWidth
                                              ? gridMaxWidth
                                              : contentWidth;
                                          final columns = _listMode
                                              ? 1
                                              : (effectiveWidth /
                                                        density.targetWidth)
                                                    .floor()
                                                    .clamp(
                                                      2,
                                                      density.maxColumns,
                                                    );

                                          final refreshScheme = Theme.of(
                                            context,
                                          ).colorScheme;
                                          return RefreshIndicator(
                                            // refresh, not load: the indicator
                                            // draws its own spinner, so flipping
                                            // `loading` would swap the grid for
                                            // skeletons under the user's finger.
                                            onRefresh: store.refresh,
                                            edgeOffset: 16,
                                            color: refreshScheme.primary,
                                            backgroundColor: refreshScheme
                                                .surfaceContainerHigh,
                                            elevation: 2,
                                            child: CustomScrollView(
                                              controller: _scrollController,
                                              // Phones keep pull-to-refresh
                                              // available even when the list is
                                              // short. On desktop, forcing that
                                              // physics makes a fully visible
                                              // grid move despite having
                                              // nowhere to scroll.
                                              physics: width < 600
                                                  ? const AlwaysScrollableScrollPhysics()
                                                  : null,
                                              slivers: [
                                                const SliverToBoxAdapter(
                                                  child: SizedBox(height: 16),
                                                ),
                                                // Always present so going on/off
                                                // line grows/shrinks the banner
                                                // smoothly instead of jolting
                                                // the grid below it.
                                                SliverToBoxAdapter(
                                                  child: AnimatedSize(
                                                    duration: Motion.base,
                                                    curve: Motion.emphasized,
                                                    alignment:
                                                        Alignment.topCenter,
                                                    child: AnimatedSwitcher(
                                                      duration: Motion.base,
                                                      switchInCurve:
                                                          Motion.standard,
                                                      switchOutCurve:
                                                          Motion.standard,
                                                      child: store.offline
                                                          ? _OfflineBanner(
                                                              onRetry: store
                                                                  .retryNow,
                                                            )
                                                          : const SizedBox(
                                                              width: double
                                                                  .infinity,
                                                            ),
                                                    ),
                                                  ),
                                                ),
                                                // Inline quick add: wide screens,
                                                // in the views you compose into
                                                // (all notes, or a label, where
                                                // it files the note for you).
                                                if ((_selection.view ==
                                                            NoteView.notes ||
                                                        _selection.view ==
                                                            NoteView.label) &&
                                                    !searching &&
                                                    width >= 600)
                                                  SliverToBoxAdapter(
                                                    child: Center(
                                                      child: ConstrainedBox(
                                                        constraints:
                                                            const BoxConstraints(
                                                              maxWidth: 600,
                                                            ),
                                                        child: Padding(
                                                          padding:
                                                              const EdgeInsets.fromLTRB(
                                                                16,
                                                                16,
                                                                16,
                                                                24,
                                                              ),
                                                          child: QuickAddBar(
                                                            labelIds:
                                                                _composeLabelIds,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                if (_viewTitle(
                                                  store,
                                                ).isNotEmpty)
                                                  _alignedToGrid(
                                                    _ViewHeader(
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
                                                    horizontalPad,
                                                    gridMaxWidth,
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
                                                      actionLabel: searching
                                                          ? null
                                                          : _emptyActionLabel,
                                                      onAction: searching
                                                          ? null
                                                          : _emptyAction,
                                                      actionIcon: searching
                                                          ? Icons.add
                                                          : _emptyActionIcon,
                                                      showBrandMark:
                                                          !searching &&
                                                          _selection.view ==
                                                              NoteView.notes,
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
                                                      gridMaxWidth,
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
                                                        gridMaxWidth,
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
                                                  // Phones need clearance for
                                                  // their overlaid FAB stack.
                                                  // Desktop keeps only the
                                                  // ordinary bottom gutter; the
                                                  // inline composer is primary
                                                  // there, and a permanent
                                                  // 200px tail made short grids
                                                  // scroll for no visible
                                                  // reason. Fill unused space
                                                  // without extending it.
                                                  SliverFillRemaining(
                                                    hasScrollBody: false,
                                                    child: SizedBox(
                                                      height: width < 600
                                                          ? 200
                                                          : 16,
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                                    ),
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

  IconData get _emptyIcon => switch (_selection.view) {
    NoteView.notes => Icons.sticky_note_2_outlined,
    NoteView.board => Icons.view_kanban_outlined,
    NoteView.reminders => Icons.notifications_outlined,
    NoteView.archive => Icons.archive_outlined,
    NoteView.trash => Icons.delete_outline,
    NoteView.label => Icons.label_outline,
    NoteView.smart => Icons.filter_alt_outlined,
  };

  String get _emptyMessage => switch (_selection.view) {
    NoteView.notes => 'Notes you add appear here',
    NoteView.board => 'Notes you add appear here',
    NoteView.reminders => 'Notes with reminders appear here',
    NoteView.archive => 'Your archived notes appear here',
    NoteView.trash => 'No notes in Trash',
    NoteView.label => 'No notes with this label yet',
    NoteView.smart => 'No notes match this smart view',
  };

  String get _emptyActionLabel => switch (_selection.view) {
    NoteView.notes ||
    NoteView.board ||
    NoteView.reminders ||
    NoteView.label => 'Create note',
    // A smart view is a query, so the way out of an empty one is to go and
    // look at the notes, not to write a note that probably won't match it.
    NoteView.smart || NoteView.archive || NoteView.trash => 'Browse notes',
  };

  VoidCallback get _emptyAction => switch (_selection.view) {
    NoteView.notes ||
    NoteView.board ||
    NoteView.reminders ||
    NoteView.label => () => _newNote(NoteKind.text),
    NoteView.smart || NoteView.archive || NoteView.trash => () => _selectView(
      _primaryView(context.read<NotesStore>()),
    ),
  };

  IconData get _emptyActionIcon => switch (_selection.view) {
    NoteView.notes ||
    NoteView.board ||
    NoteView.reminders ||
    NoteView.label => Icons.add,
    NoteView.smart ||
    NoteView.archive ||
    NoteView.trash => Icons.sticky_note_2_outlined,
  };

  /// Wrap a header-like widget (section label, view header) so its edges line
  /// up with the grid's cards: same outer [pad] and same [gridMaxWidth] cap,
  /// centered the same way, so it tracks the grid's left edge whether the grid
  /// fills the area or sits centered within a narrower band.
  Widget _alignedToGrid(Widget child, double pad, double gridMaxWidth) {
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      sliver: SliverToBoxAdapter(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: gridMaxWidth),
            // Fill the capped width (unlike the grid's masonry, a bare Text
            // would shrink to its content and then get centered), so the child
            // left-aligns to the grid's left edge.
            child: SizedBox(width: double.infinity, child: child),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(
    BuildContext context,
    String text,
    double pad,
    double gridMaxWidth,
  ) {
    return _alignedToGrid(
      Padding(
        // 8px inset from the card's left edge, matching the view header.
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            letterSpacing: 1.2,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      pad,
      gridMaxWidth,
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
    final query = _highlightQuery;
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
              onStationaryLongPress: (id) =>
                  _toggleNoteSelection(id, !_selectedNoteIds.contains(id)),
              itemBuilder: (context, note) => NoteTile(
                key: ValueKey(note.id),
                note: note,
                query: query,
                selectionMode: _selectionMode,
                selected: _selectedNoteIds.contains(note.id),
                onSelectionChanged: (selected) =>
                    _toggleNoteSelection(note.id, selected),
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
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      // 8px inset aligns the title with the grid's cards (see _alignedToGrid).
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
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
        borderRadius: BorderRadius.circular(kRadius),
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
