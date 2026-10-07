import '../models/collection.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../api/api_client.dart';
import '../models/dropped_file.dart';
import '../models/note.dart';
import '../models/workspace.dart';
import '../util/backup.dart';
import '../util/connectivity.dart';
import '../util/keep_import.dart';
import 'bulk_import.dart';
import 'checklist_tree.dart';
import 'local_cache.dart';
import '../models/saved_view.dart';
import 'note_collection.dart';
import 'notes_cache_doc.dart';
import 'note_conversion.dart';
import 'note_links.dart';
import 'pending_operation.dart';
import 'pending_operation_executor.dart';
import 'sparse_position.dart';
import 'sync_issue.dart';
import 'sync_retry_policy.dart';
import 'workspace_reconciliation.dart';

export 'note_collection.dart'
    show NoteSections, NoteView, SortMode, ViewSelection, WorkspaceScope;
export 'sync_issue.dart';

/// Coarse connectivity/sync state surfaced on the top-bar avatar.
///
/// [connecting] and [syncing] both spin: the difference is whether we are still
/// establishing that the server is there, or already talking to it.
enum SyncStatus { synced, syncing, connecting, offline, failed }

/// Optimistic-first store: every mutation updates local state immediately and
/// is synced to the backend through a serial queue that retries on network
/// failure, so the UI never waits on the wire. A WebSocket subscription pulls
/// in changes made by collaborators (or other devices) as they happen.
class NotesStore extends ChangeNotifier {
  final Api api;

  /// Persists notes + the pending sync queue locally so unsynced edits survive
  /// a reload and the app opens instantly, even offline. Defaults to an
  /// in-memory cache (tests); the app injects [PrefsLocalCache].
  final LocalCache cache;

  /// The signed-in user; used to scope trash and owner-only actions.
  final String? currentUserId;

  /// Stable identity of the backend this store is connected to. A user id is
  /// unique only inside one server, so durable notes and pending writes must
  /// be partitioned by both values.
  final String cacheNamespace;

  /// Whether an old user-only cache may be claimed by this server. Set only
  /// while restoring a token that was saved alongside the active server; a
  /// fresh login on another server must never migrate another server's data.
  final bool migrateLegacyCache;

  /// Invoked when whatever else the account keeps on the server may have
  /// moved: a push event on the socket, and the outage recovery where such an
  /// event would have been missed. Siblings that own the rest of the account
  /// (the settings store, which holds saved places and the reminders pinned to
  /// them) re-pull from here, so they never sit on a document older than the
  /// notes beside them.
  ///
  /// A resume is the third such moment, and the app drives that one itself:
  /// it has to await the re-pull before re-arming alarms and geofences from
  /// what it fetched.
  final VoidCallback? onRemoteChange;

  static const _uuid = Uuid();

  List<Note> _notes = [];
  // The editor writes optimistically, but its card keeps the version that was
  // visible when editing began until the editor closes. Null hides a new draft.
  final Map<String, Note?> _editingCards = {};
  List<Note> _displayNotesCache = const [];
  List<Note> _workspaceDisplayCache = const [];
  List<Label> _labels = [];
  List<Stage> _stages = [];
  List<Workspace> _workspaces = [];

  /// The workspace the UI is showing. Null until the first load resolves one
  /// (the cached choice, or the default workspace).
  String? _activeWorkspaceId;

  final Map<String, String> _collectionChoices = {};
  List<NoteCollection> get collections =>
      activeWorkspace?.collections ?? const [];
  NoteCollection? get activeCollection {
    final id = _collectionChoices[_activeWorkspaceId];
    for (final c in collections) {
      if (c.id == id) {
        return c;
      }
    }
    return collections.isEmpty ? null : collections.first;
  }

  void selectCollection(String id) {
    if (!collections.any((c) => c.id == id)) {
      return;
    }
    _collectionChoices[_activeWorkspaceId!] = id;
    notifyListeners();
    _persistSoon();
  }

  WorkspaceScope get collectionScope => WorkspaceScope(
    workspaceId: _activeWorkspaceId,
    isDefault: workspaceScope.isDefault,
    known: workspaceScope.known,
    collectionId: activeCollection?.id,
  );

  Future<void> duplicateWorkspace(
    String id,
    String name,
    WorkspaceCopyContent content, {
    bool reminders = false,
  }) async {
    flushForBackground();
    await _drainQueue();
    if (_connectionDown || _queue.isNotEmpty) {
      throw StateError(
        'Connect and finish syncing before duplicating a workspace',
      );
    }
    final copy = await api.duplicateWorkspace(
      id,
      name,
      content,
      reminders: reminders,
    );
    await refresh();
    setActiveWorkspace(copy.id);
  }

  void saveCollection(NoteCollection collection) {
    _collectionSorts.remove(collection.id);
    _workspaces = [
      for (final w in _workspaces)
        if (w.id == collection.workspaceId)
          w.copyWith(
            collections: [
              ...w.collections.where((c) => c.id != collection.id),
              collection,
            ]..sort((a, b) => a.position.compareTo(b.position)),
          )
        else
          w,
    ];
    _enqueue(
      PendingOp(
        PendingOpKind.collectionPut,
        id: collection.id,
        data: collection.toJson(),
      ),
    );
    notifyListeners();
  }

  void moveCollection(String id, int newIndex) {
    final workspace = activeWorkspace;
    if (workspace == null) return;
    final collection = workspace.collections
        .where((c) => c.id == id)
        .firstOrNull;
    if (collection == null) return;
    final others = [
      for (final c in workspace.collections)
        if (c.id != id) c.position,
    ];
    saveCollection(
      NoteCollection(
        id: collection.id,
        workspaceId: collection.workspaceId,
        name: collection.name,
        icon: collection.icon,
        color: collection.color,
        layout: collection.layout,
        sort: collection.sort,
        position: positionAt(others, newIndex, current: collection.position),
      ),
    );
  }

  void deleteCollection(String id) {
    final workspaceId = _workspaces
        .where((w) => w.collections.any((c) => c.id == id))
        .firstOrNull
        ?.id;
    if (workspaceId == null) {
      return;
    }
    _workspaces = [
      for (final w in _workspaces)
        if (w.id == workspaceId)
          w.copyWith(
            collections: w.collections.where((c) => c.id != id).toList(),
          )
        else
          w,
    ];
    _notes = [
      for (final n in _notes)
        if (n.collectionId == id)
          n.copyWith(trashed: true, stageId: null)
        else
          n,
    ];
    _stages.removeWhere((s) => s.collectionId == id);
    _enqueue(
      PendingOp(
        PendingOpKind.collectionDelete,
        id: id,
        data: {'workspaceId': workspaceId},
      ),
    );
    notifyListeners();
  }

  void moveToCollection(String noteId, String collectionId) {
    final note = noteById(noteId);
    if (note == null ||
        !(workspaceById(
              note.workspaceId,
            )?.collections.any((c) => c.id == collectionId) ??
            false)) {
      return;
    }
    _patch(noteId, note.copyWith(collectionId: collectionId, stageId: null), {
      'collection_id': collectionId,
      'stage_id': null,
    });
  }

  /// The last drawer/sidebar destination used in each workspace. This is
  /// device-local navigation state, like [_activeWorkspaceId], rather than a
  /// shared workspace setting.
  final Map<String, ViewSelection> _lastWorkspaceViews = {};

  /// Previously checked item texts, keyed by note id (suggestions are
  /// per-note by design).
  Map<String, List<String>> _checklistHistory = {};
  bool loading = true;

  /// Whether to *tell the user* we can't reach the server. Deliberately lags
  /// [_connectionDown]: see [_markConnectionDown].
  bool offline = false;

  /// The last request out failed. Internal control flow (what may be awaited,
  /// what to retry) reads this; the UI reads [offline].
  bool _connectionDown = false;
  Timer? _offlineConfirmTimer;

  /// The server has answered at least once since launch. Until it has, the
  /// indicator says "connecting" rather than claiming everything is saved,
  /// the notes on screen came from the local cache, not from the server.
  bool _connectedOnce = false;

  /// True while a manual [refresh] is re-pulling from the server. Distinct
  /// from [loading], the first load.
  bool refreshing = false;
  SortMode _sortMode = SortMode.custom;
  final Map<String, SortMode> _collectionSorts = {};
  SortMode get sortMode =>
      _collectionSorts[activeCollection?.id] ??
      (activeCollection == null
          ? _sortMode
          : SortMode.values.firstWhere(
              (v) => v.name == activeCollection?.sort,
              orElse: () => SortMode.custom,
            ));
  set sortMode(SortMode mode) {
    _sortMode = mode;
    if (activeCollection case final c?) {
      _collectionSorts[c.id] = mode;
    }
  }

  final List<PendingOp> _queue = [];
  final List<SyncIssue> _syncIssues = [];
  final Map<String, String> _serverUpdatedAt = {};
  String? cacheFailure;
  List<SyncIssue> get syncIssues => List.unmodifiable(_syncIssues);
  int get pendingChanges => _queue.length + _saveDebounce.length;
  late final PendingOperationExecutor _pendingOperations;
  bool _flushing = false;
  Timer? _retryTimer;
  final Map<String, Timer> _saveDebounce = {};

  /// The local cache is loaded exactly once, at the first [load]. Until then we
  /// must not persist (that would clobber the on-disk copy with empty state).
  bool _hydrated = false;
  bool _persistDirty = false;
  bool _persisting = false;

  /// Notes created locally that have not been sent to the server yet.
  final Set<String> _drafts = {};

  /// Notes currently being transformed by the optional AI writing service.
  /// A rewrite is not optimistic, so the UI uses this to provide feedback and
  /// prevent the same note from being submitted twice.
  final Set<String> _rewritingNoteIds = {};

  StreamSubscription<void>? _syncSub;
  StreamSubscription<void>? _onlineSub;
  Timer? _syncReloadDebounce;
  Timer? _connectionProbeTimer;
  bool _checkingConnection = false;
  bool _reloadPending = false;
  bool _restoringBackup = false;
  bool _disposed = false;

  /// Increments whenever a local write enters the queue. A remote fetch that
  /// started before this revision changed must never replace optimistic state,
  /// even if the write drains before the response is applied.
  int _localWriteRevision = 0;

  /// Orders overlapping server snapshots. A later load/refresh invalidates
  /// every earlier multi-request snapshot before it can replace local state.
  int _fetchGeneration = 0;

  static const _connectionProbeInterval = Duration(seconds: 2);

  static const _defaultOfflineGrace = Duration(seconds: 5);

  /// How long a connection failure has to persist before the UI says so. A
  /// phone waking from sleep routinely drops the first request or two while
  /// its radio comes back, and being told the server is unreachable, a
  /// second before it plainly is reachable, is worse than saying nothing.
  /// Tests shorten it.
  final Duration offlineGrace;

