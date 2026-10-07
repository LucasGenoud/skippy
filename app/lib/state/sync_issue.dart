import 'pending_operation.dart';

/// A queued write the server refused for good. Kept, with the note as it
/// stood, so the user can copy their text out, retry, or dismiss it.
class SyncIssue {
  const SyncIssue(this.operation, this.message, this.statusCode, this.note);

  final PendingOp operation;
  final String message;
  final int statusCode;
  final Map<String, dynamic>? note;

  bool get isConflict =>
      statusCode == 409 && message == 'note changed elsewhere';

  String get label =>
      note?['title'] as String? ??
      operation.data['title'] as String? ??
      operation.kind.wireName;

  String? get copyText {
    final data = note ?? operation.data;
    if (operation.kind != PendingOpKind.create &&
        !data.containsKey('content') &&
        !data.containsKey('items')) {
      return null;
    }
    final items = data['items'] as List? ?? const [];
    return [
      data['title'] as String? ?? '',
      data['content'] as String? ?? '',
      for (final item in items)
        '${(item as Map)['done'] == true ? '☑' : '☐'} ${item['text']}',
    ].where((part) => part.isNotEmpty).join('\n');
  }

  Map<String, dynamic> toJson() => {
    'operation': operation.toJson(),
    'message': message,
    'status': statusCode,
    if (note != null) 'note': note,
  };

  factory SyncIssue.fromJson(Map<String, dynamic> json) => SyncIssue(
    PendingOp.fromJson((json['operation'] as Map).cast<String, dynamic>()),
    json['message'] as String? ?? 'Change was rejected',
    json['status'] as int? ?? 400,
    (json['note'] as Map?)?.cast<String, dynamic>(),
  );
}
