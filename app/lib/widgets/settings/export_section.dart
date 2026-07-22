import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../models/note.dart';
import '../../state/notes_store.dart';
import '../../util/backup.dart';
import '../../util/download.dart';
import '../../util/note_export.dart';
import '../../util/snack.dart';
import '../file_drop.dart';

/// Human-readable exports plus a portable zip backup/restore that includes
/// attachment bytes. All paths are shared by web, desktop, Android, and iOS:
/// only file picking/downloading is platform-adapted underneath.
class ExportSection extends StatefulWidget {
  const ExportSection({super.key});

  @override
  State<ExportSection> createState() => _ExportSectionState();
}

class _ExportSectionState extends State<ExportSection> {
  bool _busy = false;
  String? _status;
  double? _progress;

  void _exportText(ExportFormat format) {
    final store = context.read<NotesStore>();
    final notes = store.notesForExport;
    if (notes.isEmpty) {
      showAppSnack('No notes to export');
      return;
    }
    final content = exportNotes(notes, format, labels: store.labels);
    downloadTextFile(exportFilename(format), content, format.mime);
    final count = notes.length;
    showAppSnack(
      'Exported $count ${count == 1 ? 'note' : 'notes'} as ${format.label}',
    );
  }

  Future<Uint8List> _readAttachment(
    NotesStore store,
    Attachment attachment,
  ) async {
    final response = await http
        .get(Uri.parse(store.fileUrl(attachment)))
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw StateError(
        "Couldn't download ${attachment.filename.isEmpty ? 'an attachment' : attachment.filename}",
      );
    }
    return response.bodyBytes;
  }

  Future<void> _exportBackup() async {
    final store = context.read<NotesStore>();
    final notes = store.notesForExport;
    if (notes.isEmpty && store.labels.isEmpty) {
      showAppSnack('Nothing to back up');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Preparing backup…';
      _progress = null;
    });
    try {
      final bytes = await createBackupArchive(
        notes: notes,
        labels: store.labels,
        readAttachment: (attachment) => _readAttachment(store, attachment),
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _status = 'Adding files… $done of $total';
            _progress = total == 0 ? null : done / total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _status = 'Saving backup…';
        _progress = null;
      });
      await downloadBytesFile(backupFilename(), bytes, 'application/zip');
      if (mounted) {
        showAppSnack(
          'Backup created with ${notes.length} '
          '${notes.length == 1 ? 'note' : 'notes'}',
          icon: Icons.inventory_2_outlined,
        );
      }
    } catch (error) {
      if (mounted) {
        showAppSnack(
          error is StateError
              ? error.message.toString()
              : "Couldn't create the backup",
          icon: Icons.error_outline,
          kind: SnackKind.danger,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _restoreBackup() async {
    final picked = await pickAnyFiles();
    if (!mounted || picked.isEmpty) return;
    final file = picked.first;

    final BackupBundle backup;
    try {
      backup = parseBackupArchive(file.bytes);
    } on FormatException catch (error) {
      showAppSnack(
        error.message,
        icon: Icons.error_outline,
        kind: SnackKind.danger,
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore this backup?'),
        content: Text(
          'This will add ${backup.notes.length} '
          '${backup.notes.length == 1 ? 'note' : 'notes'}, '
          '${backup.labels.length} '
          '${backup.labels.length == 1 ? 'label' : 'labels'}, and '
          '${backup.attachmentCount} '
          '${backup.attachmentCount == 1 ? 'file' : 'files'}.\n\n'
          'Nothing currently in your account will be deleted. Shared notes '
          'are restored as private copies. Notes whose IDs are already in '
          'your account are skipped.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.settings_backup_restore),
            label: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _status = 'Restoring backup…';
      _progress = 0;
    });
    try {
      final result = await context.read<NotesStore>().restoreBackup(
        backup,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _status = 'Restoring… $done of $total';
            _progress = total == 0 ? null : done / total;
          });
        },
      );
      if (mounted) {
        showAppSnack(
          'Restored ${result.notes} '
          '${result.notes == 1 ? 'note' : 'notes'} and '
          '${result.attachments} '
          '${result.attachments == 1 ? 'file' : 'files'}'
          '${result.skippedNotes == 0 ? '' : '; skipped ${result.skippedNotes} already present'}',
          icon: Icons.check_circle_outline,
        );
      }
    } on BackupRestoreException catch (error) {
      if (mounted) {
        final partial = error.restoredNotes == 0
            ? error.message
            : '${error.message}. ${error.restoredNotes} notes were restored '
                  'before it stopped.';
        showAppSnack(
          partial,
          icon: Icons.error_outline,
          kind: SnackKind.danger,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
          _progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final store = context.watch<NotesStore>();
    final count = store.notesForExport.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            'Create a complete zip backup of your notes, labels, reminders, '
            'and attached files, or restore one into this account. Archived '
            'notes are included; trash and collaborators are not. Reading '
            'formats exclude attached file bytes.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.inventory_2_outlined, size: 18),
                label: const Text('Create backup'),
                onPressed: _busy ? null : _exportBackup,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.settings_backup_restore, size: 18),
                label: const Text('Restore backup'),
                onPressed: _busy ? null : _restoreBackup,
              ),
              for (final format in ExportFormat.values)
                OutlinedButton.icon(
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: Text(format.label),
                  onPressed: _busy || count == 0
                      ? null
                      : () => _exportText(format),
                ),
            ],
          ),
        ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_status!, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: _progress),
              ],
            ),
          ),
      ],
    );
  }
}