  NotesStore({
    required this.api,
    LocalCache? cache,
    this.currentUserId,
    this.cacheNamespace = '',
    this.migrateLegacyCache = false,
    this.onRemoteChange,
    this.offlineGrace = _defaultOfflineGrace,
  }) : cache = cache ?? MemoryLocalCache() {
    _pendingOperations = PendingOperationExecutor(
      api: api,
      noteById: noteById,
      serverUpdatedAt: _serverUpdatedAt,
    );
  }

  /// Labels of the open workspace. Labels are a workspace's shared taxonomy,
  /// so switching workspaces switches the whole sidebar.
  List<Label> get labels => labelsInWorkspace(_activeWorkspaceId);

  /// Labels filed in [workspaceId], for screens that name a workspace instead
  /// of following the open one.
  List<Label> labelsInWorkspace(String? workspaceId) {
    final scope = scopeFor(workspaceId);
    return List.unmodifiable([
      for (final label in _labels)
        if (scope.containsWorkspace(label.workspaceId)) label,
    ]);
  }

  /// Board columns of the open workspace, left to right. Like [labels] these
  /// are workspace state, but an independent one: a note has any number of
  /// labels and at most one stage.
  List<Stage> get stages => stagesInWorkspace(_activeWorkspaceId)
      .where(
        (s) =>
            (s.collectionId ?? NoteCollection.generalId(s.workspaceId)) ==
            activeCollection?.id,
      )
      .toList();

  /// Board columns of [workspaceId], left to right.
  List<Stage> stagesInWorkspace(String? workspaceId) {
    final scope = scopeFor(workspaceId);
    return List.unmodifiable([
      for (final stage in _stages)
        if (scope.containsWorkspace(stage.workspaceId)) stage,
    ]);
  }

  /// Column choices follow the note even when opened from workspace trash or archive.
  List<Stage> stagesForNote(Note? note) {
    if (note == null) return const [];
    final workspaceId = _effectiveWorkspaceId(note);
    return stagesInWorkspace(workspaceId)
        .where(
          (s) =>
              (s.collectionId ?? NoteCollection.generalId(workspaceId)) ==
              (note.collectionId ?? NoteCollection.generalId(workspaceId)),
        )
        .toList();
  }

  Stage? stageById(String? id) {
    for (final stage in _stages) {
      if (stage.id == id) return stage;
    }
    return null;
  }

  /// Every workspace the user belongs to, default first.
  List<Workspace> get workspaces => List.unmodifiable(_workspaces);

  String? get activeWorkspaceId => _activeWorkspaceId;

  Workspace? get activeWorkspace => workspaceById(_activeWorkspaceId);

  Workspace? workspaceById(String? id) {
    for (final workspace in _workspaces) {
      if (workspace.id == id) return workspace;
    }
    return null;
  }

  /// Whether closing [id]'s editor may silently remove it.
  ///
  /// Untouched local drafts are still transient, even when composed while a
  /// shared workspace is open. Once a note exists on the server, workspace
  /// members count as sharing just like direct collaborators do.
  bool canAutoDiscard(String id) {
    final note = noteById(id);
    if (note == null || !note.canAutoDiscard) return false;
    if (_drafts.contains(id)) return true;
    final workspace = workspaceById(_effectiveWorkspaceId(note));
    return !(workspace?.isShared ?? false);
  }

  Workspace? get defaultWorkspace {
    for (final workspace in _workspaces) {
      if (workspace.isDefault) return workspace;
    }
    return _workspaces.isEmpty ? null : _workspaces.first;
  }

  /// How the home screen narrows notes to the open workspace.
  WorkspaceScope get workspaceScope => scopeFor(_activeWorkspaceId);

  /// How any one workspace narrows the content this device holds. The rule is
  /// the same wherever it is applied, which is what keeps a workspace's own
  /// screens counting exactly what its grid shows, the default workspace's
  /// catch-all for directly shared notes included.
  WorkspaceScope scopeFor(String? workspaceId) => WorkspaceScope(
    workspaceId: workspaceId,
    isDefault: workspaceId != null && workspaceId == defaultWorkspace?.id,
    known: {for (final workspace in _workspaces) workspace.id},
  );

  /// Notes in the open workspace, whatever their view, used by the pickers
  /// and counts that must agree with what the grid shows.
  List<Note> get notesInActiveWorkspace => notesInWorkspace(_activeWorkspaceId);

  List<Note> get displayNotesInActiveWorkspace {
    final scope = workspaceScope;
    final notes = [
      for (final note in _displayNotes)
        if (scope.contains(note)) note,
    ];
    if (listEquals(notes, _workspaceDisplayCache)) {
      return _workspaceDisplayCache;
    }
    return _workspaceDisplayCache = List.unmodifiable(notes);
  }

  List<Note> get _displayNotes {
    final notes = [
      for (final note in _notes)
        if (!_editingCards.containsKey(note.id) ||
            _editingCards[note.id] != null)
          _editingCards[note.id] ?? note,
    ];
    if (listEquals(notes, _displayNotesCache)) return _displayNotesCache;
    return _displayNotesCache = List.unmodifiable(notes);
  }

  Note? displayNoteById(String id) =>
      _editingCards.containsKey(id) ? _editingCards[id] : noteById(id);

  void beginEditing(String id, {bool newNote = false}) {
    if (_editingCards.containsKey(id)) return;
    _editingCards[id] = newNote ? null : noteById(id);
  }

  void endEditing(String id) {
    if (!_editingCards.containsKey(id)) return;
    _editingCards.remove(id);
    notifyListeners();
  }

  /// Notes filed in [workspaceId], whatever their view, trash included.
  List<Note> notesInWorkspace(String? workspaceId) {
    final scope = scopeFor(workspaceId);
    return [
      for (final note in _notes)
        if (scope.contains(note)) note,
    ];
  }

  void setActiveWorkspace(String id) {
    if (_activeWorkspaceId == id || workspaceById(id) == null) return;
    _activeWorkspaceId = id;
    notifyListeners();
    _persistNow();
  }

  ViewSelection? lastWorkspaceView(String? workspaceId) =>
      workspaceId == null ? null : _lastWorkspaceViews[workspaceId];

  void rememberWorkspaceView(ViewSelection selection) {
    final workspaceId = _activeWorkspaceId;
    if (workspaceId == null || _lastWorkspaceViews[workspaceId] == selection) {
      return;
    }
    _lastWorkspaceViews[workspaceId] = selection;
    _persistNow();
  }

  /// Point at a workspace that still exists: the cached choice when it is
  /// still ours, otherwise the default one. Called after every fetch, so a
  /// workspace deleted (or left) on another device can't strand the view.
  void _reconcileActiveWorkspace() {
    if (_workspaces.isEmpty) return;
    if (workspaceById(_activeWorkspaceId) != null) return;
    _activeWorkspaceId = defaultWorkspace?.id;
  }

  /// Workspaces this account owns. Backups and readable exports deliberately
  /// exclude workspaces that were merely shared with this user.
  List<Workspace> get ownedWorkspaces => List.unmodifiable([
    for (final workspace in _workspaces)
      if (workspace.isOwnedBy(currentUserId)) workspace,
  ]);

  Set<String> get _ownedWorkspaceIds => {
    for (final workspace in ownedWorkspaces) workspace.id,
  };

  String _effectiveWorkspaceId(Note note) =>
      note.workspaceId.isEmpty ? defaultWorkspace?.id ?? '' : note.workspaceId;

  /// Notes carrying a reminder, across every workspace. Deliberately not
  /// workspace-scoped: which workspace happens to be open must not decide
  /// whether an alarm fires. Consumed by `ReminderScheduler`.
  List<Note> get notesWithReminders => [
    for (final note in _notes)
      if (note.hasReminder) note,
  ];

  /// Notes that may be put on the home screen.
  ///
  /// Every note this device holds, workspace ownership included rather than
  /// filtered: a list shared with you (the household groceries) is exactly what
  /// a widget is for. Trashed notes are dropped by the payload builder, which
  /// also owns the ordering and the caps.
  List<Note> get notesForWidgets => List.unmodifiable(_notes);

  /// Non-trashed notes in every owned workspace, in workspace/grid order.
  List<Note> get notesForExport {
    final owned = _ownedWorkspaceIds;
    return [
      for (final note in _notes)
        if (!note.trashed && owned.contains(_effectiveWorkspaceId(note))) note,
    ]..sort((a, b) {
      final byWorkspace = _effectiveWorkspaceId(
        a,
      ).compareTo(_effectiveWorkspaceId(b));
      return byWorkspace != 0 ? byWorkspace : a.position.compareTo(b.position);
    });
  }

  /// Complete backup inputs. Unlike the readable formats, trash is included.
  List<Note> get notesForBackup {
    final owned = _ownedWorkspaceIds;
    return [
      for (final note in _notes)
        if (owned.contains(_effectiveWorkspaceId(note)))
          note.workspaceId.isEmpty
              ? note.copyWith(workspaceId: defaultWorkspace?.id ?? '')
              : note,
    ];
  }

  List<Label> get labelsForBackup {
    final owned = _ownedWorkspaceIds;
    return [
      for (final label in _labels)
        if (owned.contains(label.workspaceId)) label,
    ];
  }

  List<Stage> get stagesForBackup {
    final owned = _ownedWorkspaceIds;
    return [
      for (final stage in _stages)
        if (owned.contains(stage.workspaceId)) stage,
    ];
  }

  /// Replace this account's owned workspace data with selected workspaces from
  /// a validated backup. Workspaces owned by someone else are untouched.
  ///
  /// Direct, awaited calls keep progress truthful. The operation is
  /// intentionally rejected while offline because replacement cannot be
  /// represented safely by the optimistic queue.
  Future<BackupRestoreResult> restoreBackup(
    BackupBundle bundle, {
    Set<String>? workspaceIds,
    BackupProgress? onProgress,
  }) async {
    final selected = [
      for (final workspace in bundle.workspaces)
        if (workspaceIds?.contains(workspace.id) ?? true) workspace,
    ];
    if (selected.isEmpty) {
      throw const BackupRestoreException(
        'Choose at least one workspace to restore',
        restoredNotes: 0,
      );
    }

    return _bulkWrite('Connect to the server before restoring a backup', () {
      final owned = ownedWorkspaces;
      final ownedIds = {for (final workspace in owned) workspace.id};
      final defaultId = defaultWorkspace?.id;
      final replacing = RestoreReplacement(
        notes: [
          for (final note in _notes)
            if (ownedIds.contains(_effectiveWorkspaceId(note)) &&
                note.isOwnedBy(currentUserId))
              note,
        ],
        defaultWorkspace: defaultWorkspace,
        defaultLabels: [
          for (final label in _labels)
            if (label.workspaceId == defaultId) label,
        ],
        defaultStages: [
          for (final stage in _stages)
            if (stage.workspaceId == defaultId) stage,
        ],
        otherWorkspaces: [
          for (final workspace in owned)
            if (!workspace.isDefault) workspace,
        ],
      );
      return BulkImporter(
        api,
        currentUserId,
      ).restoreBackup(selected, replacing, onProgress: onProgress);
    });
  }

