import 'package:uuid/uuid.dart';

import '../api/api_client.dart';
import '../models/collection.dart';
import '../models/note.dart';
import '../models/workspace.dart';
import '../util/backup.dart';
import '../util/keep_import.dart';
import 'note_links.dart';
import 'sparse_position.dart';

/// What a backup restore replaces: the account's owned workspace data as the
/// store holds it when the restore starts.
class RestoreReplacement {
  const RestoreReplacement({
    required this.notes,
    required this.defaultWorkspace,
    required this.defaultLabels,
    required this.defaultStages,
    required this.otherWorkspaces,
  });

  /// Notes this user owns in their own workspaces, the default one included.
  final List<Note> notes;
  final Workspace? defaultWorkspace;
  final List<Label> defaultLabels;
  final List<Stage> defaultStages;

  /// Owned workspaces other than the default one, deleted with what they hold.
  final List<Workspace> otherWorkspaces;
}

/// The server writes behind a backup restore and a Google Keep import: direct,
/// awaited calls in a fixed order, so progress stays truthful. `NotesStore`
/// decides when one may run and refreshes afterwards; this owns the requests
/// and the id remapping between them.
class BulkImporter {
  BulkImporter(this._api, this._currentUserId);

  final Api _api;
  final String? _currentUserId;

  static const _uuid = Uuid();

  UserRef? get _owner =>
      _currentUserId == null ? null : UserRef(id: _currentUserId, name: '');

