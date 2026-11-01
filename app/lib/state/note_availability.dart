import '../models/note.dart';
import '../models/workspace.dart';
import 'notes_store.dart';

/// Which actions a note offers right now. The card's menu and the editor's
/// menus both ask here, so they cannot disagree about what a note allows.
///
/// A null note is the editor's unsaved draft: nothing that needs a saved note
/// is offered yet, but it is live and its author owns it.
class NoteAvailability {
  final NotesStore _store;
  final Note? _note;

  const NoteAvailability(this._store, this._note);

  bool get _live => !(_note?.trashed ?? false);

  bool get _hasContent => !(_note?.isEmpty ?? true);

  /// An empty draft is thrown away on close, so filing it anywhere first
  /// would only make it outlive its editor.
  bool get _discardable => switch (_note) {
    final note? => _store.canAutoDiscard(note.id),
    null => true,
  };

  WorkspaceAi get _ai => _store.aiIn(_note?.workspaceId);

  /// Moving to Trash and moving between workspaces are the owner's calls.
  bool get isOwner => _note?.isOwnedBy(_store.currentUserId) ?? true;

  /// Colour, labels, reminders, files, sharing and conversion: everything
  /// except reading is off in Trash.
  bool get canEdit => _live;

  bool get canArchive => _live && !_discardable;

  bool get canTrash => _live && isOwner && !_discardable;

  bool get canCopy => _hasContent;

  bool get canDuplicate => _live && _hasContent;

  bool get canShowHistory => _hasContent;

  bool get canSetGridSpan => _live && _note != null;

  bool get canMoveToCollection =>
      _live && _store.workspaceById(_note?.workspaceId) != null;

  /// There has to be another workspace to move it to.
  bool get canMoveToWorkspace =>
      _live && _hasContent && isOwner && _store.workspaces.length > 1;

  /// Unlike workspaces, a column needs no second one to move to: "Unassigned"
  /// is always a destination, so this only asks that there be a board.
  bool get canMoveToStage =>
      _live && _hasContent && _store.stagesForNote(_note).isNotEmpty;

  /// AI editing follows the note's workspace: its switch, its owner's tasks.
  bool get canRewrite =>
      _live &&
      _hasContent &&
      !(_note?.isAudio ?? false) &&
      _ai.allows(AiFeature.writing) &&
      _ai.rewriteTasks.isNotEmpty;

  List<NoteRewriteTask> get rewriteTasks => _ai.rewriteTasks;

  /// A page summary is appended to the body, which checklists and audio
  /// notes do not have.
  bool get canSummarizeLinks =>
      _live &&
      !(_note?.isChecklist ?? false) &&
      !(_note?.isAudio ?? false) &&
      _ai.allows(AiFeature.writing);
}