  /// Add the notes of a Google Keep export to [collectionId] in [workspaceId],
  /// beside what is already there. A label is matched to the workspace's by
  /// name, ignoring case, and created when it has none.
  ///
  /// Direct, awaited calls like [restoreBackup], for truthful progress; it is
  /// likewise refused while offline.
  Future<KeepImportResult> importKeep(
    KeepArchive archive, {
    required String workspaceId,
    required String collectionId,
    KeepTrash trash = KeepTrash.skip,
    BackupProgress? onProgress,
  }) => _bulkWrite(
    'Connect to the server before importing',
    () => BulkImporter(api, currentUserId).importKeep(
      archive,
      workspaceId: workspaceId,
      collectionId: collectionId,
      existingLabels: labelsInWorkspace(workspaceId),
      frontPosition: _frontPosition(),
      trash: trash,
      onProgress: onProgress,
    ),
  );

  /// Run a restore or import once every queued write has reached the server,
  /// then re-pull what it wrote. Refused while offline: replacing data cannot
  /// be represented by the optimistic queue.
  Future<T> _bulkWrite<T>(
    String offlineMessage,
    Future<T> Function() write,
  ) async {
    flushForBackground();
    await _drainQueue();
    if (_connectionDown || _queue.isNotEmpty) {
      throw BackupRestoreException(offlineMessage, restoredNotes: 0);
    }

    _restoringBackup = true;
    notifyListeners();
    try {
      return await write();
    } finally {
      _restoringBackup = false;
      await refresh();
      notifyListeners();
      if (_reloadPending) {
        _reloadPending = false;
        load();
      }
    }
  }