  /// Delete what [replacing] describes, then recreate [selected] from the
  /// backup under fresh ids.
  Future<BackupRestoreResult> restoreBackup(
    List<BackupWorkspace> selected,
    RestoreReplacement replacing, {
    BackupProgress? onProgress,
  }) async {
    int sum(int Function(BackupWorkspace) count) =>
        selected.fold(0, (total, workspace) => total + count(workspace));
    final totalSteps =
        replacing.notes.length +
        replacing.defaultLabels.length +
        replacing.defaultStages.length +
        replacing.otherWorkspaces.length +
        selected.where((workspace) => !workspace.isDefault).length +
        sum((w) => w.labels.length) +
        sum((w) => w.stages.length) +
        sum((w) => w.notes.length) +
        sum((w) => w.attachmentCount);
    var completed = 0;
    void step() => onProgress?.call(++completed, totalSteps);

    var restoredNotes = 0;
    var restoredAttachments = 0;
    var restoredLabels = 0;
    var restoredStages = 0;
    var restoredWorkspaces = 0;

    try {
      // Clear individually owned notes first, including those in the default
      // workspace. Deleting each remaining non-default workspace then removes
      // any notes it still contains, regardless of their author.
      final defaultWorkspace = replacing.defaultWorkspace;
      for (final note in replacing.notes) {
        await _api.deleteNote(note.id);
        step();
      }
      for (final label in replacing.defaultLabels) {
        await _api.deleteLabel(label.id);
        step();
      }
      for (final view in defaultWorkspace?.savedViews ?? const []) {
        await _api.deleteSavedView(defaultWorkspace!.id, view.id);
      }
      for (final stage in replacing.defaultStages) {
        await _api.deleteStage(stage.id);
        step();
      }
      for (final workspace in replacing.otherWorkspaces) {
        await _api.deleteWorkspace(workspace.id);
        step();
      }

      // Every restored note gets its id up front, so links between restored
      // notes can point at each other's new ids.
      final restoredIds = {
        for (final workspace in selected)
          for (final backupNote in workspace.notes) backupNote.id: _uuid.v4(),
      };

      for (final backupWorkspace in selected) {
        final String targetWorkspaceId;
        if (backupWorkspace.isDefault) {
          if (defaultWorkspace == null) {
            throw const BackupRestoreException(
              'The account has no default workspace',
              restoredNotes: 0,
            );
          }
          targetWorkspaceId = defaultWorkspace.id;
          if (defaultWorkspace.name != backupWorkspace.name) {
            await _api.renameWorkspace(
              defaultWorkspace.id,
              backupWorkspace.name,
            );
          }
        } else {
          final created = await _api.createWorkspace(
            _uuid.v4(),
            backupWorkspace.name,
          );
          targetWorkspaceId = created.id;
          restoredWorkspaces++;
          step();
        }
        await _restoreSettings(backupWorkspace, targetWorkspaceId);

        final collectionMap = await _restoreCollections(
          backupWorkspace,
          targetWorkspaceId,
        );
        for (final view in backupWorkspace.savedViews) {
          await _api.putSavedView(targetWorkspaceId, view);
        }

        final labelMap = <String, String>{};
        for (final backupLabel in backupWorkspace.labels) {
          final id = _uuid.v4();
          await _api.createLabel(
            id,
            backupLabel.name,
            workspaceId: targetWorkspaceId,
            color: backupLabel.color,
            icon: backupLabel.icon,
            position: backupLabel.position,
          );
          labelMap[backupLabel.id] = id;
          restoredLabels++;
          step();
        }

        final stageMap = <String, String>{};
        for (final backupStage in backupWorkspace.stages) {
          final id = _uuid.v4();
          await _api.createStage(
            id,
            backupStage.name,
            collectionId:
                collectionMap[backupStage.collectionId] ??
                collectionMap.values.first,
            workspaceId: targetWorkspaceId,
            color: backupStage.color,
            position: backupStage.position,
          );
          stageMap[backupStage.id] = id;
          restoredStages++;
          step();
        }

        for (final backupNote in backupWorkspace.notes) {
          final note = _restoredNote(
            backupNote,
            id: restoredIds[backupNote.id]!,
            workspaceId: targetWorkspaceId,
            collectionId:
                collectionMap[backupNote.collectionId] ??
                collectionMap.values.first,
            noteIds: restoredIds,
            labelIds: labelMap,
            stageIds: stageMap,
          );
          await _api.createNote(note, preserveTimestamps: true);
          restoredNotes++;
          step();
          for (final attachment in backupNote.attachments) {
            await _api.uploadAttachment(
              note.id,
              attachment.bytes,
              attachment.mime,
              attachment.filename,
            );
            restoredAttachments++;
            step();
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
    }
  }

  /// Workspace switches that differ from a new workspace's defaults.
  Future<void> _restoreSettings(
    BackupWorkspace backupWorkspace,
    String targetWorkspaceId,
  ) async {
    if (!backupWorkspace.notesEnabled || !backupWorkspace.boardEnabled) {
      await _api.updateWorkspaceViews(
        targetWorkspaceId,
        notesEnabled: backupWorkspace.notesEnabled,
        boardEnabled: backupWorkspace.boardEnabled,
      );
    }
    if (backupWorkspace.aiSwitches != const AiSwitches()) {
      await _api.updateWorkspaceAi(
        targetWorkspaceId,
        backupWorkspace.aiSwitches,
      );
    }
  }

  /// Replace the target's collections with the backup's, returning old id to
  /// new id. A backup from before collections gets one General collection.
  Future<Map<String, String>> _restoreCollections(
    BackupWorkspace backupWorkspace,
    String targetWorkspaceId,
  ) async {
    final currentTargets = await _api.fetchWorkspaces();
    for (final target in currentTargets.where(
      (w) => w.id == targetWorkspaceId,
    )) {
      for (final collection in target.collections) {
        await _api.deleteCollection(targetWorkspaceId, collection.id);
      }
    }

    final sourceCollections =
        backupWorkspace.collections.isEmpty &&
            (backupWorkspace.notes.isNotEmpty ||
                backupWorkspace.stages.isNotEmpty)
        ? [NoteCollection.general(backupWorkspace.id)]
        : backupWorkspace.collections;
    final collectionMap = <String, String>{};
    for (final old in sourceCollections) {
      final id = _uuid.v4();
      collectionMap[old.id] = id;
      await _api.putCollection(
        NoteCollection.fromJson({
          ...old.toJson(),
          'id': id,
          'workspace_id': targetWorkspaceId,
        }),
      );
    }
    return collectionMap;
  }

  /// A backup note as it is recreated, every reference mapped to new ids.
  Note _restoredNote(
    BackupNote backupNote, {
    required String id,
    required String workspaceId,
    required String collectionId,
    required Map<String, String> noteIds,
    required Map<String, String> labelIds,
    required Map<String, String> stageIds,
  }) {
    // An item with no id of its own gets a fresh one, so its reminder has to
    // follow it rather than the id it was archived under.
    final itemIdMap = <String, String>{};
    final restoredItems = [
      for (final item in backupNote.items)
        ChecklistItem(
          id: itemIdMap[item.id] = item.id.isEmpty ? _uuid.v4() : item.id,
          text: item.text,
          done: item.done,
        ),
    ];
    return Note(
      id: id,
      workspaceId: workspaceId,
      collectionId: collectionId,
      kind: backupNote.kind,
      title: backupNote.title,
      content: remapNoteLinks(backupNote.content, noteIds),
      items: restoredItems,
      color: backupNote.color,
      pinned: backupNote.pinned,
      archived: backupNote.archived,
      trashed: backupNote.trashed,
      position: backupNote.position,
      gridSpan: backupNote.gridSpan,
      stageId: backupNote.stageId == null
          ? null
          : stageIds[backupNote.stageId!],
      stagePosition: backupNote.stagePosition,
      reminderAt: backupNote.reminderAt?.toLocal(),
      reminderRepeat: backupNote.reminderRepeat,
      itemReminders: {
        for (final reminder in backupNote.itemReminders)
          if (itemIdMap[reminder.itemId] case final String itemId)
            if (restoredItems.any((item) => item.id == itemId && !item.done))
              itemId: ItemReminder(
                itemId: itemId,
                at: reminder.at.toLocal(),
                repeat: reminder.repeat,
              ),
      },
      createdAt: backupNote.createdAt,
      updatedAt: backupNote.updatedAt,
      labelIds: {
        for (final oldId in backupNote.labelIds)
          if (labelIds[oldId] case final String newId) newId,
      },
      owner: _owner,
    );
  }

  /// Add [archive]'s notes to [collectionId] in [workspaceId], placing them in
  /// front of [frontPosition]. A label is matched to [existingLabels] by name,
  /// ignoring case, and created when there is none.
  Future<KeepImportResult> importKeep(
    KeepArchive archive, {
    required String workspaceId,
    required String collectionId,
    required List<Label> existingLabels,
    required double frontPosition,
    KeepTrash trash = KeepTrash.skip,
    BackupProgress? onProgress,
  }) async {
    // Oldest first, each placed ahead of the last, so the most recently
    // edited note ends up at the front as it was in Keep.
    final notes = [
      for (final note in archive.notes)
        if (trash == KeepTrash.include || !note.trashed) note,
    ]..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final total = notes.fold<int>(
      0,
      (count, note) => count + 1 + note.attachments.length,
    );
    final labelIds = {
      for (final label in existingLabels) label.name.toLowerCase(): label.id,
    };
    var position = frontPosition;
    var completed = 0;
    var importedNotes = 0;
    var importedAttachments = 0;
    var createdLabels = 0;

    try {
      for (final keep in notes) {
        final noteLabels = <String>{};
        for (final name in keep.labels) {
          var id = labelIds[name.toLowerCase()];
          if (id == null) {
            id = _uuid.v4();
            await _api.createLabel(id, name, workspaceId: workspaceId);
            labelIds[name.toLowerCase()] = id;
            createdLabels++;
          }
          noteLabels.add(id);
        }

        final note = Note(
          id: _uuid.v4(),
          workspaceId: workspaceId,
          collectionId: collectionId,
          kind: keep.kind,
          title: keep.title,
          content: keep.content,
          items: [
            for (final item in keep.items)
              ChecklistItem(id: _uuid.v4(), text: item.text, done: item.done),
          ],
          color: keep.color,
          pinned: keep.pinned,
          archived: keep.archived,
          trashed: keep.trashed,
          position: position,
          createdAt: keep.createdAt,
          updatedAt: keep.updatedAt,
          labelIds: noteLabels,
          owner: _owner,
        );
        position -= kPositionGap;
        await _api.createNote(note, preserveTimestamps: true);
        importedNotes++;
        onProgress?.call(++completed, total);

        for (final attachment in keep.attachments) {
          await _api.uploadAttachment(
            note.id,
            attachment.bytes,
            attachment.mime,
            attachment.filename,
          );
          importedAttachments++;
          onProgress?.call(++completed, total);
        }
      }
      return KeepImportResult(
        notes: importedNotes,
        attachments: importedAttachments,
        labels: createdLabels,
      );
    } catch (error) {
      final message = error is ApiException
          ? error.serverMessage
          : 'Import could not be completed';
      throw BackupRestoreException(message, restoredNotes: importedNotes);
    }
  }
}
