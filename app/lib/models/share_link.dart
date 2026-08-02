import 'note.dart';

/// What a public link points at. The wire values are shared with the backend
/// (`models.rs`, `SHARE_TARGETS`).
enum ShareTarget {
  note('note', 'Note'),
  notes('notes', 'Notes'),
  board('board', 'Board'),
  label('label', 'Label');

  final String wire;

  /// How the target reads in the manage list ("Board", "Note").
  final String noun;

  const ShareTarget(this.wire, this.noun);

  static ShareTarget? fromWire(String? value) {
    for (final target in values) {
      if (target.wire == value) return target;
    }
    return null;
  }
}

/// A public link as its owner sees it: enough to show the row, copy the URL,
/// and revoke it. The token is the capability, so this only ever comes back
/// over an authenticated request.
class ShareLink {
  final String token;
  final ShareTarget target;
  final String? noteId;
  final String? workspaceId;
  final String? labelId;

  /// Server-resolved name of what the link points at.
  final String title;
  final DateTime createdAt;
  final DateTime? expiresAt;

  const ShareLink({
    required this.token,
    required this.target,
    required this.title,
    required this.createdAt,
    this.noteId,
    this.workspaceId,
    this.labelId,
    this.expiresAt,
  });

  /// The path a browser opens. Resolved against the server's own origin by
  /// [publicShareUrl]; kept relative here because the same link is valid from
  /// any host that serves this backend.
  String get path => '/s/$token';

  factory ShareLink.fromJson(Map<String, dynamic> json) => ShareLink(
    token: json['token'] as String,
    target: ShareTarget.fromWire(json['target'] as String?) ?? ShareTarget.note,
    noteId: json['note_id'] as String?,
    workspaceId: json['workspace_id'] as String?,
    labelId: json['label_id'] as String?,
    title: json['title'] as String? ?? '',
    createdAt:
        DateTime.tryParse(json['created_at'] as String? ?? '') ??
        DateTime.now(),
    expiresAt: json['expires_at'] == null
        ? null
        : DateTime.tryParse(json['expires_at'] as String)?.toLocal(),
  );
}

/// The full URL to hand out, built from the backend's origin. The Rust binary
/// serves the app, so `/s/<token>` on that origin is the page.
String publicShareUrl(String baseUrl, ShareLink link) =>
    '${baseUrl.replaceAll(RegExp(r'/+$'), '')}${link.path}';

/// Everything behind a public link. Read-only by construction: there is no
/// note id to patch, no owner, and no store, only what the page draws.
class PublicShare {
  final ShareTarget target;

  /// The note's title, the workspace's name, or the label's name.
  final String title;

  /// Display name of whoever published the link.
  final String sharedBy;
  final List<Note> notes;
  final List<Label> labels;
  final List<Stage> stages;
  final DateTime? expiresAt;

  const PublicShare({
    required this.target,
    required this.title,
    required this.sharedBy,
    required this.notes,
    this.labels = const [],
    this.stages = const [],
    this.expiresAt,
  });

  factory PublicShare.fromJson(Map<String, dynamic> json) => PublicShare(
    target: ShareTarget.fromWire(json['target'] as String?) ?? ShareTarget.note,
    title: json['title'] as String? ?? '',
    sharedBy: json['shared_by'] as String? ?? '',
    // The payload's notes carry only public fields, but they are a strict
    // subset of the note wire format, so the existing parser reads them and
    // the same cards can draw them.
    notes: ((json['notes'] as List?) ?? const [])
        .map((j) => Note.fromJson(j as Map<String, dynamic>))
        .toList(),
    labels: ((json['labels'] as List?) ?? const [])
        .map((j) => Label.fromJson(j as Map<String, dynamic>))
        .toList(),
    stages: ((json['stages'] as List?) ?? const [])
        .map((j) => Stage.fromJson(j as Map<String, dynamic>))
        .toList(),
    expiresAt: json['expires_at'] == null
        ? null
        : DateTime.tryParse(json['expires_at'] as String)?.toLocal(),
  );
}