  Note? noteById(String id) {
    for (final n in _notes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// Current title of a linked note; null when it is not reachable here, so
  /// the title stored in the link shows instead.
  String? linkTitleFor(String id) {
    final note = noteById(id);
    if (note == null || note.trashed) {
      return null;
    }
    return noteLinkTitle(note);
  }

  /// Notes linking to note [id].
  List<Note> backlinks(String id) => backlinksTo(id, _notes);

  /// Notes a link being typed as `[[query` could point at.
  List<Note> linkTargets(String query, {String? excludeId}) =>
      linkCandidates(_notes, query, excludeId: excludeId);

  Label? labelById(String id) {
    for (final l in _labels) {
      if (l.id == id) return l;
    }
    return null;
  }

  bool isDraft(String id) => _drafts.contains(id);

  bool get _hasLocalChangesInFlight =>
      _queue.isNotEmpty ||
      _drafts.isNotEmpty ||
      _saveDebounce.isNotEmpty ||
      _restoringBackup;

  /// Whether there are local edits not yet acknowledged by the server.
  bool get hasPendingWork => _hasLocalChangesInFlight;

  /// Still trying to reach the server: either it has never answered this
  /// session (a cold start renders from cache long before the first request
  /// resolves) or a request just failed and the outage hasn't yet outlasted
  /// [offlineGrace]. This is what keeps the indicator spinning between "opened
  /// the app" and a verdict either way.
  bool get _connecting =>
      !_connectedOnce || _connectionDown || loading || refreshing;

  /// Coarse connectivity/sync state for the UI indicator. A confirmed outage
  /// wins (nothing can sync at all); reaching the server comes next, since
  /// until that lands we can't honestly claim local work is being pushed; then
  /// pending local work; else everything is saved on the server.
  SyncStatus get syncStatus => switch (this) {
    _ when _syncIssues.isNotEmpty || cacheFailure != null => SyncStatus.failed,
    _ when offline => SyncStatus.offline,
    _ when _connecting => SyncStatus.connecting,
    _ when _hasLocalChangesInFlight => SyncStatus.syncing,
    _ => SyncStatus.synced,
  };

  /// A request failed. The failure is recorded right away for the retry
  /// machinery, but only surfaces to the user once it has lasted
  /// [offlineGrace], a blip that the next probe recovers from never shows.
  void _markConnectionDown() {
    if (_connectionDown) return;
    _connectionDown = true;
    _offlineConfirmTimer?.cancel();
    _offlineConfirmTimer = Timer(offlineGrace, () {
      _offlineConfirmTimer = null;
      if (!_connectionDown || offline) return;
      offline = true;
      notifyListeners();
    });
  }

  /// A request succeeded. Returns whether that changed anything the UI shows,
  /// so callers can skip a redundant notification.
  bool _markConnectionUp() {
    _offlineConfirmTimer?.cancel();
    _offlineConfirmTimer = null;
    // Reaching the server ends the connecting phase as well as any outage, and
    // both of those are visible on the indicator.
    final changed = _connectionDown || !_connectedOnce || offline;
    _connectionDown = false;
    _connectedOnce = true;
    offline = false;
    return changed;
  }

  /// The app came back to the foreground. Everything it thought it knew about
  /// the network is stale, a suspended app's socket is dead, its timers were
  /// frozen, and the phone may have changed networks entirely, so drop any
  /// offline verdict rather than greeting the user with a complaint about a
  /// connection nothing has tested since. Then pull: the change socket was
  /// down while we were away, so anything edited elsewhere is still missing.
  Future<void> onResumed() async {
    _offlineConfirmTimer?.cancel();
    _offlineConfirmTimer = null;
    _connectionDown = false;
    if (offline) {
      offline = false;
      notifyListeners();
    }
    await refresh();
  }

  Future<void> load() async {
    if (_disposed) return;
    final generation = ++_fetchGeneration;
    bool isCurrent() => !_disposed && generation == _fetchGeneration;
    await _hydrate();
    if (!isCurrent()) return;
    var fetchAgain = false;
    do {
      fetchAgain = false;
      final startedWithLocalChanges = _hasLocalChangesInFlight;
      final revisionAtStart = _localWriteRevision;
      try {
        final (workspaces, notes, labels, stages, history) = await (
          api.fetchWorkspaces(),
          api.fetchNotes(),
          api.fetchLabels(),
          api.fetchStages(),
          api.fetchChecklistHistory(),
        ).wait;
        if (!isCurrent()) return;
        final writesChangedDuringFetch = revisionAtStart != _localWriteRevision;
        // A write can enter and leave the queue entirely while these requests
        // are in flight. Checking only the queue at the end would then apply a
        // stale pre-write snapshot over the optimistic checklist edit.
        if (!startedWithLocalChanges &&
            !writesChangedDuringFetch &&
            !_hasLocalChangesInFlight) {
          _serverUpdatedAt
            ..clear()
            ..addEntries(
              notes.map(
                (n) => MapEntry(n.id, n.updatedAt.toUtc().toIso8601String()),
              ),
            );
          _notes = notes..sort((a, b) => a.position.compareTo(b.position));
          _labels = labels;
          _stages = stages;
          _workspaces = workspaces;
          _reconcileActiveWorkspace();
          _checklistHistory = history;
          _reloadPending = false;
        } else if (_hasLocalChangesInFlight) {
          _reloadPending = true;
        } else {
          // The writes drained while fetching. Pull once more now so this load
          // completes with the server's post-write state.
          _reloadPending = false;
          fetchAgain = true;
        }
        _markConnectionUp();
      } catch (_) {
        if (!isCurrent()) return;
        _markConnectionDown();
        _retryTimer?.cancel();
        _retryTimer = Timer(const Duration(seconds: 5), load);
      }
    } while (fetchAgain);
    if (!isCurrent()) return;
    loading = false;
    notifyListeners();
  }

  /// A user-triggered re-pull (pull-to-refresh). Unlike [load] it
  /// doesn't re-hydrate the cache or flip [loading], and it first drains any
  /// pending writes so the refetch reflects them. Skips clobbering when local
  /// changes are still in flight, matching [load].
  Future<void> refresh() async {
    if (_disposed || refreshing) {
      return;
    }
    refreshing = true;
    notifyListeners();
    for (final id in _saveDebounce.keys.toList()) {
      _saveDebounce.remove(id)?.cancel();
      _enqueueContentPatch(id);
    }
    if (_queue.isNotEmpty) {
      _flush();
    }
    try {
      // One snapshot path owns generation and write-revision checks. Manual
      // refresh must reject a pre-edit snapshot just like live sync does.
      await load();
    } finally {
      refreshing = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  // ---------------------------------------------------------------------
  // Local persistence (offline cache)

  String get _legacyCacheKey => notesCacheKey('', currentUserId);

  String get _cacheKey => notesCacheKey(cacheNamespace, currentUserId);

  /// Load the on-disk snapshot so notes render instantly, before, and even
  /// without, a network round-trip. Runs once; the network fetch in [load]
  /// then reconciles (local unsynced edits win). Persisted pending writes are
  /// replayed right away.
  Future<void> _hydrate() async {
    if (_hydrated) return;
    try {
      var doc = await cache.read(_cacheKey);
      if (doc == null && migrateLegacyCache && _cacheKey != _legacyCacheKey) {
        doc = await cache.read(_legacyCacheKey);
        if (doc != null) {
          await cache.write(_cacheKey, doc);
          await cache.clear(_legacyCacheKey);
        }
      }
      if (doc == null && !migrateLegacyCache && _cacheKey != _legacyCacheKey) {
        // A fresh login cannot prove which server created the old user-only
        // cache. Claim this server's namespace with an empty marker now, so a
        // later restored launch cannot reinterpret another server's pending
        // writes as its own.
        doc = const NotesCacheDoc().toJson();
        await cache.write(_cacheKey, doc);
      }
      if (doc != null) {
        final cached = NotesCacheDoc.fromJson(doc);
        _notes = [...cached.notes]
          ..sort((a, b) => a.position.compareTo(b.position));
        _labels = [...cached.labels]..sort(_byLabelPosition);
        _stages = [...cached.stages]
          ..sort((a, b) => a.position.compareTo(b.position));
        _workspaces = [...cached.workspaces];
        _activeWorkspaceId = cached.activeWorkspaceId;
        _collectionChoices.addAll(cached.collectionChoices);
        _reconcileActiveWorkspace();
        _lastWorkspaceViews
          ..clear()
          ..addAll(cached.workspaceViews);
        _checklistHistory = {...cached.checklistHistory};
        _queue
          ..clear()
          ..addAll(cached.queue);
        _syncIssues
          ..clear()
          ..addAll(cached.syncIssues);
        _serverUpdatedAt.addAll(cached.serverUpdatedAt);
      }
    } catch (_) {
      // Corrupt/unreadable cache: start empty rather than fail to open.
    }
    _hydrated = true;
    if (_notes.isNotEmpty ||
        _labels.isNotEmpty ||
        _stages.isNotEmpty ||
        _workspaces.isNotEmpty) {
      loading = false;
      notifyListeners();
    }
    if (_queue.isNotEmpty) _flush();
  }

  /// Snapshot of everything worth keeping across launches. Empty drafts (a note
  /// just started, no content yet) are transient and left out.
  NotesCacheDoc _toCacheDoc() => NotesCacheDoc(
    notes: [
      for (final n in _notes)
        if (!(_drafts.contains(n.id) && canAutoDiscard(n.id))) n,
    ],
    labels: _labels,
    stages: _stages,
    workspaces: _workspaces,
    activeWorkspaceId: _activeWorkspaceId,
    collectionChoices: _collectionChoices,
    workspaceViews: _lastWorkspaceViews,
    checklistHistory: _checklistHistory,
    queue: [
      ..._queue,
      // A content edit made in the last <400ms before a reload hasn't been
      // enqueued yet (it's mid-debounce); fold those pending saves in so
      // nothing is lost.
      for (final id in _saveDebounce.keys)
        if (noteById(id) case final note?) _contentPatchOp(id, note),
    ],
    syncIssues: _syncIssues,
    serverUpdatedAt: _serverUpdatedAt,
  );

  /// Rate-limited persistence for plain state changes: encoding the whole
  /// corpus (and, on web, a synchronous localStorage write) on every notify
  /// is the single biggest UI-thread cost during typing and animations, so
  /// cap it at one write per second. A skipped write is never lost for
  /// long: anything durable (an edit, a toggle, a reorder) enqueues a
  /// server op within 400ms, and queue changes persist immediately via
  /// [_persistNow]; only server-refetch snapshots can stay stale, and those
  /// are refetched on the next launch anyway.
  DateTime _lastPersist = DateTime.fromMillisecondsSinceEpoch(0);

  void _persistSoon() {
    if (DateTime.now().difference(_lastPersist) < const Duration(seconds: 1)) {
      return;
    }
    _persistNow();
  }

  /// Coalesced, one-writer-at-a-time persistence. Uses a microtask (not a
  /// timer) so it runs promptly after each change without leaking test
  /// timers.
  void _persistNow() {
    if (_disposed || !_hydrated) return;
    _lastPersist = DateTime.now();
    _persistDirty = true;
    if (_persisting) return;
    _persisting = true;
    scheduleMicrotask(_persistLoop);
  }

  Future<void> _persistLoop() async {
    while (_persistDirty) {
      _persistDirty = false;
      try {
        await cache.write(_cacheKey, _toCacheDoc().toJson());
        if (cacheFailure != null) {
          cacheFailure = null;
          if (!_disposed) super.notifyListeners();
        }
      } catch (error) {
        cacheFailure = error.toString();
        if (!_disposed) super.notifyListeners();
      }
    }
    _persisting = false;
  }

  void retryCacheWrite() => _persistNow();

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
    _persistSoon();
  }

  /// Live sync: any server-side change to this user's notes triggers a
  /// debounced refetch (skipped while our own edits are still in flight).
  void startSync() {
    if (_disposed) return;
    _syncSub?.cancel();
    _syncSub = api.changeEvents().listen((_) {
      _syncReloadDebounce?.cancel();
      _syncReloadDebounce = Timer(const Duration(milliseconds: 350), () {
        onRemoteChange?.call();
        if (_hasLocalChangesInFlight) {
          _reloadPending = true;
        } else {
          load();
        }
      });
    });
    // The browser fires 'online' the instant connectivity returns; flush the
    // pending queue right away instead of waiting for the 5s retry tick.
    _onlineSub?.cancel();
    _onlineSub = onlineEvents().listen((_) {
      if (_connectionDown) retryNow();
    });

    // A quiet WebSocket can take a long time to notice that its TCP connection
    // disappeared. Probe the tiny health endpoint so the status indicator is
    // useful even while the user is only reading notes.
    _connectionProbeTimer?.cancel();
    _connectionProbeTimer = Timer.periodic(
      _connectionProbeInterval,
      (_) => checkConnectionNow(),
    );
    // Probe straight away too. The health endpoint answers (or times out) long
    // before a full note fetch would, so this is what settles "connecting" into
    // connected-or-offline on launch instead of waiting for the first tick.
    checkConnectionNow();
  }

  /// Probe immediately (also exposed for deterministic tests and explicit
  /// lifecycle hooks). The periodic timer above normally drives this.
  Future<void> checkConnectionNow() async {
    if (_disposed || _checkingConnection) return;
    _checkingConnection = true;
    try {
      await api.checkConnection();
      if (_disposed) return;
      final wasDown = _connectionDown;
      if (_markConnectionUp()) notifyListeners();
      // Recovered: push whatever was waiting, whether or not the outage
      // lasted long enough for the user to ever hear about it, and re-pull —
      // a reconnected socket replays nothing it missed while it was gone.
      if (wasDown) {
        onRemoteChange?.call();
        await retryNow();
      }
    } catch (_) {
      if (_disposed) return;
      _markConnectionDown();
    } finally {
      _checkingConnection = false;
    }
  }

  // ---------------------------------------------------------------------
  // Filtering & sorting

  // One cached view: unrelated rebuilds still compare note identities, but
  // avoid parsing, searching and sorting the corpus again. Copy the inputs
  // because mutations also replace entries in the store's lists in place.
  Object? _selectionKey;
  List<Note> _selectionNotes = const [];
  List<Label> _selectionLabels = const [];
  List<Workspace> _selectionWorkspaces = const [];
  NoteSections? _selectionResult;

  NoteSections notesFor(
    ViewSelection selection,
    String query, {
    bool display = false,
  }) {
    final notes = display ? _displayNotes : _notes;
    final key = (
      selection,
      query,
      sortMode,
      _activeWorkspaceId,
      activeCollection?.id,
      display,
    );
    if (_selectionResult != null &&
        key == _selectionKey &&
        listEquals(notes, _selectionNotes) &&
        listEquals(_labels, _selectionLabels) &&
        listEquals(_workspaces, _selectionWorkspaces)) {
      return _selectionResult!;
    }
    final result = selectNotes(
      notes: notes,
      labels: _labels,
      selection: selection,
      query: query,
      sortMode: sortMode,
      currentUserId: currentUserId,
      scope:
          selection.view == NoteView.trash ||
              selection.view == NoteView.archive ||
              selection.view == NoteView.reminders
          ? workspaceScope
          : collectionScope,
    );
    _selectionKey = key;
    _selectionNotes = List.of(notes);
    _selectionLabels = List.of(_labels);
    _selectionWorkspaces = List.of(_workspaces);
    return _selectionResult = NoteSections(
      List.unmodifiable(result.pinned),
      List.unmodifiable(result.others),
    );
  }

  void setSortMode(SortMode mode) {
    sortMode = mode;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Note mutations (all optimistic)

  /// [labelIds] files the note from birth, what a note composed while a label
  /// view is open needs, so it doesn't vanish out of the view it was written
  /// in. They ride along on the create request, so a draft never loses them.
  Note createDraft({
    NoteKind kind = NoteKind.text,
    Set<String> labelIds = const {},
    String? stageId,
  }) {
    final now = DateTime.now();
    final workspaceId = _activeWorkspaceId ?? '';
    // Share-sheet intake and file drops can compose into an empty workspace.
    if (activeWorkspace != null && activeCollection == null) {
      saveCollection(
        NoteCollection(
          id: _uuid.v4(),
          workspaceId: workspaceId,
          name: 'General',
        ),
      );
    }
    final note = Note(
      id: _uuid.v4(),
      workspaceId: workspaceId,
      collectionId: activeCollection?.id,
      kind: kind,
      position: _frontPosition(),
      labelIds: labelIds,
      // A note composed inside a board column belongs to it from birth, the
      // same way one composed in a label view arrives already filed.
      stageId: stageId,
      stagePosition: _endOfStage(stageId, workspaceId),
      createdAt: now,
      updatedAt: now,
      owner: currentUserId == null
          ? null
          : UserRef(id: currentUserId!, name: ''),
    );
    _notes.insert(0, note);
    _drafts.add(note.id);
    notifyListeners();
    return note;
  }

  /// Gap between neighbouring notes placed at the front of the grid.
  static const _frontGap = kPositionGap;

  double _frontPosition() {
    double min = 0;
    for (final n in _notes) {
      if (n.position < min) min = n.position;
    }
    return min - _frontGap;
  }

  /// Debounced content autosave from the editor (title, body, checklist).
  /// [kind] rides along so editor undo can revert a text<->checklist convert.
  ///
  /// Plain typing sets [urgent] false: state updates immediately but the
  /// grid-wide rebuild is throttled, so keystrokes never jank the UI. Discrete
  /// changes (checks, adds, reorders) notify instantly.
  void updateNoteContent(
    String id, {
    NoteKind? kind,
    String? title,
    String? content,
    List<ChecklistItem>? items,
    bool urgent = true,
  }) {
    final note = noteById(id);
    if (note == null) return;
    // Same rule the server applies on write: a row cannot be nested deeper
    // than the one above it allows, so a local edit never shows a shape the
    // next refetch would correct underneath the user.
    final normalized = items == null ? null : normalizeDepths(items);
    final updated = note.copyWith(
      kind: kind,
      title: title,
      content: content,
      items: normalized,
      // An item reminder lives only as long as its unchecked item does. The
      // server prunes in the same write, so this is the local half of one
      // rule: ticking something off silently cancels its alarm instead of
      // leaving it armed until the next refetch.
      itemReminders: normalized == null
          ? null
          : _prunedItemReminders(note, normalized),
      updatedAt: DateTime.now(),
    );
    if (urgent) {
      _replace(updated);
    } else {
      _replaceThrottled(updated);
    }
    if (_drafts.contains(id)) {
      _materializeIfNeeded(id);
    } else {
      _saveDebounce[id]?.cancel();
      _saveDebounce[id] = Timer(const Duration(milliseconds: 400), () {
        _saveDebounce.remove(id);
        _enqueueContentPatch(id);
      });
    }
  }

  void _enqueueContentPatch(String id) {
    final latest = noteById(id);
    if (latest == null) return;
    _enqueue(_contentPatchOp(id, latest));
  }

  /// Runs an explicitly requested AI rewrite after every pending local edit
  /// has reached the server. Unlike normal typing this cannot be optimistic:
  /// the replacement text comes from the configured provider.
  Future<void> rewriteNote(String id, NoteRewriteTask task) async {
    if (!_rewritingNoteIds.add(id)) return;
    notifyListeners();
    try {
      await _pushPending(id);
      final updated = await api.rewriteNote(id, task);
      _serverUpdatedAt[id] = updated.updatedAt.toUtc().toIso8601String();
      if (noteById(id) != null) _replace(updated);
    } finally {
      _rewritingNoteIds.remove(id);
      notifyListeners();
    }
  }

  bool isRewritingNote(String id) => _rewritingNoteIds.contains(id);

  PendingOp _contentPatchOp(String id, Note note) => PendingOp(
    PendingOpKind.patch,
    id: id,
    data: {
      'kind': note.kind.wire,
      'title': note.title,
      'content': note.content,
      'items': Note.itemsToJson(note.items),
    },
  );

  ChecklistItem? _itemById(String noteId, String itemId) {
    final note = noteById(noteId);
    if (note == null) return null;
    for (final item in note.items) {
      if (item.id == itemId) return item;
    }
    return null;
  }

  /// Toggle a checklist box (works from the card without opening the note).
  void toggleChecklistItem(String noteId, String itemId) {
    final item = _itemById(noteId, itemId);
    if (item == null) return;
    setChecklistItemDone(noteId, itemId, !item.done);
  }

  /// Set a checklist box to an absolute state.
  ///
  /// Absolute rather than a flip so replaying a tick made somewhere else (a
  /// home-screen widget, queued while the app was closed) is idempotent: the
  /// same op applied twice, or applied after the server already took it, still
  /// lands on the value the user chose. A no-op when nothing changes, so a
  /// replay costs neither a rebuild nor a redundant patch.
  void setChecklistItemDone(String noteId, String itemId, bool done) {
    final note = noteById(noteId);
    if (note == null) return;
    final current = _itemById(noteId, itemId);
    if (current == null || current.done == done) return;
    // Closing a task closes what is nested under it, and reopening it
    // reopens them: a task is not half-done because its parts are.
    final items = setDoneCascading(note.items, itemId, done);
    // Keep the local suggestion dictionary warm; the server records it too.
    if (done) rememberCheckedText(noteId, current.text);
    updateNoteContent(noteId, items: items);
  }

  void rememberCheckedText(String noteId, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final history = _checklistHistory.putIfAbsent(noteId, () => []);
    if (!history.any((h) => h.toLowerCase() == trimmed.toLowerCase())) {
      _checklistHistory[noteId] = [trimmed, ...history];
    }
  }

  /// Typing suggestions for checklist rows, drawn from items previously
  /// checked off IN THIS NOTE, history never leaks across notes. Prefix
  /// matches rank above substring matches; texts already on the list are
  /// excluded. An empty query suggests the note's whole history, most used
  /// first (the popup scrolls).
  List<String> suggestionsFor(
    String? noteId,
    String query, {
    Set<String> exclude = const {},
  }) {
    final history = noteId == null ? null : _checklistHistory[noteId];
    if (history == null || history.isEmpty) return const [];
    final q = query.trim().toLowerCase();
    final excluded = {for (final e in exclude) e.trim().toLowerCase()};
    final prefix = <String>[];
    final contains = <String>[];
    for (final text in history) {
      final lower = text.toLowerCase();
      if (excluded.contains(lower)) continue;
      if (q.isEmpty || lower.startsWith(q)) {
        prefix.add(text);
      } else if (lower.contains(q)) {
        contains.add(text);
      }
    }
    return [...prefix, ...contains];
  }

  /// Convert a note to [target], mapping content sensibly: lines <-> items,
  /// and markdown task syntax (`- [x] milk`) survives the round trip.
  void convertKind(String id, NoteKind target) {
    final note = noteById(id);
    if (note == null || note.kind == target) return;
    final updated = convertNoteKind(note, target, newItemId: _uuid.v4);
    _replace(updated.copyWith(updatedAt: DateTime.now()));
    if (_drafts.contains(id)) return;
    _enqueue(
      PendingOp(
        PendingOpKind.patch,
        id: id,
        data: {
          'kind': updated.kind.wire,
          'content': updated.content,
          'items': Note.itemsToJson(updated.items),
        },
      ),
    );
  }

  // Keep filing at its queue position: a later move may target a collection,
  // label or column that has not been created when this operation runs.
  PendingOp _createOp(Note note) => PendingOp(
    PendingOpKind.create,
    id: note.id,
    data: {
      'workspace_id': note.workspaceId,
      'collection_id': note.collectionId,
      'stage_id': note.stageId,
      'label_ids': note.labelIds.toList(),
    },
  );

  void _materializeIfNeeded(String id) {
    final note = noteById(id);
    if (note == null || note.canAutoDiscard) return;
    _drafts.remove(id);
    _enqueue(_createOp(note));
  }

  void _replace(Note updated) {
    final i = _notes.indexWhere((n) => n.id == updated.id);
    if (i == -1) return;
    _notes[i] = updated;
    _notifyThrottle?.cancel();
    _notifyThrottle = null;
    notifyListeners();
  }

  Timer? _notifyThrottle;

  /// State mutates now; listeners hear about it within ~200ms. Keeps every
  /// keystroke from rebuilding the whole grid behind the editor.
  void _replaceThrottled(Note updated) {
    final i = _notes.indexWhere((n) => n.id == updated.id);
    if (i == -1) return;
    _notes[i] = updated;
    _notifyThrottle ??= Timer(const Duration(milliseconds: 200), () {
      _notifyThrottle = null;
      notifyListeners();
    });
  }

  void _patch(String id, Note updated, Map<String, dynamic> fields) {
    _replace(updated.copyWith(updatedAt: DateTime.now()));
    // Drafts have no server row yet; local state rides along in the create.
    if (_drafts.contains(id)) return;
    _enqueue(PendingOp(PendingOpKind.patch, id: id, data: fields));
  }

  void togglePin(String id) {
    final note = noteById(id);
    if (note == null) return;
    if (note.archived && !note.pinned) {
      // Pinning an archived note moves it back to Notes.
      _patch(id, note.copyWith(pinned: true, archived: false), {
        'pinned': true,
        'archived': false,
      });
    } else {
      _patch(id, note.copyWith(pinned: !note.pinned), {'pinned': !note.pinned});
    }
  }

  void setColor(String id, String color) {
    final note = noteById(id);
    if (note == null) return;
    _patch(id, note.copyWith(color: color), {'color': color});
  }

  void setGridSpan(String id, int span) {
    final note = noteById(id);
    if (note == null || span == note.gridSpan || span < 1 || span > 3) return;
    _patch(id, note.copyWith(gridSpan: span), {'grid_span': span});
  }

  void setArchived(String id, bool archived) {
    final note = noteById(id);
    if (note == null) return;
    _patch(id, note.copyWith(archived: archived, pinned: false), {
      'archived': archived,
      'pinned': false,
    });
  }

  void setReminder(String id, DateTime? at, [ReminderRepeat? repeat]) {
    final note = noteById(id);
    if (note == null) return;
    _patch(
      id,
      note.copyWith(reminderAt: at, reminderRepeat: at == null ? null : repeat),
      {
        'reminder_at': at?.toUtc().toIso8601String(),
        'reminder_repeat': at == null ? null : repeat?.wire,
      },
    );
    // A reminder makes even a wordless draft durable. Create it immediately
    // so an app suspension before the editor closes cannot leave a cached
    // note with no corresponding server row.
    if (at != null && _drafts.contains(id)) {
      _materializeIfNeeded(id);
    }
  }

  /// Set (or, with a null [at], clear) the reminder on one checklist item.
  ///
  /// Optimistic like every other mutation, and queued as its own operation
  /// rather than folded into the note's content patch: the server keeps item
  /// reminders in a sub-resource so two devices editing two rows of the same
  /// list cannot overwrite each other.
  void setItemReminder(
    String noteId,
    String itemId,
    DateTime? at, [
    ReminderRepeat? repeat,
  ]) {
    final note = noteById(noteId);
    if (note == null) return;
    final item = _itemById(noteId, itemId);
    // The rule the server enforces: only an item that is there and unchecked
    // can carry one. Clearing stays allowed either way, so a row that just
    // went away can still be tidied up.
    if (at != null && (item == null || item.done)) return;
    final reminders = Map<String, ItemReminder>.from(note.itemReminders);
    if (at == null) {
      if (reminders.remove(itemId) == null) return;
    } else {
      reminders[itemId] = ItemReminder(itemId: itemId, at: at, repeat: repeat);
    }
    // Deliberately no updatedAt bump: an alarm moving is not an edit, and the
    // note should not start reading as "Edited just now" because of it.
    _replace(note.copyWith(itemReminders: reminders));
    // A draft has no server row yet; its reminders ride along in the create,
    // which reads the note fresh when it runs.
    if (_drafts.contains(noteId)) {
      _materializeIfNeeded(noteId);
      return;
    }
    // The server judges the reminder against the saved row, so an edit still
    // waiting out its debounce (a row just reopened by Undo) is queued first.
    final pendingSave = _saveDebounce.remove(noteId);
    if (pendingSave != null) {
      pendingSave.cancel();
      _enqueueContentPatch(noteId);
    }
    _enqueue(
      PendingOp(
        PendingOpKind.itemReminder,
        id: noteId,
        data: {
          'itemId': itemId,
          'at': at?.toUtc().toIso8601String(),
          'repeat': at == null ? null : repeat?.wire,
        },
      ),
    );
  }

  /// [note]'s item reminders, keeping only the ones whose item survives
  /// [items] unchecked.
  static Map<String, ItemReminder> _prunedItemReminders(
    Note note,
    List<ChecklistItem> items,
  ) {
    if (note.itemReminders.isEmpty) return note.itemReminders;
    return {
      for (final item in items)
        if (!item.done && note.itemReminders[item.id] != null)
          item.id: note.itemReminders[item.id]!,
    };
  }

  bool canTrash(String id) => noteById(id)?.isOwnedBy(currentUserId) ?? false;

  void moveToTrash(String id) {
    final note = noteById(id);
    if (note == null) return;
    _patch(id, note.copyWith(trashed: true, pinned: false), {
      'trashed': true,
      'pinned': false,
    });
  }

  void restoreFromTrash(String id, {String? collectionId}) {
    final note = noteById(id);
    if (note == null) return;
    _patch(id, note.copyWith(trashed: false, collectionId: collectionId), {
      'trashed': false,
      'collection_id': ?collectionId,
    });
  }

  void deleteForever(String id) {
    _saveDebounce.remove(id)?.cancel();
    _notes.removeWhere((n) => n.id == id);
    final wasDraft = _drafts.remove(id);
    notifyListeners();
    if (!wasDraft) _enqueue(PendingOp(PendingOpKind.delete, id: id));
  }

  void emptyTrash() {
    for (final n
        in _notes
            .where((n) => n.trashed && n.isOwnedBy(currentUserId))
            .toList()) {
      deleteForever(n.id);
    }
  }

  void toggleLabelOnNote(String noteId, String labelId) {
    final note = noteById(noteId);
    if (note == null) return;
    final ids = Set<String>.from(note.labelIds);
    ids.contains(labelId) ? ids.remove(labelId) : ids.add(labelId);
    _replace(note.copyWith(labelIds: ids));
    if (_drafts.contains(noteId)) return;
    _enqueue(
      PendingOp(
        PendingOpKind.patch,
        id: noteId,
        data: {'label_ids': ids.toList()},
      ),
    );
  }

  /// Add [labelId] to a note (used by drag-and-drop onto a sidebar label).
  /// Idempotent: a no-op when the note is already labelled, so dropping twice
  /// never removes the label the way [toggleLabelOnNote] would.
  bool addLabelToNote(String noteId, String labelId) {
    final note = noteById(noteId);
    if (note == null || note.labelIds.contains(labelId)) return false;
    toggleLabelOnNote(noteId, labelId);
    return true;
  }

  /// Persist a drag reorder: renumber the given section locally exactly the
  /// way the server will, so both stay in sync.
  void reorder(List<String> orderedIds) {
    for (var i = 0; i < orderedIds.length; i++) {
      final note = noteById(orderedIds[i]);
      if (note != null) _replace(note.copyWith(position: (i + 1) * 1024.0));
    }
    _notes.sort((a, b) => a.position.compareTo(b.position));
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.reorder,
        data: {'ids': List<String>.from(orderedIds)},
      ),
    );
  }

  /// "Duplicate": clone content into a fresh note at the front of the grid,
  /// and return it so the caller can switch to what it just made.
  /// Attachments and collaborators intentionally stay behind.
  ///
  /// The copy is titled "Copy …" so the two are never confused in the grid;
  /// an untitled note's copy is simply "Copy".
  Note? duplicate(String id) {
    final source = noteById(id);
    if (source == null) return null;
    final now = DateTime.now();
    final copy = Note(
      id: _uuid.v4(),
      workspaceId: source.workspaceId,
      collectionId: source.collectionId,
      kind: source.kind,
      title: copyTitle(source.title),
      content: source.content,
      items: [
        for (final item in source.items)
          ChecklistItem(id: _uuid.v4(), text: item.text, done: item.done),
      ],
      color: source.color,
      position: _frontPosition(),
      gridSpan: source.gridSpan,
      createdAt: now,
      updatedAt: now,
      labelIds: Set<String>.from(source.labelIds),
      owner: source.owner,
    );
    _notes.insert(0, copy);
    _notes.sort((a, b) => a.position.compareTo(b.position));
    notifyListeners();
    _enqueue(_createOp(copy));
    if (copy.labelIds.isNotEmpty) {
      _enqueue(
        PendingOp(
          PendingOpKind.patch,
          id: copy.id,
          data: {'label_ids': copy.labelIds.toList()},
        ),
      );
    }
    return copy;
  }

  /// Flush pending edits when an editor closes. Returns true when the note
  /// was empty and has been discarded.
  bool finalizeNote(String id, {bool retainEmpty = false}) {
    final note = noteById(id);
    if (note == null) return false;
    if (!retainEmpty && canAutoDiscard(id)) {
      deleteForever(id);
      return true;
    }
    if (_drafts.contains(id)) {
      if (retainEmpty) {
        _drafts.remove(id);
        _enqueue(_createOp(note));
      } else {
        _materializeIfNeeded(id);
      }
    } else {
      final timer = _saveDebounce.remove(id);
      if (timer != null) {
        timer.cancel();
        _enqueueContentPatch(id);
      }
    }
    return false;
  }

  /// The app is heading to background: the OS may suspend (or kill) us at
  /// any moment, so stop waiting on debounce timers, enqueue what they were
  /// holding (which persists the queue and starts pushing it) and snapshot
  /// the rest of the state while we still can.
  void flushForBackground() {
    for (final id in _saveDebounce.keys.toList()) {
      _saveDebounce.remove(id)?.cancel();
      _enqueueContentPatch(id);
    }
    _persistNow();
  }

  // ---------------------------------------------------------------------
  // Workspaces

  List<SavedView> get savedViews =>
      List.unmodifiable(activeWorkspace?.savedViews ?? const <SavedView>[]);

  SavedView? savedViewById(String id) {
    for (final view in savedViews) {
      if (view.id == id) {
        return view;
      }
    }
    return null;
  }

  SavedView addSavedView({
    required String name,
    required String query,
    String? icon,
    String? color,
  }) {
    final view = SavedView(
      id: _uuid.v4(),
      name: name.trim(),
      query: query.trim(),
      icon: icon,
      color: color,
      position: positionBetween(savedViews.lastOrNull?.position, null),
    );
    _putSavedView(view);
    return view;
  }

  void updateSavedView(
    String id, {
    required String name,
    required String query,
    String? icon,
    String? color,
  }) {
    final view = savedViewById(id);
    if (view == null) {
      return;
    }
    _putSavedView(
      view.copyWith(
        name: name.trim(),
        query: query.trim(),
        icon: icon,
        color: color,
      ),
    );
  }

  void _putSavedView(SavedView view) {
    final index = _workspaces.indexWhere((w) => w.id == _activeWorkspaceId);
    if (index < 0) {
      return;
    }
    final workspace = _workspaces[index];
    _workspaces[index] = workspace.copyWith(
      savedViews: [
        for (final old in workspace.savedViews)
          if (old.id != view.id) old,
        view,
      ]..sort((a, b) => a.position.compareTo(b.position)),
    );
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.savedViewPut,
        id: view.id,
        data: {'workspaceId': workspace.id, 'view': view.toJson()},
      ),
    );
  }

