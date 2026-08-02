import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../screens/editor_screen.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/motion.dart';
import '../util/snack.dart';
import 'recording_sheet.dart';

/// FABs that morph into the editor via container transform: a mini one for a
/// new checklist, the main one for a new text note.
class NewNoteFabs extends StatelessWidget {
  /// Labels every note these buttons create, set when a label view is open,
  /// so writing a note there keeps it in the view you wrote it in. This is the
  /// only way to compose into a label on a phone (no quick-add bar there).
  final Set<String> labelIds;

  const NewNoteFabs({super.key, this.labelIds = const {}});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final transcriptionAvailable = context
        .watch<SettingsStore>()
        .audioTranscriptionCapable;

    Widget fab({
      required double size,
      required IconData icon,
      required Color color,
      required Color onColor,
      required NoteKind kind,
      required String tooltip,
    }) {
      return Tooltip(
        message: tooltip,
        child: _HoverLift(
          child: OpenContainer<void>(
            transitionDuration: Motion.slow,
            transitionType: ContainerTransitionType.fade,
            closedElevation: 4,
            closedColor: color,
            middleColor: scheme.surface,
            openColor: scheme.surface,
            closedShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadius),
            ),
            tappable: false,
            closedBuilder: (context, open) => InkWell(
              customBorder: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kRadius),
              ),
              onTap: () => openNoteEditor(
                context,
                openFullscreen: open,
                kind: kind,
                labelIds: labelIds,
                sourceRect: morphSourceRect(context),
              ),
              child: SizedBox(
                width: size,
                height: size,
                child: Icon(icon, size: size / 2, color: onColor),
              ),
            ),
            openBuilder: (context, close) =>
                EditorScreen(noteId: null, kind: kind, labelIds: labelIds),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _AudioNoteFab(
          labelIds: labelIds,
          transcriptionAvailable: transcriptionAvailable,
        ),
        const SizedBox(height: 12),
        fab(
          size: 44,
          icon: Icons.article_outlined,
          color: scheme.surfaceContainerHigh,
          onColor: scheme.onSurfaceVariant,
          kind: NoteKind.markdown,
          tooltip: 'New markdown note',
        ),
        const SizedBox(height: 12),
        fab(
          size: 44,
          icon: Icons.check_box_outlined,
          color: scheme.surfaceContainerHigh,
          onColor: scheme.onSurfaceVariant,
          kind: NoteKind.checklist,
          tooltip: 'New checklist',
        ),
        const SizedBox(height: 12),
        fab(
          size: 56,
          icon: Icons.add,
          color: scheme.primaryContainer,
          onColor: scheme.onPrimaryContainer,
          kind: NoteKind.text,
          tooltip: 'New note',
        ),
      ],
    );
  }
}

/// Mic FAB: records a clip in a focused sheet, then drops it into a new audio
/// note. Transcription is requested only when the optional Whisper service is
/// connected; recording and playback never depend on that service.
class _AudioNoteFab extends StatelessWidget {
  final Set<String> labelIds;
  final bool transcriptionAvailable;
  const _AudioNoteFab({
    this.labelIds = const {},
    required this.transcriptionAvailable,
  });

  Future<void> _record(BuildContext context) async {
    final store = context.read<NotesStore>();
    final clip = await RecordingSheet.show(context);
    if (clip == null) return;
    final id = await store.createAudioNote(
      clip.bytes,
      clip.mime,
      labelIds: labelIds,
      transcriptionAvailable: transcriptionAvailable,
    );
    if (id == null) showAppSnack("Couldn't save the recording");
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'New audio note',
      child: _HoverLift(
        child: Material(
          color: scheme.surfaceContainerHigh,
          elevation: 4,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadius),
          ),
          child: InkWell(
            onTap: () => _record(context),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                Icons.mic_none,
                size: 22,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Subtle hover feedback for the note-creation FABs: the button scales up a
/// touch under the pointer. Pointer-only by nature, touch never hovers.
class _HoverLift extends StatefulWidget {
  final Widget child;
  const _HoverLift({required this.child});

  @override
  State<_HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<_HoverLift> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: _hovered ? 1.06 : 1.0,
        duration: Motion.fast,
        curve: Motion.standard,
        child: widget.child,
      ),
    );
  }
}
