/// Client-side upload cap; the server allows slightly more (30 MB) so this
/// limit is always the one the user sees.
const int maxUploadBytes = 25 * 1024 * 1024;

const Map<String, String> _mimeByExtension = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'csv': 'text/csv',
  'json': 'application/json',
  'zip': 'application/zip',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'wav': 'audio/wav',
  'mp4': 'video/mp4',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
};

String mimeFromName(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return _mimeByExtension[ext] ?? 'application/octet-stream';
}

/// The reverse of [mimeFromName]: a file extension for a mime type, without
/// the dot. The table is walked in order so `image/jpeg` comes back as the
/// `jpg` it was written with; a type that isn't in it falls back to its
/// subtype (`image/heic` → `heic`, `image/svg+xml` → `svg`), which is right
/// often enough to be worth doing. Null when nothing sensible comes out.
String? extensionFromMime(String mime) {
  final lower = mime.trim().toLowerCase();
  for (final entry in _mimeByExtension.entries) {
    if (entry.value == lower) return entry.key;
  }
  final subtype = lower.split('/').last.split('+').first;
  return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(subtype) ? subtype : null;
}

/// Names browsers give clipboard content that has no name of its own. A pasted
/// screenshot is `image.png` in every one of them, so several in a row would
/// otherwise all land on the note under the same name.
const Set<String> _genericPastedNames = {'image', 'file', 'blob', 'unknown'};

/// Filename for something pasted onto a note. Keeps [suggested] when the
/// clipboard carried a real name (copying a file from the OS does), and
/// stamps a generated one when it didn't, so a run of pasted screenshots
/// stays distinguishable in the attachment list.
String pastedFileName(String mime, {String? suggested, DateTime? at}) {
  final name = (suggested ?? '').trim();
  final ext = extensionFromMime(mime);
  final dot = name.lastIndexOf('.');
  final stem = (dot <= 0 ? name : name.substring(0, dot)).toLowerCase();
  if (name.isNotEmpty && !_genericPastedNames.contains(stem)) return name;

  final t = at ?? DateTime.now();
  String pad(int value) => value.toString().padLeft(2, '0');
  final stamp =
      '${t.year}${pad(t.month)}${pad(t.day)}'
      '-${pad(t.hour)}${pad(t.minute)}${pad(t.second)}';
  return 'pasted-$stamp${ext == null ? '' : '.$ext'}';
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
