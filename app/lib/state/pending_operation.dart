/// The backend write represented by a persisted queue entry.
enum PendingOpKind {
  create('create'),
  patch('patch'),
  delete('delete'),
  reorder('reorder'),
  labelCreate('labelCreate'),
  labelUpdate('labelUpdate'),
  labelDelete('labelDelete'),
  stageCreate('stageCreate'),
  stageUpdate('stageUpdate'),
  stageDelete('stageDelete'),
  workspaceCreate('workspaceCreate'),
  workspaceRename('workspaceRename'),
  workspaceViews('workspaceViews'),
  workspaceDelete('workspaceDelete'),
  leaveWorkspace('leaveWorkspace'),
  removeCollaborator('removeCollaborator'),
  itemReminder('itemReminder'),
  deleteAttachment('deleteAttachment'),
  transcribe('transcribe'),
  unknown('unknown');

  final String wireName;

  const PendingOpKind(this.wireName);

  static PendingOpKind fromWire(String value) {
    for (final kind in values) {
      if (kind.wireName == value) return kind;
    }
    return unknown;
  }
}

/// A serializable backend write that can survive an app restart.
class PendingOp {
  final PendingOpKind kind;
  final String? id;
  final Map<String, dynamic> data;

  const PendingOp(this.kind, {this.id, this.data = const {}});

  Map<String, dynamic> toJson() => {
    'kind': kind.wireName,
    if (id != null) 'id': id,
    if (data.isNotEmpty) 'data': data,
  };

  factory PendingOp.fromJson(Map<String, dynamic> json) => PendingOp(
    PendingOpKind.fromWire(json['kind'] as String? ?? ''),
    id: json['id'] as String?,
    data: (json['data'] as Map?)?.cast<String, dynamic>() ?? const {},
  );
}
