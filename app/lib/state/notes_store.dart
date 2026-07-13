import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../api/api_client.dart';
import '../models/dropped_file.dart';
import '../models/note.dart';

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

  final List<Future<void> Function()> _queue = [];
  bool _flushing = false;
  Timer? _retryTimer;
  final Map<String, Timer> _saveDebounce = {};

  /// Notes created locally that have not been sent to the server yet.
  final Set<String> _drafts = {};

  StreamSubscription<void>? _syncSub;
  Timer? _syncReloadDebounce;
  bool _reloadPending = false;

  NotesStore({required this.api, this.currentUserId, this.onRemoteChange});

  List<Label> get labels => List.unmodifiable(_labels);

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
    _enqueue(
      () => api.patchNote(id, {
        'kind': latest.kind.wire,
        'title': latest.title,
        'content': latest.content,
        'items': Note.itemsToJson(latest.items),
      }),
    );
  }

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
      () => api.patchNote(id, {
        'kind': updated.kind.wire,
        'content': updated.content,
        'items': Note.itemsToJson(updated.items),
      }),
    );
  }

  void _materializeIfNeeded(String id) {
    final note = noteById(id);
    if (note == null || note.isEmpty) return;
    _drafts.remove(id);
    _enqueue(() async {
      final latest = noteById(id);
      if (latest == null) return;
      await api.createNote(latest);
    });
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
    _enqueue(() => api.patchNote(id, fields));
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
    if (!wasDraft) _enqueue(() => api.deleteNote(id));
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
    _enqueue(() => api.patchNote(noteId, {'label_ids': ids.toList()}));
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
    final ids = List<String>.from(orderedIds);
    _enqueue(() => api.reorderNotes(ids));
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
    _enqueue(() async {
      await api.createNote(copy);
      if (copy.labelIds.isNotEmpty) {
        await api.patchNote(copy.id, {'label_ids': copy.labelIds.toList()});
      }
    });
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
    _enqueue(() => api.removeCollaborator(noteId, userId));
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
    _enqueue(() => api.deleteAttachment(attachmentId));
  }

  String fileUrl(String attachmentId) => api.fileUrl(attachmentId);

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
    _enqueue(() => api.createLabel(label.id, label.name));
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
    _enqueue(() => api.renameLabel(id, name.trim()));
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
    _enqueue(() => api.deleteLabel(id));
  }

  // ---------------------------------------------------------------------
  // Sync queue

  void _enqueue(Future<void> Function() op) {
    _queue.add(op);
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
        await op();
        _queue.removeAt(0);
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
    for (final t in _saveDebounce.values) {
      t.cancel();
    }
    super.dispose();
  }
}