  void removeSavedView(String id) {
    final index = _workspaces.indexWhere((w) => w.id == _activeWorkspaceId);
    if (index < 0 || savedViewById(id) == null) {
      return;
    }
    final workspace = _workspaces[index];
    _workspaces[index] = workspace.copyWith(
      savedViews: workspace.savedViews.where((v) => v.id != id).toList(),
    );
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.savedViewDelete,
        id: id,
        data: {'workspaceId': workspace.id},
      ),
    );
  }

  void reorderSavedViews(int oldIndex, int newIndex) {
    final next = [...savedViews];
    if (oldIndex < 0 || oldIndex >= next.length) {
      return;
    }
    final view = next.removeAt(oldIndex);
    final others = [for (final v in next) v.position];
    _putSavedView(
      view.copyWith(
        position: positionAt(others, newIndex, current: view.position),
        icon: view.icon,
        color: view.color,
      ),
    );
  }

  /// Create a workspace and switch to it. Optimistic like note creation: the
  /// switch happens now and the write drains through the queue.
  Workspace createWorkspace(String name) {
    final id = _uuid.v4();
    final workspace = Workspace(
      id: id,
      collections: [NoteCollection.general(id)],
      name: name.trim(),
      owner: currentUserId == null
          ? null
          : UserRef(id: currentUserId!, name: ''),
    );
    _workspaces = [..._workspaces, workspace];
    _activeWorkspaceId = workspace.id;
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.workspaceCreate,
        id: workspace.id,
        data: {'name': workspace.name},
      ),
    );
    return workspace;
  }

  void renameWorkspace(String id, String name) {
    final i = _workspaces.indexWhere((w) => w.id == id);
    if (i == -1) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _workspaces[i] = _workspaces[i].copyWith(name: trimmed);
    notifyListeners();
    _enqueue(
      PendingOp(PendingOpKind.workspaceRename, id: id, data: {'name': trimmed}),
    );
  }

  /// Enable the workspace's two primary entry points. The owner controls this
  /// shared setting; keeping one enabled prevents a workspace with no main
  /// place to show or create notes.
  void updateWorkspaceViews({
    required String id,
    required bool notesEnabled,
    required bool boardEnabled,
  }) {
    if (!notesEnabled && !boardEnabled) return;
    final i = _workspaces.indexWhere((w) => w.id == id);
    if (i == -1 || !_workspaces[i].isOwnedBy(currentUserId)) return;
    _workspaces[i] = _workspaces[i].copyWith(
      notesEnabled: notesEnabled,
      boardEnabled: boardEnabled,
    );
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.workspaceViews,
        id: id,
        data: {'notesEnabled': notesEnabled, 'boardEnabled': boardEnabled},
      ),
    );
  }

  /// Set a workspace's AI switches. Like its views, only the owner changes
  /// them, and every member gets the AI they allow.
  void updateWorkspaceAi(String id, AiSwitches switches) {
    final i = _workspaces.indexWhere((w) => w.id == id);
    if (i == -1 || !_workspaces[i].isOwnedBy(currentUserId)) return;
    final workspace = _workspaces[i];
    _workspaces[i] = workspace.copyWith(
      ai: workspace.ai.copyWith(switches: switches),
    );
    notifyListeners();
    _enqueue(
      PendingOp(PendingOpKind.workspaceAi, id: id, data: switches.toJson()),
    );
  }

  /// The AI in workspace [id]. A note reached through a direct share, from a
  /// workspace this user is not in, gets none: that owner's setup is not
  /// visible from here.
  WorkspaceAi aiIn(String? id) => workspaceById(id)?.ai ?? const WorkspaceAi();

  /// Whether [id] can be deleted: you own it and it isn't your default one.
  bool canDeleteWorkspace(String id) {
    final workspace = workspaceById(id);
    return workspace != null &&
        !workspace.isDefault &&
        workspace.isOwnedBy(currentUserId);
  }

  /// Permanently delete a workspace and every note it contains. Cancel local
  /// debounced saves and drafts for those notes so no write can be enqueued
  /// after the workspace-delete operation.
  void deleteWorkspace(String id) {
    if (!canDeleteWorkspace(id)) return;
    for (final note in _notes.where((note) => note.workspaceId == id)) {
      _saveDebounce.remove(note.id)?.cancel();
      _drafts.remove(note.id);
    }
    _notes.removeWhere((note) => note.workspaceId == id);
    _labels.removeWhere((label) => label.workspaceId == id);
    _stages.removeWhere((stage) => stage.workspaceId == id);
    _workspaces.removeWhere((workspace) => workspace.id == id);
    _lastWorkspaceViews.remove(id);
    _reconcileActiveWorkspace();
    notifyListeners();
    _enqueue(PendingOp(PendingOpKind.workspaceDelete, id: id));
  }

  /// Leave a workspace someone else owns. Workspace-owned notes disappear
  /// from this user's shelf unless the note also carries an explicit direct
  /// share for them; the server leaves every note in the workspace.
  void leaveWorkspace(String id) {
    final me = currentUserId;
    final workspace = workspaceById(id);
    if (me == null || workspace == null || workspace.isOwnedBy(me)) return;
    final departure = reconcileWorkspaceDeparture(
      notes: _notes,
      labels: _labels,
      workspaceId: id,
      userId: me,
    );
    _notes = departure.notes;
    _labels.removeWhere((label) => label.workspaceId == id);
    _stages.removeWhere((stage) => stage.workspaceId == id);
    _workspaces.removeWhere((w) => w.id == id);
    _lastWorkspaceViews.remove(id);
    _reconcileActiveWorkspace();
    notifyListeners();
    _enqueue(
      PendingOp(PendingOpKind.leaveWorkspace, id: id, data: {'userId': me}),
    );
  }

  /// Await-based (not queued): the dialog wants immediate success/failure.
  /// Throws [ApiException] with a friendly `serverMessage` on rejection.
  Future<void> addWorkspaceMember(String workspaceId, String email) async {
    // The workspace has to exist on the server before anyone can be added.
    await _drainQueue();
    final updated = await api.addWorkspaceMember(workspaceId, email);
    final i = _workspaces.indexWhere((w) => w.id == workspaceId);
    if (i != -1) {
      _workspaces[i] = _workspaces[i].copyWith(members: updated.members);
      notifyListeners();
    }
  }

  void removeWorkspaceMember(String workspaceId, String userId) {
    if (userId == currentUserId) {
      leaveWorkspace(workspaceId);
      return;
    }
    final i = _workspaces.indexWhere((w) => w.id == workspaceId);
    if (i == -1) return;
    _workspaces[i] = _workspaces[i].copyWith(
      members: _workspaces[i].members.where((m) => m.id != userId).toList(),
    );
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.leaveWorkspace,
        id: workspaceId,
        data: {'userId': userId},
      ),
    );
  }

  /// File a note in another workspace. Owner-only, matching the server: a move
  /// changes who can see the note. Labels from the old workspace are dropped,
  /// since a label belongs to one workspace's taxonomy.
  void moveNoteToWorkspace(String noteId, String workspaceId) {
    final note = noteById(noteId);
    if (note == null ||
        note.workspaceId == workspaceId ||
        !note.isOwnedBy(currentUserId) ||
        workspaceById(workspaceId) == null) {
      return;
    }
    final kept = {
      for (final id in note.labelIds)
        if (labelById(id)?.workspaceId == workspaceId) id,
    };
    final collections = workspaceById(workspaceId)!.collections;
    if (collections.isEmpty) {
      return;
    }
    final collectionId = collections.first.id;
    _patch(
      noteId,
      note.copyWith(
        workspaceId: workspaceId,
        collectionId: collectionId,
        labelIds: kept,
        stageId: null,
      ),
      {
        'workspace_id': workspaceId,
        'collection_id': collectionId,
        'stage_id': null,
      },
    );
  }

  // ---------------------------------------------------------------------
  // Sharing

  /// Await-based (not queued): the dialog wants immediate success/failure.
  /// Throws [ApiException] with a friendly `serverMessage` on rejection.
  Future<void> addCollaborator(String noteId, String email) async {
    // Sharing needs the note on the server first.
    final timer = _saveDebounce.remove(noteId);
    timer?.cancel();
    if (_drafts.contains(noteId)) {
      _materializeIfNeeded(noteId);
    } else if (timer != null) {
      _enqueueContentPatch(noteId);
    }
    await _drainQueue();
    final updated = await api.addCollaborator(noteId, email);
    final local = noteById(noteId);
    if (local != null) {
      _replace(local.copyWith(collaborators: updated.collaborators));
    }
  }

  void removeCollaborator(String noteId, String userId) {
    final note = noteById(noteId);
    if (note == null) return;
    if (userId == currentUserId) {
      // Leaving a shared note removes it from our shelf entirely.
      _notes.removeWhere((n) => n.id == noteId);
      notifyListeners();
    } else {
      _replace(
        note.copyWith(
          collaborators: note.collaborators
              .where((c) => c.id != userId)
              .toList(),
        ),
      );
    }
    _enqueue(
      PendingOp(
        PendingOpKind.removeCollaborator,
        id: noteId,
        data: {'userId': userId},
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Version history

  /// Ensure the server has this note and every pending edit to it before an
  /// await-based call that reads or mutates server-side state (history lives
  /// on the server, so it must reflect edits still sitting in the local queue).
  Future<void> _pushPending(String noteId) async {
    final timer = _saveDebounce.remove(noteId);
    timer?.cancel();
    if (_drafts.contains(noteId)) {
      _materializeIfNeeded(noteId);
    } else if (timer != null) {
      _enqueueContentPatch(noteId);
    }
    await _drainQueue();
  }

  /// A note's edit history, newest first. Flushes pending edits first so the
  /// timeline includes what the user just typed. Throws [ApiException] on
  /// server/network failure (the UI surfaces it).
  Future<List<NoteVersion>> noteVersions(String id) async {
    await _pushPending(id);
    return api.fetchNoteVersions(id);
  }

  /// Roll a note back to a past version. The server checkpoints the current
  /// state first (so this is reversible), and returns the updated note, which
  /// replaces the local copy.
  Future<void> restoreNoteVersion(String id, String versionId) async {
    await _pushPending(id);
    final updated = await api.restoreNoteVersion(id, versionId);
    _serverUpdatedAt[id] = updated.updatedAt.toUtc().toIso8601String();
    if (noteById(id) != null) _replace(updated);
  }

  // ---------------------------------------------------------------------
  // Attachments

  /// Await-based: the editor shows progress and needs the server-issued id.
  /// Accepts any file type; the server decides how it may be served.
  Future<void> uploadFile(
    String noteId,
    Uint8List bytes,
    String mime,
    String filename,
  ) async {
    await _materializeForAttachment(noteId);
    await _drainQueue();
    final attachment = await api.uploadAttachment(
      noteId,
      bytes,
      mime,
      filename,
    );
    final note = noteById(noteId);
    if (note != null) {
      _replace(note.copyWith(attachments: [...note.attachments, attachment]));
    }
  }

  Future<void> _materializeForAttachment(String noteId) async {
    if (_drafts.contains(noteId)) {
      // Force-create even while textually empty; the file is the content.
      _drafts.remove(noteId);
      final note = noteById(noteId);
      if (note != null) {
        final created = await api.createNote(note);
        _serverUpdatedAt[noteId] = created.updatedAt.toUtc().toIso8601String();
      }
    }
  }

  /// Drag-and-drop onto the grid: one new note holding all [files].
  /// Returns the note id, or null when nothing uploaded (the empty draft is
  /// discarded rather than left as a phantom note).
  Future<String?> createNoteWithFiles(
    List<DroppedFile> files, {
    Set<String> labelIds = const {},
  }) async {
    final note = createDraft(labelIds: labelIds);
    var uploaded = 0;
    for (final file in files) {
      try {
        await uploadFile(note.id, file.bytes, file.mime, file.name);
        uploaded++;
      } catch (_) {
        // Skip the failed file; the rest may still make it.
      }
    }
    if (uploaded == 0) {
      deleteForever(note.id);
      return null;
    }
    return note.id;
  }

  /// Content shared into the app (a link, some text) → one text note.
  /// Materializes immediately via [updateNoteContent] (which pushes the draft
  /// to the server). Returns the note id, or null when there was nothing to
  /// save (the empty draft is discarded rather than left as a phantom note).
  Future<String?> createTextNote(String content, {String title = ''}) async {
    final body = content.trim();
    final heading = title.trim();
    if (body.isEmpty && heading.isEmpty) return null;
    final note = createDraft();
    updateNoteContent(note.id, title: heading, content: body);
    return note.id;
  }

  void removeAttachment(String noteId, String attachmentId) {
    final note = noteById(noteId);
    if (note == null) return;
    _replace(
      note.copyWith(
        attachments: note.attachments
            .where((attachment) => attachment.id != attachmentId)
            .toList(),
      ),
    );
    _enqueue(PendingOp(PendingOpKind.deleteAttachment, id: attachmentId));
  }

  /// Resolved, ready-to-load URL for an attachment (uses the server's signed,
  /// time-limited URL so image/audio element loads stay authorized).
  String fileUrl(Attachment attachment) => api.attachmentUrl(attachment);

  // ---------------------------------------------------------------------
  // Audio notes

  /// Recording finished → create an audio note holding the clip. When Whisper
  /// is available, the note is shown as transcribing immediately; otherwise it
  /// remains a fully playable audio note with an empty editable transcript.
  /// Returns the note id, or null when the upload failed (the empty draft is
  /// discarded).
  Future<String?> createAudioNote(
    Uint8List bytes,
    String mime, {
    Set<String> labelIds = const {},
    bool transcriptionAvailable = false,
  }) async {
    final note = createDraft(kind: NoteKind.audio, labelIds: labelIds);
    if (transcriptionAvailable) {
      // Surface the transcribing animation before the round-trip completes.
      _replace(note.copyWith(transcriptStatus: 'pending'));
    }
    final ext = switch (mime.split(';').first.trim()) {
      'audio/webm' => 'webm',
      'audio/ogg' => 'ogg',
      'audio/mp4' => 'm4a',
      'audio/mpeg' => 'mp3',
      'audio/wav' || 'audio/x-wav' => 'wav',
      _ => 'audio',
    };
    try {
      await uploadFile(note.id, bytes, mime, 'recording.$ext');
    } catch (_) {
      deleteForever(note.id);
      return null;
    }
    return note.id;
  }

  /// Retry a failed (or stale) transcription. Optimistically flips the note
  /// back to transcribing while the server re-runs Whisper.
  void retranscribe(String id) {
    final note = noteById(id);
    if (note == null) return;
    _replace(note.copyWith(transcriptStatus: 'pending'));
    _enqueue(PendingOp(PendingOpKind.transcribe, id: id));
  }

  // ---------------------------------------------------------------------
  // Semantic search

  /// Ranked note ids for a meaning-based query, filtered to notes we
  /// actually have locally (never trashed ones). Throws on server errors so
  /// the UI can fall back to keyword search.
  Future<List<Note>> semanticSearch(String query) async {
    final ids = await api.semanticSearch(
      query,
      workspaceId: _activeWorkspaceId,
    );
    return [
      for (final id in ids)
        if (noteById(id) case final Note note)
          if (!note.trashed) note,
    ];
  }

  // ---------------------------------------------------------------------
  // Labels

  Label createLabel(String name, {String? color, String? icon}) {
    final workspaceId = _activeWorkspaceId ?? '';
    final label = Label(
      id: _uuid.v4(),
      workspaceId: workspaceId,
      name: name.trim(),
      color: color,
      icon: icon,
      position: _nextLabelPosition(workspaceId),
    );
    _labels = [..._labels, label]..sort(_byLabelPosition);
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.labelCreate,
        id: label.id,
        data: {
          'name': label.name,
          'workspaceId': label.workspaceId,
          'color': color,
          'icon': icon,
          'position': label.position,
        },
      ),
    );
    return label;
  }

  /// A new label goes to the end of the sidebar list, matching the server.
  double _nextLabelPosition(String workspaceId) {
    var max = 0.0;
    for (final label in _labels) {
      if (label.workspaceId == workspaceId && label.position > max) {
        max = label.position;
      }
    }
    return max + 1024.0;
  }

  static int _byLabelPosition(Label a, Label b) {
    final byPosition = a.position.compareTo(b.position);
    return byPosition != 0
        ? byPosition
        : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  /// Rename and/or restyle a label. Passing null for [color]/[icon] clears it
  /// (resets to the theme default), these are set to exactly what's given, not
  /// merged, so the editor's "no colour"/"no icon" choice sticks. [position]
  /// moves the label in the sidebar; omitting it leaves the order alone.
  void updateLabel(
    String id, {
    String? name,
    String? color,
    String? icon,
    double? position,
  }) {
    final i = _labels.indexWhere((l) => l.id == id);
    if (i == -1) return;
    final newName = (name ?? _labels[i].name).trim();
    _labels[i] = Label(
      id: id,
      workspaceId: _labels[i].workspaceId,
      name: newName,
      color: color,
      icon: icon,
      position: position ?? _labels[i].position,
    );
    _labels.sort(_byLabelPosition);
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.labelUpdate,
        id: id,
        data: {
          'name': newName,
          'color': color,
          'icon': icon,
          'position': position,
        },
      ),
    );
  }

  /// Drag-reorder a label. [newIndex] is the final resting index, same
  /// convention as [moveStage].
  void moveLabel(String id, int newIndex) {
    final ordered = labels;
    final label = ordered.where((l) => l.id == id).firstOrNull;
    if (label == null) return;
    final others = [
      for (final l in ordered)
        if (l.id != id) l.position,
    ];
    updateLabel(
      id,
      name: label.name,
      color: label.color,
      icon: label.icon,
      position: positionAt(others, newIndex, current: label.position),
    );
  }

  void deleteLabel(String id) {
    _labels.removeWhere((l) => l.id == id);
    for (var i = 0; i < _notes.length; i++) {
      if (_notes[i].labelIds.contains(id)) {
        _notes[i] = _notes[i].copyWith(
          labelIds: {..._notes[i].labelIds}..remove(id),
        );
      }
    }
    notifyListeners();
    _enqueue(PendingOp(PendingOpKind.labelDelete, id: id));
  }

  // ---------------------------------------------------------------------
  // Stages (board columns)
  //
  // Deliberately parallel to labels rather than sharing code with them: the
  // two are independent systems, and keeping them as two obvious blocks costs
  // less than one abstraction both have to be read through.

  Stage createStage(String name, {String? color}) {
    final workspaceId = _activeWorkspaceId ?? '';
    final stage = Stage(
      id: _uuid.v4(),
      workspaceId: workspaceId,
      collectionId: activeCollection?.id,
      name: name.trim(),
      color: color,
      position: _nextStagePosition(workspaceId),
    );
    _stages = [..._stages, stage]
      ..sort((a, b) => a.position.compareTo(b.position));
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.stageCreate,
        id: stage.id,
        data: {
          'name': stage.name,
          'workspaceId': workspaceId,
          'collectionId': activeCollection?.id,
          'color': color,
          'position': stage.position,
        },
      ),
    );
    return stage;
  }

  /// A new column goes to the right of the board, matching the server.
  double _nextStagePosition(String workspaceId) {
    var max = 0.0;
    for (final stage in _stages) {
      if (stage.workspaceId == workspaceId && stage.position > max) {
        max = stage.position;
      }
    }
    return max + 1024.0;
  }

  /// Rename and/or recolour a column. Passing null for [color] clears it, the
  /// same "set, not merge" rule [updateLabel] uses. [position] moves the
  /// column; omitting it leaves the board's order alone.
  void updateStage(String id, {String? name, String? color, double? position}) {
    final i = _stages.indexWhere((s) => s.id == id);
    if (i == -1) return;
    final newName = (name ?? _stages[i].name).trim();
    _stages[i] = Stage(
      id: id,
      workspaceId: _stages[i].workspaceId,
      collectionId: _stages[i].collectionId,
      name: newName,
      color: color,
      position: position ?? _stages[i].position,
    );
    _stages.sort((a, b) => a.position.compareTo(b.position));
    notifyListeners();
    _enqueue(
      PendingOp(
        PendingOpKind.stageUpdate,
        id: id,
        data: {'name': newName, 'color': color, 'position': position},
      ),
    );
  }

  /// Drag-reorder a column. [newIndex] is the final resting index (the slot
  /// the item lands in, counted *after* its own removal), the convention
  /// `ReorderableListView.onReorderItem` reports, so that callback can call
  /// this directly. Recomputes a sparse position between the new neighbours
  /// rather than renumbering the board (see [positionAt]).
  void moveStage(String id, int newIndex) {
    final ordered = stages;
    final stage = ordered.where((s) => s.id == id).firstOrNull;
    if (stage == null) return;
    final others = [
      for (final s in ordered)
        if (s.id != id) s.position,
    ];
    updateStage(
      id,
      name: stage.name,
      color: stage.color,
      position: positionAt(others, newIndex, current: stage.position),
    );
  }

  /// Delete a column. Its notes are not destroyed, they go back to unassigned,
  /// locally and on the server.
  void deleteStage(String id) {
    _stages.removeWhere((s) => s.id == id);
    for (var i = 0; i < _notes.length; i++) {
      if (_notes[i].stageId == id) {
        _notes[i] = _notes[i].copyWith(stageId: null);
      }
    }
    notifyListeners();
    _enqueue(PendingOp(PendingOpKind.stageDelete, id: id));
  }

  /// Move a note to [stageId] (null for unassigned). Without a [position] the
  /// card goes to the end of that column, which is what the column picker
  /// wants; a drop passes the slot it landed in (see [positionBetween]).
  ///
  /// One patch carries both fields, so a move is a single queued write rather
  /// than a stage change chased by a reorder. That also makes reordering
  /// *within* a column the same operation as moving between two: it is a move
  /// to the stage the card is already in. Labels are untouched, a card
  /// changing column says nothing about its taxonomy.
  void setNoteStage(String noteId, String? stageId, {double? position}) {
    final note = noteById(noteId);
    if (note == null) return;
    // A no-op reposition still has to be filtered out, or every drop that
    // lands where the card already was would queue a write.
    if (note.stageId == stageId && position == null) return;
    final target = position ?? _endOfStage(stageId, note.workspaceId);
    if (note.stageId == stageId && note.stagePosition == target) return;
    _patch(noteId, note.copyWith(stageId: stageId, stagePosition: target), {
      'stage_id': stageId,
      'stage_position': target,
    });
  }

  /// One slot past the last card of [stageId] in [workspaceId].
  double _endOfStage(String? stageId, String workspaceId) {
    var max = 0.0;
    for (final note in _notes) {
      if (note.workspaceId != workspaceId || note.stageId != stageId) continue;
      if (note.stagePosition > max) max = note.stagePosition;
    }
    return max + 1024.0;
  }

  // ---------------------------------------------------------------------
  // Sync queue

  void _enqueue(PendingOp op) {
    if (_disposed) return;
    _localWriteRevision++;
    _queue.add(op);
    _persistNow();
    _flush();
  }

  void dismissSyncIssue(SyncIssue issue) {
    if (_syncIssues.remove(issue)) {
      _persistNow();
      notifyListeners();
      if (_queue.isEmpty) load();
    }
  }

  void retrySyncIssue(SyncIssue issue) {
    if (!_syncIssues.remove(issue)) return;
    if (issue.note case final snapshot?) {
      final restored = Note.fromJson(snapshot);
      if (noteById(restored.id) == null) {
        _notes.add(restored);
      } else {
        _replace(restored);
      }
    }
    _persistNow();
    notifyListeners();
    _enqueue(issue.operation);
  }

  /// Wait for the serial queue to empty (used before await-based calls that
  /// depend on queued writes, like sharing right after creating).
  Future<void> _drainQueue() async {
    while (!_disposed && _queue.isNotEmpty && !_connectionDown) {
      if (_retryTimer?.isActive == true) return;
      await _flush();
      if (_queue.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  Future<void> _flush() async {
    if (_disposed || _flushing) return;
    _flushing = true;
    try {
      while (!_disposed && _queue.isNotEmpty) {
        final op = _queue.first;
        try {
          // Keep exactly one mutation in flight. `Future.timeout` does not
          // cancel its underlying HTTP request; retrying after such a timeout
          // could let the original finish last and overwrite a newer queued
          // operation. ApiClient owns the real transport timeout instead.
          await _pendingOperations.run(op);
          if (_disposed) break;
          _queue.removeAt(0);
          _persistNow();
          final connectionChanged = _markConnectionUp();
          if (connectionChanged || _queue.isEmpty) notifyListeners();
        } on ApiException catch (e) {
          if (_disposed) break;
          // Authentication expiry and explicit throttling are recoverable.
          // Keep the operation durable so signing in again or waiting for the
          // server cannot silently discard an offline edit. Other 4xx
          // responses are permanent contract/permission failures.
          final decision = syncFailureDecision(e);
          if (decision.shouldDrop) {
            _syncIssues.removeWhere(
              (issue) =>
                  issue.operation.id == op.id &&
                  issue.operation.kind == op.kind &&
                  issue.statusCode == e.statusCode,
            );
            _syncIssues.add(
              SyncIssue(
                op,
                e.serverMessage,
                e.statusCode,
                op.id == null ? null : noteById(op.id!)?.toJson(),
              ),
            );
            _queue.removeAt(0);
            _persistNow();
            notifyListeners();
            continue;
          }
          _scheduleRetry(
            markConnectionDown: decision.markConnectionDown,
            delay: decision.retryDelay,
          );
          break;
        } catch (_) {
          if (!_disposed) _scheduleRetry();
          break;
        }
      }
    } finally {
      _flushing = false;
    }
    if (!_disposed &&
        _queue.isEmpty &&
        _reloadPending &&
        !_hasLocalChangesInFlight) {
      _reloadPending = false;
      load();
    }
  }

  void _scheduleRetry({
    bool markConnectionDown = true,
    Duration delay = const Duration(seconds: 5),
  }) {
    if (_disposed) return;
    if (markConnectionDown) _markConnectionDown();
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, _flush);
  }

  Future<void> retryNow() async {
    if (_disposed) return;
    _retryTimer?.cancel();
    if (_queue.isEmpty) {
      await load();
    } else {
      await _flush();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    _offlineConfirmTimer?.cancel();
    _syncReloadDebounce?.cancel();
    _connectionProbeTimer?.cancel();
    _syncSub?.cancel();
    _onlineSub?.cancel();
    _notifyThrottle?.cancel();
    for (final t in _saveDebounce.values) {
      t.cancel();
    }
    super.dispose();
  }
}
