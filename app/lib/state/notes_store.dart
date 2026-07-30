import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../api/api_client.dart';
import '../models/dropped_file.dart';
import '../models/note.dart';
import '../models/workspace.dart';
import '../util/backup.dart';
import '../util/connectivity.dart';
import 'local_cache.dart';
import 'note_collection.dart';
import 'note_conversion.dart';
import 'pending_operation.dart';

export 'note_collection.dart'
    show NoteSections, NoteView, SortMode, ViewSelection, WorkspaceScope;

/// Coarse connectivity/sync state surfaced on the top-bar avatar.
///
/// [connecting] and [syncing] both spin: the difference is whether we are still
/// establishing that the server is there, or already talking to it.
enum SyncStatus { synced, syncing, connecting, offline }

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

  /// Invoked on server-push change events, so siblings (e.g. the settings
  /// store) can refresh from the same socket.
  final VoidCallback? onRemoteChange;

  static const _uuid = Uuid();

  List<Note> _notes = [];
  List<Label> _labels = [];
  List<Stage> _stages = [];
  List<Workspace> _workspaces = [];

  /// The workspace the UI is showing. Null until the first load resolves one
  /// (the cached choice, or the default workspace).
  String? _activeWorkspaceId;

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
  SortMode sortMode = SortMode.custom;

  final List<PendingOp> _queue = [];
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
  }) : cache = cache ?? MemoryLocalCache();

  /// Labels of the open workspace. Labels are a workspace's shared taxonomy,
  /// so switching workspaces switches the whole sidebar.
  List<Label> get labels {
    final scope = workspaceScope;
    return List.unmodifiable([
      for (final label in _labels)
        if (scope.containsWorkspace(label.workspaceId)) label,
    ]);
  }

  /// Board columns of the open workspace, left to right. Like [labels] these
  /// are workspace state, but an independent one: a note has any number of
  /// labels and at most one stage.
  List<Stage> get stages {
    final scope = workspaceScope;
    return List.unmodifiable([
      for (final stage in _stages)
        if (scope.containsWorkspace(stage.workspaceId)) stage,
    ]);
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
  WorkspaceScope get workspaceScope => WorkspaceScope(
    workspaceId: _activeWorkspaceId,
    isDefault:
        _activeWorkspaceId != null &&
        _activeWorkspaceId == defaultWorkspace?.id,
    known: {for (final workspace in _workspaces) workspace.id},
  );

  /// Notes in the open workspace, whatever their view, used by the pickers
  /// and counts that must agree with what the grid shows.
  List<Note> get notesInActiveWorkspace {
    final scope = workspaceScope;
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
      if (note.reminderAt != null) note,
  ];

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
    flushForBackground();
    await _drainQueue();
    if (_connectionDown || _queue.isNotEmpty) {
      throw const BackupRestoreException(
        'Connect to the server before restoring a backup',
        restoredNotes: 0,
      );
    }

    _restoringBackup = true;
    notifyListeners();
    final selectedIds =
        workspaceIds ??
        {for (final workspace in bundle.workspaces) workspace.id};
    final selected = [
      for (final workspace in bundle.workspaces)
        if (selectedIds.contains(workspace.id)) workspace,
    ];
    if (selected.isEmpty) {
      _restoringBackup = false;
      notifyListeners();
      throw const BackupRestoreException(
        'Choose at least one workspace to restore',
        restoredNotes: 0,
      );
    }

    final owned = ownedWorkspaces;
    final ownedIds = {for (final workspace in owned) workspace.id};
    final ownedNotes = [
      for (final note in _notes)
        if (ownedIds.contains(_effectiveWorkspaceId(note)) &&
            note.isOwnedBy(currentUserId))
          note,
    ];
    final defaultId = defaultWorkspace?.id;
    final defaultLabels = [
      for (final label in _labels)
        if (label.workspaceId == defaultId) label,
    ];
    final defaultStages = [
      for (final stage in _stages)
        if (stage.workspaceId == defaultId) stage,
    ];
    final nonDefaultOwned = [
      for (final workspace in owned)
        if (!workspace.isDefault) workspace,
    ];
    final selectedLabels = selected.fold<int>(
      0,
      (count, workspace) => count + workspace.labels.length,
    );
    final selectedStages = selected.fold<int>(
      0,
      (count, workspace) => count + workspace.stages.length,
    );
    final selectedNotes = selected.fold<int>(
      0,
      (count, workspace) => count + workspace.notes.length,
    );
    final selectedAttachments = selected.fold<int>(
      0,
      (count, workspace) => count + workspace.attachmentCount,
    );
    final createdWorkspaces = selected
        .where((workspace) => !workspace.isDefault)
        .length;
    final totalSteps =
        ownedNotes.length +
        defaultLabels.length +
        defaultStages.length +
        nonDefaultOwned.length +
        createdWorkspaces +
        selectedLabels +
        selectedStages +
        selectedNotes +
        selectedAttachments;
    var completed = 0;
    var restoredNotes = 0;
    var restoredAttachments = 0;
    var restoredLabels = 0;
    var restoredStages = 0;
    var restoredWorkspaces = 0;

    try {
      // Clear individually owned notes first, including those in the default
      // workspace. Deleting each remaining non-default workspace then removes
      // any notes it still contains, regardless of their author.
      for (final note in ownedNotes) {
        await api.deleteNote(note.id);
        onProgress?.call(++completed, totalSteps);
      }
      for (final label in defaultLabels) {
        await api.deleteLabel(label.id);
        onProgress?.call(++completed, totalSteps);
      }
      for (final stage in defaultStages) {
        await api.deleteStage(stage.id);
        onProgress?.call(++completed, totalSteps);
      }
      for (final workspace in nonDefaultOwned) {
        await api.deleteWorkspace(workspace.id);
        onProgress?.call(++completed, totalSteps);
      }

      final defaultTarget = defaultWorkspace;
      for (final backupWorkspace in selected) {
        final String targetWorkspaceId;
        if (backupWorkspace.isDefault) {
          if (defaultTarget == null) {
            throw const BackupRestoreException(
              'The account has no default workspace',
              restoredNotes: 0,
            );
          }
          targetWorkspaceId = defaultTarget.id;
          if (defaultTarget.name != backupWorkspace.name) {
            await api.renameWorkspace(defaultTarget.id, backupWorkspace.name);
          }
        } else {
          final created = await api.createWorkspace(
            _uuid.v4(),
            backupWorkspace.name,
          );
          targetWorkspaceId = created.id;
          restoredWorkspaces++;
          onProgress?.call(++completed, totalSteps);
        }
        if (!backupWorkspace.notesEnabled || !backupWorkspace.boardEnabled) {
          await api.updateWorkspaceViews(
            targetWorkspaceId,
            notesEnabled: backupWorkspace.notesEnabled,
            boardEnabled: backupWorkspace.boardEnabled,
          );
        }

        final labelMap = <String, String>{};
        for (final backupLabel in backupWorkspace.labels) {
          final id = _uuid.v4();
          await api.createLabel(
            id,
            backupLabel.name,
            workspaceId: targetWorkspaceId,
            color: backupLabel.color,
            icon: backupLabel.icon,
            position: backupLabel.position,
          );
          labelMap[backupLabel.id] = id;
          restoredLabels++;
          onProgress?.call(++completed, totalSteps);
        }

        final stageMap = <String, String>{};
        for (final backupStage in backupWorkspace.stages) {
          final id = _uuid.v4();
          await api.createStage(
            id,
            backupStage.name,
            workspaceId: targetWorkspaceId,
            color: backupStage.color,
            position: backupStage.position,
          );
          stageMap[backupStage.id] = id;
          restoredStages++;
          onProgress?.call(++completed, totalSteps);
        }

        for (final backupNote in backupWorkspace.notes) {
          final noteId = _uuid.v4();
          final note = Note(
            id: noteId,
            workspaceId: targetWorkspaceId,
            kind: backupNote.kind,
            title: backupNote.title,
            content: backupNote.content,
            items: [
              for (final item in backupNote.items)
                ChecklistItem(
                  id: item.id.isEmpty ? _uuid.v4() : item.id,
                  text: item.text,
                  done: item.done,
                ),
            ],
            color: backupNote.color,
            pinned: backupNote.pinned,
            archived: backupNote.archived,
            trashed: backupNote.trashed,
            position: backupNote.position,
            stageId: backupNote.stageId == null
                ? null
                : stageMap[backupNote.stageId!],
            stagePosition: backupNote.stagePosition,
            reminderAt: backupNote.reminderAt?.toLocal(),
            createdAt: backupNote.createdAt,
            updatedAt: backupNote.updatedAt,
            labelIds: {
              for (final oldId in backupNote.labelIds)
                if (labelMap[oldId] case final String id) id,
            },
            owner: currentUserId == null
                ? null
                : UserRef(id: currentUserId!, name: ''),
          );
          await api.createNote(note, preserveTimestamps: true);
          restoredNotes++;
          onProgress?.call(++completed, totalSteps);
          for (final attachment in backupNote.attachments) {
            await api.uploadAttachment(
              note.id,
              attachment.bytes,
              attachment.mime,
              attachment.filename,
            );
            restoredAttachments++;
            onProgress?.call(++completed, totalSteps);
          }
        }
      }

      return BackupRestoreResult(
        workspaces:
            restoredWorkspaces + (selected.any((w) => w.isDefault) ? 1 : 0),
        notes: restoredNotes,
        attachments: restoredAttachments,
        labels: restoredLabels,
        stages: restoredStages,
      );
    } catch (error) {
      final message = error is ApiException
          ? error.serverMessage
          : error is BackupRestoreException
          ? error.message
          : 'Restore could not be completed';
      throw BackupRestoreException(
        '$message. Some owned workspace data may already have been replaced',
        restoredNotes: restoredNotes,
      );
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
        final workspaces = await api.fetchWorkspaces();
        if (!isCurrent()) return;
        final notes = await api.fetchNotes();
        if (!isCurrent()) return;
        final labels = await api.fetchLabels();
        if (!isCurrent()) return;
        final stages = await api.fetchStages();
        if (!isCurrent()) return;
        final history = await api.fetchChecklistHistory();
        if (!isCurrent()) return;
        final writesChangedDuringFetch = revisionAtStart != _localWriteRevision;
        // A write can enter and leave the queue entirely while these requests
        // are in flight. Checking only the queue at the end would then apply a
        // stale pre-write snapshot over the optimistic checklist edit.
        if (!startedWithLocalChanges &&
            !writesChangedDuringFetch &&
            !_hasLocalChangesInFlight) {
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
    if (_disposed || refreshing) return;
    final generation = ++_fetchGeneration;
    bool isCurrent() => !_disposed && generation == _fetchGeneration;
    refreshing = true;
    notifyListeners();
    // Push anything queued/mid-debounce first, so the server state we pull back
    // already includes it (and won't be discarded by the in-flight guard).
    for (final id in _saveDebounce.keys.toList()) {
      _saveDebounce.remove(id)?.cancel();
      _enqueueContentPatch(id);
    }
    if (_queue.isNotEmpty) _flush();
    try {
      final workspaces = await api.fetchWorkspaces();
      if (!isCurrent()) return;
      final notes = await api.fetchNotes();
      if (!isCurrent()) return;
      final labels = await api.fetchLabels();
      if (!isCurrent()) return;
      final stages = await api.fetchStages();
      if (!isCurrent()) return;
      final history = await api.fetchChecklistHistory();
      if (!isCurrent()) return;
      if (!_hasLocalChangesInFlight) {
        _notes = notes..sort((a, b) => a.position.compareTo(b.position));
        _labels = labels;
        _stages = stages;
        _workspaces = workspaces;
        _reconcileActiveWorkspace();
        _checklistHistory = history;
      } else {
        _reloadPending = true;
      }
      _markConnectionUp();
    } catch (_) {
      if (!isCurrent()) return;
      _markConnectionDown();
    } finally {
      refreshing = false;
      if (isCurrent()) {
        // A refresh may have superseded the initial load.
        loading = false;
        notifyListeners();
      }
    }
  }

  // ---------------------------------------------------------------------
  // Local persistence (offline cache)

  String get _legacyCacheKey => notesCacheKey('', currentUserId);

  String get _cacheKey => notesCacheKey(cacheNamespace, currentUserId);

  static const Map<String, dynamic> _emptyCacheDoc = {
    'notes': <dynamic>[],
    'labels': <dynamic>[],
    'stages': <dynamic>[],
    'workspaces': <dynamic>[],
    'workspace_views': <String, dynamic>{},
    'history': <String, dynamic>{},
    'queue': <dynamic>[],
  };

  static ViewSelection? _workspaceViewFromJson(Object? value) {
    if (value is! Map) return null;
    final name = value['view'];
    if (name is! String) return null;
    NoteView? view;
    for (final candidate in NoteView.values) {
      if (candidate.name == name) {
        view = candidate;
        break;
      }
    }
    if (view == null) return null;
    final labelId = value['label_id'];
    if (view == NoteView.label && (labelId is! String || labelId.isEmpty)) {
      return null;
    }
    return ViewSelection(view, labelId is String ? labelId : null);
  }

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
        doc = _emptyCacheDoc;
        await cache.write(_cacheKey, doc);
      }
      if (doc != null) {
        _notes = [
          for (final j in (doc['notes'] as List? ?? const []))
            Note.fromJson((j as Map).cast<String, dynamic>()),
        ]..sort((a, b) => a.position.compareTo(b.position));
        _labels = [
          for (final j in (doc['labels'] as List? ?? const []))
            Label.fromJson((j as Map).cast<String, dynamic>()),
        ]..sort(_byLabelPosition);
        _stages = [
          for (final j in (doc['stages'] as List? ?? const []))
            Stage.fromJson((j as Map).cast<String, dynamic>()),
        ]..sort((a, b) => a.position.compareTo(b.position));
        _workspaces = [
          for (final j in (doc['workspaces'] as List? ?? const []))
            Workspace.fromJson((j as Map).cast<String, dynamic>()),
        ];
        _activeWorkspaceId = doc['active_workspace'] as String?;
        _reconcileActiveWorkspace();
        _lastWorkspaceViews.clear();
        for (final entry
            in (doc['workspace_views'] as Map? ?? const {}).entries) {
          final selection = _workspaceViewFromJson(entry.value);
          if (entry.key is String && selection != null) {
            _lastWorkspaceViews[entry.key as String] = selection;
          }
        }
        _checklistHistory = {
          for (final e in (doc['history'] as Map? ?? const {}).entries)
            e.key as String: (e.value as List).cast<String>(),
        };
        _queue
          ..clear()
          ..addAll([
            for (final j in (doc['queue'] as List? ?? const []))
              PendingOp.fromJson((j as Map).cast<String, dynamic>()),
          ]);
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
  Map<String, dynamic> _toCacheDoc() {
    final ops = [for (final op in _queue) op.toJson()];
    // A content edit made in the last <400ms before a reload hasn't been
    // enqueued yet (it's mid-debounce); fold those pending saves in so nothing
    // is lost.
    for (final id in _saveDebounce.keys) {
      final note = noteById(id);
      if (note != null) ops.add(_contentPatchOp(id, note).toJson());
    }
    return {
      // Note.toJson carries attachment *metadata* only (id/mime/name/size),
      // never file bytes. Uploaded media stays on the server and is fetched by
      // URL on demand, so the cache stays small regardless of attachment size.
      'notes': [
        for (final n in _notes)
          if (!(_drafts.contains(n.id) && canAutoDiscard(n.id))) n.toJson(),
      ],
      'labels': [for (final l in _labels) l.toJson()],
      'stages': [for (final s in _stages) s.toJson()],
      'workspaces': [for (final w in _workspaces) w.toJson()],
      // Which workspace to reopen in. Deliberately local rather than a synced
      // setting: it is where this device was, not a preference.
      'active_workspace': _activeWorkspaceId,
      'workspace_views': {
        for (final entry in _lastWorkspaceViews.entries)
          entry.key: {
            'view': entry.value.view.name,
            if (entry.value.labelId != null) 'label_id': entry.value.labelId,
          },
      },
      'history': _checklistHistory,
      'queue': ops,
    };
  }

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
        await cache.write(_cacheKey, _toCacheDoc());
      } catch (_) {
        // Best-effort; the next change retries the write.
      }
    }
    _persisting = false;
  }

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
      // lasted long enough for the user to ever hear about it.
      if (wasDown) await retryNow();
    } catch (_) {
      if (_disposed) return;
      _markConnectionDown();
    } finally {
      _checkingConnection = false;
    }
  }

  // ---------------------------------------------------------------------
  // Filtering & sorting

  NoteSections notesFor(ViewSelection selection, String query) => selectNotes(
    notes: _notes,
    labels: _labels,
    selection: selection,
    query: query,
    sortMode: sortMode,
    currentUserId: currentUserId,
    scope: workspaceScope,
  );

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
    final note = Note(
      id: _uuid.v4(),
      workspaceId: workspaceId,
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

  double _frontPosition() {
    double min = 0;
    for (final n in _notes) {
      if (n.position < min) min = n.position;
    }
    return min - 1024.0;
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
    final updated = note.copyWith(
      kind: kind,
      title: title,
      content: content,
      items: items,
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
  Future<void> rewriteNote(String id, NoteRewriteMode mode) async {
    if (!_rewritingNoteIds.add(id)) return;
    notifyListeners();
    try {
      await _pushPending(id);
      final updated = await api.rewriteNote(id, mode);
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

  /// Toggle a checklist box (works from the card without opening the note).
  void toggleChecklistItem(String noteId, String itemId) {
    final note = noteById(noteId);
    if (note == null) return;
    final items = [
      for (final item in note.items)
        item.id == itemId ? item.copyWith(done: !item.done) : item,
    ];
    // Keep the local suggestion dictionary warm; the server records it too.
    final toggled = items.firstWhere((i) => i.id == itemId);
    if (toggled.done) rememberCheckedText(noteId, toggled.text);
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

  void _materializeIfNeeded(String id) {
    final note = noteById(id);
    if (note == null || note.canAutoDiscard) return;
    _drafts.remove(id);
    _enqueue(PendingOp(PendingOpKind.create, id: id));
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

  void setArchived(String id, bool archived) {
    final note = noteById(id);
    if (note == null) return;
    _patch(id, note.copyWith(archived: archived, pinned: false), {
      'archived': archived,
      'pinned': false,
    });
  }

  void setReminder(String id, DateTime? at) {
    final note = noteById(id);
    if (note == null) return;
    _patch(id, note.copyWith(reminderAt: at), {
      'reminder_at': at?.toUtc().toIso8601String(),
    });
    // A reminder makes even a wordless draft durable. Create it immediately
    // so an app suspension before the editor closes cannot leave a cached
    // note with no corresponding server row.
    if (at != null && _drafts.contains(id)) {
      _materializeIfNeeded(id);
    }
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

  void restoreFromTrash(String id) {
    final note = noteById(id);
    if (note == null) return;
    _patch(id, note.copyWith(trashed: false), {'trashed': false});
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

  /// "Duplicate": clone content into a fresh note at the front of the grid.
  /// Attachments and collaborators intentionally stay behind.
  void duplicate(String id) {
    final source = noteById(id);
    if (source == null) return;
    final now = DateTime.now();
    final copy = Note(
      id: _uuid.v4(),
      workspaceId: source.workspaceId,
      kind: source.kind,
      title: source.title,
      content: source.content,
      items: [
        for (final item in source.items)
          ChecklistItem(id: _uuid.v4(), text: item.text, done: item.done),
      ],
      color: source.color,
      position: _frontPosition(),
      createdAt: now,
      updatedAt: now,
      labelIds: Set<String>.from(source.labelIds),
      owner: source.owner,
    );
    _notes.insert(0, copy);
    _notes.sort((a, b) => a.position.compareTo(b.position));
    notifyListeners();
    _enqueue(PendingOp(PendingOpKind.create, id: copy.id));
    if (copy.labelIds.isNotEmpty) {
      _enqueue(
        PendingOp(
          PendingOpKind.patch,
          id: copy.id,
          data: {'label_ids': copy.labelIds.toList()},
        ),
      );
    }
  }

  /// Flush pending edits when an editor closes. Returns true when the note
  /// was empty and has been discarded.
  bool finalizeNote(String id) {
    final note = noteById(id);
    if (note == null) return false;
    if (canAutoDiscard(id)) {
      deleteForever(id);
      return true;
    }
    if (_drafts.contains(id)) {
      _materializeIfNeeded(id);
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

  /// Create a workspace and switch to it. Optimistic like note creation: the
  /// switch happens now and the write drains through the queue.
  Workspace createWorkspace(String name) {
    final workspace = Workspace(
      id: _uuid.v4(),
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

  /// Leave a workspace someone else owns. Notes you own there follow you to
  /// your default workspace; the rest disappear from your shelf.
  void leaveWorkspace(String id) {
    final me = currentUserId;
    final workspace = workspaceById(id);
    if (me == null || workspace == null || workspace.isOwnedBy(me)) return;
    _rehomeNotesLocally(id, (note) => note.isOwnedBy(me));
    _notes.removeWhere((note) => note.workspaceId == id);
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

  /// Reconcile notes while a workspace is going away. Our own notes move into
  /// our default workspace. A note owned elsewhere but retained through a
  /// direct share keeps an unknown foreign workspace id until the refetch
  /// supplies its owner's new default id; [WorkspaceScope] still surfaces it
  /// in our default view. Workspace labels and board placement never follow.
  void _rehomeNotesLocally(String workspaceId, bool Function(Note) keep) {
    final home = defaultWorkspace?.id ?? '';
    final leavingLabels = {
      for (final label in _labels)
        if (label.workspaceId == workspaceId) label.id,
    };
    for (var i = 0; i < _notes.length; i++) {
      final note = _notes[i];
      if (note.workspaceId != workspaceId || !keep(note)) continue;
      _notes[i] = note.copyWith(
        workspaceId: note.isOwnedBy(currentUserId) ? home : note.workspaceId,
        labelIds: note.labelIds.difference(leavingLabels),
        stageId: null,
      );
    }
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
    _patch(noteId, note.copyWith(workspaceId: workspaceId, labelIds: kept), {
      'workspace_id': workspaceId,
    });
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
    if (_drafts.contains(noteId)) {
      // Force-create even while textually empty; the file is the content.
      _drafts.remove(noteId);
      final note = noteById(noteId);
      if (note != null) await api.createNote(note);
    }
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
            .where((a) => a.id != attachmentId)
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

  /// Recording finished → create an audio note holding the clip. The note is
  /// shown as transcribing immediately (optimistic); uploading the clip makes
  /// the server run Whisper and fill in the transcript. Returns the note id,
  /// or null when the upload failed (the empty draft is discarded).
  Future<String?> createAudioNote(
    Uint8List bytes,
    String mime, {
    Set<String> labelIds = const {},
  }) async {
    final note = createDraft(kind: NoteKind.audio, labelIds: labelIds);
    // Surface the transcribing animation before the round-trip completes.
    _replace(note.copyWith(transcriptStatus: 'pending'));
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
    final ordered = List<Label>.from(labels);
    final currentIndex = ordered.indexWhere((l) => l.id == id);
    if (currentIndex == -1) return;
    final label = ordered.removeAt(currentIndex);
    ordered.insert(newIndex, label);
    final above = newIndex > 0 ? ordered[newIndex - 1] : null;
    final below = newIndex + 1 < ordered.length ? ordered[newIndex + 1] : null;
    final newPosition = above == null && below == null
        ? label.position
        : above == null
        ? below!.position - 1024.0
        : below == null
        ? above.position + 1024.0
        : (above.position + below.position) / 2;
    updateLabel(
      id,
      name: label.name,
      color: label.color,
      icon: label.icon,
      position: newPosition,
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
  /// rather than renumbering the board, same trick as [positionBetween].
  void moveStage(String id, int newIndex) {
    final ordered = List<Stage>.from(stages);
    final currentIndex = ordered.indexWhere((s) => s.id == id);
    if (currentIndex == -1) return;
    final stage = ordered.removeAt(currentIndex);
    ordered.insert(newIndex, stage);
    final above = newIndex > 0 ? ordered[newIndex - 1] : null;
    final below = newIndex + 1 < ordered.length ? ordered[newIndex + 1] : null;
    final newPosition = above == null && below == null
        ? stage.position
        : above == null
        ? below!.position - 1024.0
        : below == null
        ? above.position + 1024.0
        : (above.position + below.position) / 2;
    updateStage(
      id,
      name: stage.name,
      color: stage.color,
      position: newPosition,
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

  /// The slot between two cards in a column, for a drop that landed there.
  ///
  /// Positions are sparse rather than densely renumbered, so placing a card
  /// writes one row instead of the whole column, the same trick
  /// [_frontPosition] uses for new notes. A null neighbour means the head or
  /// the tail of the column.
  static double positionBetween(Note? above, Note? below) {
    if (above == null && below == null) return 1024.0;
    if (above == null) return below!.stagePosition - 1024.0;
    if (below == null) return above.stagePosition + 1024.0;
    return (above.stagePosition + below.stagePosition) / 2;
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
          await _run(op);
          if (_disposed) break;
          _queue.removeAt(0);
          _persistNow();
          if (_markConnectionUp()) notifyListeners();
        } on ApiException catch (e) {
          if (_disposed) break;
          // Authentication expiry and explicit throttling are recoverable.
          // Keep the operation durable so signing in again or waiting for the
          // server cannot silently discard an offline edit. Other 4xx
          // responses are permanent contract/permission failures.
          final retryable =
              e.statusCode == 401 ||
              e.statusCode == 408 ||
              e.statusCode == 425 ||
              e.statusCode == 429;
          if (e.statusCode >= 400 && e.statusCode < 500 && !retryable) {
            debugPrint('dropping rejected op: $e');
            _queue.removeAt(0);
            _persistNow();
            continue;
          }
          final serverAskedToWait =
              e.statusCode == 401 || e.statusCode == 425 || e.statusCode == 429;
          _scheduleRetry(
            markConnectionDown: !serverAskedToWait,
            delay: serverAskedToWait
                ? const Duration(seconds: 10)
                : const Duration(seconds: 5),
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

  /// Execute one queued write. Creates re-read the freshest note so edits made
  /// after enqueuing still go up; a create for a note deleted in the meantime
  /// is a no-op (a trailing delete/404 tidies the server side).
  Future<void> _run(PendingOp op) {
    switch (op.kind) {
      case PendingOpKind.create:
        final note = noteById(op.id!);
        return note == null ? Future.value() : api.createNote(note);
      case PendingOpKind.patch:
        return api.patchNote(op.id!, op.data);
      case PendingOpKind.delete:
        return api.deleteNote(op.id!);
      case PendingOpKind.reorder:
        return api.reorderNotes((op.data['ids'] as List).cast<String>());
      case PendingOpKind.labelCreate:
        return api.createLabel(
          op.id!,
          op.data['name'] as String,
          workspaceId: op.data['workspaceId'] as String? ?? '',
          color: op.data['color'] as String?,
          icon: op.data['icon'] as String?,
          position: (op.data['position'] as num?)?.toDouble(),
        );
      case PendingOpKind.labelUpdate:
        return api.updateLabel(
          op.id!,
          op.data['name'] as String,
          color: op.data['color'] as String?,
          icon: op.data['icon'] as String?,
          position: (op.data['position'] as num?)?.toDouble(),
        );
      case PendingOpKind.labelDelete:
        return api.deleteLabel(op.id!);
      case PendingOpKind.stageCreate:
        return api.createStage(
          op.id!,
          op.data['name'] as String,
          workspaceId: op.data['workspaceId'] as String? ?? '',
          color: op.data['color'] as String?,
          position: (op.data['position'] as num?)?.toDouble(),
        );
      case PendingOpKind.stageUpdate:
        return api.updateStage(
          op.id!,
          op.data['name'] as String,
          color: op.data['color'] as String?,
          position: (op.data['position'] as num?)?.toDouble(),
        );
      case PendingOpKind.stageDelete:
        return api.deleteStage(op.id!);
      case PendingOpKind.workspaceCreate:
        return api.createWorkspace(op.id!, op.data['name'] as String);
      case PendingOpKind.workspaceRename:
        return api.renameWorkspace(op.id!, op.data['name'] as String);
      case PendingOpKind.workspaceViews:
        return api.updateWorkspaceViews(
          op.id!,
          notesEnabled: op.data['notesEnabled'] as bool? ?? true,
          boardEnabled: op.data['boardEnabled'] as bool? ?? true,
        );
      case PendingOpKind.workspaceDelete:
        return api.deleteWorkspace(op.id!);
      case PendingOpKind.leaveWorkspace:
        return api.removeWorkspaceMember(op.id!, op.data['userId'] as String);
      case PendingOpKind.removeCollaborator:
        return api.removeCollaborator(op.id!, op.data['userId'] as String);
      case PendingOpKind.deleteAttachment:
        return api.deleteAttachment(op.id!);
      case PendingOpKind.transcribe:
        return api.transcribeNote(op.id!);
      case PendingOpKind.unknown:
        return Future<void>.value();
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
