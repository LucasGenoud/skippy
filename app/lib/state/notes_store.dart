import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../api/api_client.dart';
import '../models/dropped_file.dart';
import '../models/note.dart';
import '../util/connectivity.dart';
import 'local_cache.dart';

enum NoteView { notes, reminders, archive, trash, label }

enum SortMode { custom, edited, newest, oldest }

class ViewSelection {
  final NoteView view;
  final String? labelId;
  const ViewSelection(this.view, [this.labelId]);

  static const notes = ViewSelection(NoteView.notes);
  static const reminders = ViewSelection(NoteView.reminders);
  static const archive = ViewSelection(NoteView.archive);
  static const trash = ViewSelection(NoteView.trash);

  @override
  bool operator ==(Object other) =>
      other is ViewSelection && other.view == view && other.labelId == labelId;

  @override
  int get hashCode => Object.hash(view, labelId);
}

class NoteSections {
  final List<Note> pinned;
  final List<Note> others;
  const NoteSections(this.pinned, this.others);
  bool get isEmpty => pinned.isEmpty && others.isEmpty;
}

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

  /// Invoked on server-push change events, so siblings (e.g. the settings
  /// store) can refresh from the same socket.
  final VoidCallback? onRemoteChange;

  static const _uuid = Uuid();

  List<Note> _notes = [];
  List<Label> _labels = [];

  /// Previously checked item texts, keyed by note id (suggestions are
  /// per-note by design).
  Map<String, List<String>> _checklistHistory = {};
  bool loading = true;
  bool offline = false;
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

  StreamSubscription<void>? _syncSub;
  StreamSubscription<void>? _onlineSub;
  Timer? _syncReloadDebounce;
  bool _reloadPending = false;

  NotesStore({
    required this.api,
    LocalCache? cache,
    this.currentUserId,
    this.onRemoteChange,
  }) : cache = cache ?? MemoryLocalCache();

  List<Label> get labels => List.unmodifiable(_labels);

  /// Notes for a data export: everything except trash, in display order.
  List<Note> get notesForExport =>
      _notes.where((n) => !n.trashed).toList()
        ..sort((a, b) => a.position.compareTo(b.position));

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
      _queue.isNotEmpty || _drafts.isNotEmpty || _saveDebounce.isNotEmpty;

  Future<void> load() async {
    await _hydrate();
    try {
      final notes = await api.fetchNotes();
      final labels = await api.fetchLabels();
      final history = await api.fetchChecklistHistory();
      // Don't clobber local state that still has unsynced changes.
      if (!_hasLocalChangesInFlight) {
        _notes = notes..sort((a, b) => a.position.compareTo(b.position));
        _labels = labels;
        _checklistHistory = history;
      } else {
        _reloadPending = true;
      }
      offline = false;
    } catch (_) {
      offline = true;
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 5), load);
    }
    loading = false;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Local persistence (offline cache)

  String get _cacheKey => currentUserId ?? 'local';

  /// Load the on-disk snapshot so notes render instantly — before, and even
  /// without, a network round-trip. Runs once; the network fetch in [load]
  /// then reconciles (local unsynced edits win). Persisted pending writes are
  /// replayed right away.
  Future<void> _hydrate() async {
    if (_hydrated) return;
    try {
      final doc = await cache.read(_cacheKey);
      if (doc != null) {
        _notes = [
          for (final j in (doc['notes'] as List? ?? const []))
            Note.fromJson((j as Map).cast<String, dynamic>()),
        ]..sort((a, b) => a.position.compareTo(b.position));
        _labels = [
          for (final j in (doc['labels'] as List? ?? const []))
            Label.fromJson((j as Map).cast<String, dynamic>()),
        ];
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
    if (_notes.isNotEmpty || _labels.isNotEmpty) {
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
      // Note.toJson carries attachment *metadata* only (id/mime/name/size) —
      // never file bytes. Uploaded media stays on the server and is fetched by
      // URL on demand, so the cache stays small regardless of attachment size.
      'notes': [
        for (final n in _notes)
          if (!(_drafts.contains(n.id) && n.isEmpty)) n.toJson(),
      ],
      'labels': [for (final l in _labels) l.toJson()],
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
    if (!_hydrated) return;
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
    super.notifyListeners();
    _persistSoon();
  }

  /// Live sync: any server-side change to this user's notes triggers a
  /// debounced refetch (skipped while our own edits are still in flight).
  void startSync() {
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
    _onlineSub = onlineEvents().listen((_) => retryNow());
  }

  // ---------------------------------------------------------------------
  // Filtering & sorting

  NoteSections notesFor(ViewSelection selection, String query) {
    final q = query.trim().toLowerCase();
    bool matches(Note n) {
      if (q.isEmpty) return true;
      if (n.title.toLowerCase().contains(q)) return true;
      if (n.content.toLowerCase().contains(q)) return true;
      if (n.items.any((i) => i.text.toLowerCase().contains(q))) return true;
      return n.labelIds.any((id) {
        final label = labelById(id);
        return label != null && label.name.toLowerCase().contains(q);
      });
    }

    bool inView(Note n) => switch (selection.view) {
      NoteView.notes => !n.archived && !n.trashed,
      NoteView.reminders => n.reminderAt != null && !n.trashed,
      NoteView.archive => n.archived && !n.trashed,
      // Trash only shows your own notes: collaborators cannot trash, so a
      // shared note trashed by its owner is simply gone for them.
      NoteView.trash => n.trashed && n.isOwnedBy(currentUserId),
      NoteView.label => !n.trashed && n.labelIds.contains(selection.labelId),
    };

    final visible = _notes.where((n) => inView(n) && matches(n)).toList();

    if (selection.view == NoteView.reminders) {
      visible.sort((a, b) => a.reminderAt!.compareTo(b.reminderAt!));
      return NoteSections(const [], visible);
    }
    _applySort(visible);
    final splitPins =
        selection.view == NoteView.notes || selection.view == NoteView.label;
    if (!splitPins) return NoteSections(const [], visible);
    return NoteSections(
      visible.where((n) => n.pinned).toList(),
      visible.where((n) => !n.pinned).toList(),
    );
  }

  void _applySort(List<Note> notes) {
    switch (sortMode) {
      case SortMode.custom:
        break; // _notes is already position-sorted
      case SortMode.edited:
        notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      case SortMode.newest:
        notes.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case SortMode.oldest:
        notes.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }
  }

  void setSortMode(SortMode mode) {
    sortMode = mode;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Note mutations (all optimistic)

  Note createDraft({NoteKind kind = NoteKind.text}) {
    final now = DateTime.now();
    final note = Note(
      id: _uuid.v4(),
      kind: kind,
      position: _frontPosition(),
      createdAt: now,
      updatedAt: now,
      owner: currentUserId == null
          ? null
          : UserRef(id: currentUserId!, username: ''),
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

  PendingOp _contentPatchOp(String id, Note note) => PendingOp(
    'patch',
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
  /// checked off IN THIS NOTE — history never leaks across notes. Prefix
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
    late final Note updated;
    if (target == NoteKind.checklist) {
      // One item per non-empty line; markdown list/task markers map onto
      // the checkbox instead of being kept as text.
      final items = <ChecklistItem>[];
      for (final rawLine in note.content.split('\n')) {
        var line = rawLine.trim();
        if (line.isEmpty) continue;
        var done = false;
        final task = RegExp(r'^[-*+]\s+\[( |x|X)\]\s*').firstMatch(line);
        if (task != null) {
          done = task.group(1)!.toLowerCase() == 'x';
          line = line.substring(task.end).trim();
        } else {
          line = line.replaceFirst(RegExp(r'^[-*+]\s+'), '');
        }
        if (line.isEmpty) continue;
        items.add(ChecklistItem(id: _uuid.v4(), text: line, done: done));
      }
      updated = note.copyWith(kind: target, content: '', items: items);
    } else if (note.isChecklist) {
      final text = [
        for (final item in note.items)
          if (item.text.trim().isNotEmpty)
            target == NoteKind.markdown
                ? '- [${item.done ? 'x' : ' '}] ${item.text}'
                : item.text,
      ].join('\n');
      final merged = note.content.trim().isEmpty
          ? text
          : '${note.content}\n$text';
      updated = note.copyWith(kind: target, content: merged, items: []);
    } else {
      // text <-> markdown: same content, different rendering.
      updated = note.copyWith(kind: target);
    }
    _replace(updated.copyWith(updatedAt: DateTime.now()));
    if (_drafts.contains(id)) return;
    _enqueue(
      PendingOp(
        'patch',
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
    if (note == null || note.isEmpty) return;
    _drafts.remove(id);
    _enqueue(PendingOp('create', id: id));
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
    _enqueue(PendingOp('patch', id: id, data: fields));
  }

  void togglePin(String id) {
    final note = noteById(id);
    if (note == null) return;
    if (note.archived && !note.pinned) {
      // Keep parity: pinning an archived note moves it back to Notes.
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
    if (!wasDraft) _enqueue(PendingOp('delete', id: id));
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
    _enqueue(PendingOp('patch', id: noteId, data: {'label_ids': ids.toList()}));
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
      PendingOp('reorder', data: {'ids': List<String>.from(orderedIds)}),
    );
  }

  /// "Make a copy": clone content into a fresh note at the front of the grid.
  /// Attachments and collaborators intentionally stay behind.
  void duplicate(String id) {
    final source = noteById(id);
    if (source == null) return;
    final now = DateTime.now();
    final copy = Note(
      id: _uuid.v4(),
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
    _enqueue(PendingOp('create', id: copy.id));
    if (copy.labelIds.isNotEmpty) {
      _enqueue(
        PendingOp(
          'patch',
          id: copy.id,
          data: {'label_ids': copy.labelIds.toList()},
        ),
      );
    }
  }

  /// Flush pending edits when an editor closes. Returns true when the note
  /// was empty and has been discarded (Keep behavior).
  bool finalizeNote(String id) {
    final note = noteById(id);
    if (note == null) return false;
    if (note.isEmpty) {
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
  /// any moment, so stop waiting on debounce timers — enqueue what they were
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
  // Sharing

  /// Await-based (not queued): the dialog wants immediate success/failure.
  /// Throws [ApiException] with a friendly `serverMessage` on rejection.
  Future<void> addCollaborator(String noteId, String username) async {
    // Sharing needs the note on the server first.
    final timer = _saveDebounce.remove(noteId);
    timer?.cancel();
    if (_drafts.contains(noteId)) {
      _materializeIfNeeded(noteId);
    } else if (timer != null) {
      _enqueueContentPatch(noteId);
    }
    await _drainQueue();
    final updated = await api.addCollaborator(noteId, username);
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
      PendingOp('removeCollaborator', id: noteId, data: {'userId': userId}),
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
  Future<String?> createNoteWithFiles(List<DroppedFile> files) async {
    final note = createDraft();
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
    _enqueue(PendingOp('deleteAttachment', id: attachmentId));
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
  Future<String?> createAudioNote(Uint8List bytes, String mime) async {
    final note = createDraft(kind: NoteKind.audio);
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
    _enqueue(PendingOp('transcribe', id: id));
  }

  // ---------------------------------------------------------------------
  // Semantic search

  /// Ranked note ids for a meaning-based query, filtered to notes we
  /// actually have locally (never trashed ones). Throws on server errors so
  /// the UI can fall back to keyword search.
  Future<List<Note>> semanticSearch(String query) async {
    final ids = await api.semanticSearch(query);
    return [
      for (final id in ids)
        if (noteById(id) case final Note note)
          if (!note.trashed) note,
    ];
  }

  // ---------------------------------------------------------------------
  // Labels

  Label createLabel(String name) {
    final label = Label(id: _uuid.v4(), name: name.trim());
    _labels = [..._labels, label]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    notifyListeners();
    _enqueue(
      PendingOp('labelCreate', id: label.id, data: {'name': label.name}),
    );
    return label;
  }

  void renameLabel(String id, String name) {
    final i = _labels.indexWhere((l) => l.id == id);
    if (i == -1) return;
    _labels[i] = Label(id: id, name: name.trim());
    _labels.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    notifyListeners();
    _enqueue(PendingOp('labelRename', id: id, data: {'name': name.trim()}));
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
    _enqueue(PendingOp('labelDelete', id: id));
  }

  // ---------------------------------------------------------------------
  // Sync queue

  void _enqueue(PendingOp op) {
    _queue.add(op);
    _persistNow();
    _flush();
  }

  /// Wait for the serial queue to empty (used before await-based calls that
  /// depend on queued writes, like sharing right after creating).
  Future<void> _drainQueue() async {
    while (_queue.isNotEmpty && !offline) {
      await _flush();
      if (_queue.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    while (_queue.isNotEmpty) {
      final op = _queue.first;
      try {
        await _run(op);
        _queue.removeAt(0);
        _persistNow();
        if (offline) {
          offline = false;
          notifyListeners();
        }
      } on ApiException catch (e) {
        // A 4xx will never succeed on retry; drop the op instead of wedging
        // the queue. 5xx are treated like network failures below.
        if (e.statusCode >= 400 && e.statusCode < 500) {
          debugPrint('dropping rejected op: $e');
          _queue.removeAt(0);
          _persistNow();
          continue;
        }
        _scheduleRetry();
        break;
      } catch (_) {
        _scheduleRetry();
        break;
      }
    }
    _flushing = false;
    if (_queue.isEmpty && _reloadPending && !_hasLocalChangesInFlight) {
      _reloadPending = false;
      load();
    }
  }

  /// Execute one queued write. Creates re-read the freshest note so edits made
  /// after enqueuing still go up; a create for a note deleted in the meantime
  /// is a no-op (a trailing delete/404 tidies the server side).
  Future<void> _run(PendingOp op) {
    switch (op.kind) {
      case 'create':
        final note = noteById(op.id!);
        return note == null ? Future.value() : api.createNote(note);
      case 'patch':
        return api.patchNote(op.id!, op.data);
      case 'delete':
        return api.deleteNote(op.id!);
      case 'reorder':
        return api.reorderNotes((op.data['ids'] as List).cast<String>());
      case 'labelCreate':
        return api.createLabel(op.id!, op.data['name'] as String);
      case 'labelRename':
        return api.renameLabel(op.id!, op.data['name'] as String);
      case 'labelDelete':
        return api.deleteLabel(op.id!);
      case 'removeCollaborator':
        return api.removeCollaborator(op.id!, op.data['userId'] as String);
      case 'deleteAttachment':
        return api.deleteAttachment(op.id!);
      case 'transcribe':
        return api.transcribeNote(op.id!);
      default:
        return Future<void>.value();
    }
  }

  void _scheduleRetry() {
    if (!offline) {
      offline = true;
      notifyListeners();
    }
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 5), _flush);
  }

  void retryNow() {
    _retryTimer?.cancel();
    if (_queue.isEmpty) {
      load();
    } else {
      _flush();
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _syncReloadDebounce?.cancel();
    _syncSub?.cancel();
    _onlineSub?.cancel();
    _notifyThrottle?.cancel();
    for (final t in _saveDebounce.values) {
      t.cancel();
    }
    super.dispose();
  }
}

/// A serializable pending write. Replacing closures with these lets the sync
/// queue be persisted and replayed after a reload. [kind] selects the API call
/// (see `NotesStore._run`); [id] and [data] carry its arguments.
class PendingOp {
  final String kind;
  final String? id;
  final Map<String, dynamic> data;

  const PendingOp(this.kind, {this.id, this.data = const {}});

  Map<String, dynamic> toJson() => {
    'kind': kind,
    if (id != null) 'id': id,
    if (data.isNotEmpty) 'data': data,
  };

  factory PendingOp.fromJson(Map<String, dynamic> json) => PendingOp(
    json['kind'] as String,
    id: json['id'] as String?,
    data: (json['data'] as Map?)?.cast<String, dynamic>() ?? const {},
  );
}
