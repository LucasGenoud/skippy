import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/notes_store.dart';
import '../../util/download.dart';
import '../../util/note_export.dart';
import '../../util/snack.dart';

/// Bulk-export every note (excluding trash) to a downloaded file. Web only:
/// the download is a no-op on native builds, which the app never ships as.
class ExportSection extends StatelessWidget {
  const ExportSection({super.key});

  void _export(BuildContext context, ExportFormat format) {
    final store = context.read<NotesStore>();
    final notes = store.notesForExport;
    if (notes.isEmpty) {
      showAppSnack('No notes to export');
      return;
    }
    final content = exportNotes(notes, format, labels: store.labels);
    downloadTextFile(exportFilename(format), content, format.mime);
    final n = notes.length;
    showAppSnack('Exported $n ${n == 1 ? 'note' : 'notes'} as ${format.label}');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = context.watch<NotesStore>().notesForExport.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            'Download a copy of your $count '
            '${count == 1 ? 'note' : 'notes'} (archived included, trash '
            'excluded). JSON is a complete backup; Markdown and plain text '
            'are for reading and sharing.',
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
              for (final format in ExportFormat.values)
                OutlinedButton.icon(
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: Text(format.label),
                  onPressed: count == 0 ? null : () => _export(context, format),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
