import '../models/note.dart';
import '../models/workspace.dart';
import 'note_collection.dart';
import 'pending_operation.dart';
import 'sync_issue.dart';

/// The offline snapshot `NotesStore` keeps per account and server: what it
/// renders before the network answers, plus the writes still owed to it.
/// Pure encoding; the store decides what goes in and how it is ordered.
class NotesCacheDoc {
  const NotesCacheDoc({
    this.notes = const [],
    this.labels = const [],
    this.stages = const [],
    this.workspaces = const [],
    this.checklistHistory = const {},
    this.queue = const [],
    this.syncIssues = const [],
    this.serverUpdatedAt = const {},
  });

  final List<Note> notes;
  final List<Label> labels;
  final List<Stage> stages;
  final List<Workspace> workspaces;
  final Map<String, List<String>> checklistHistory;
  final List<PendingOp> queue;
  final List<SyncIssue> syncIssues;

  /// Note id to the `updated_at` the server last reported, for conflict checks.
  final Map<String, String> serverUpdatedAt;

  factory NotesCacheDoc.fromJson(Map<String, dynamic> doc) => NotesCacheDoc(
    notes: _list(doc['notes'], Note.fromJson),
    labels: _list(doc['labels'], Label.fromJson),
    stages: _list(doc['stages'], Stage.fromJson),
    workspaces: _list(doc['workspaces'], Workspace.fromJson),
    checklistHistory: {
      for (final e in (doc['history'] as Map? ?? const {}).entries)
        e.key as String: (e.value as List).cast<String>(),
    },
    queue: _list(doc['queue'], PendingOp.fromJson),
    syncIssues: _list(doc['sync_issues'], SyncIssue.fromJson),
    serverUpdatedAt: (doc['server_updated_at'] as Map? ?? const {})
        .cast<String, String>(),
  );

  Map<String, dynamic> toJson() => {
    // Note.toJson carries attachment *metadata* only (id/mime/name/size),
    // never file bytes. Uploaded media stays on the server and is fetched by
    // URL on demand, so the cache stays small regardless of attachment size.
    'notes': [for (final n in notes) n.toJson()],
    'labels': [for (final l in labels) l.toJson()],
    'stages': [for (final s in stages) s.toJson()],
    'workspaces': [for (final w in workspaces) w.toJson()],
    'history': checklistHistory,
    'queue': [for (final op in queue) op.toJson()],
    'sync_issues': [for (final issue in syncIssues) issue.toJson()],
    'server_updated_at': serverUpdatedAt,
  };

  static List<T> _list<T>(
    Object? json,
    T Function(Map<String, dynamic>) fromJson,
  ) => [
    for (final j in (json as List? ?? const []))
      fromJson((j as Map).cast<String, dynamic>()),
  ];
}

/// Where this device was: the open workspace, and the collection and view
/// last used in each. Kept apart from [NotesCacheDoc] because it changes on
/// every switch, and writing it must not re-encode every note.
///
/// Its keys match those older snapshots carried inline, so such a snapshot
/// reads as one of these.
class NavigationCacheDoc {
  const NavigationCacheDoc({
    this.activeWorkspaceId,
    this.collectionChoices = const {},
    this.workspaceViews = const {},
  });

  /// Which workspace to reopen in. Local rather than a synced setting: it is
  /// where this device was, not a preference.
  final String? activeWorkspaceId;

  /// Workspace id to the collection last open in it.
  final Map<String, String> collectionChoices;

  /// Workspace id to the drawer destination last used in it.
  final Map<String, ViewSelection> workspaceViews;

  factory NavigationCacheDoc.fromJson(Map<String, dynamic> doc) =>
      NavigationCacheDoc(
        activeWorkspaceId: doc['active_workspace'] as String?,
        collectionChoices: (doc['collection_choices'] as Map? ?? const {})
            .cast<String, String>(),
        workspaceViews: {
          for (final entry
              in (doc['workspace_views'] as Map? ?? const {}).entries)
            if (entry.key is String)
              entry.key as String: ?_viewFromJson(entry.value),
        },
      );

  Map<String, dynamic> toJson() => {
    'active_workspace': activeWorkspaceId,
    'collection_choices': collectionChoices,
    'workspace_views': {
      for (final entry in workspaceViews.entries)
        entry.key: {
          'view': entry.value.view.name,
          if (entry.value.labelId != null) 'label_id': entry.value.labelId,
        },
    },
  };

  static ViewSelection? _viewFromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final view = NoteView.values
        .where((candidate) => candidate.name == value['view'])
        .firstOrNull;
    if (view == null) {
      return null;
    }
    final labelId = value['label_id'];
    if (view == NoteView.label && (labelId is! String || labelId.isEmpty)) {
      return null;
    }
    return ViewSelection(view, labelId is String ? labelId : null);
  }
}
