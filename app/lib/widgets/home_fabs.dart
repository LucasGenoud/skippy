import 'dart:async';

import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../screens/editor_screen.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/motion.dart';
import '../util/snack.dart';
import 'note_zoom.dart';
import 'recording_sheet.dart';

/// The note-creation button. One button at rest, so nothing covers the grid;
/// tapping it unfolds the kinds of note above it:
///
///         [ mic  Audio     ]
///         [ doc  Markdown  ]
///         [ box  Checklist ]
///         [ pen  Note      ]
///                       [x]
///
/// Each kind grows into its editor from where it sits. The kinds stay mounted
/// while folded, so a note closing back into its button has somewhere to land.
class NewNoteFabs extends StatefulWidget {
  /// Labels every note these buttons create, set when a label view is open,
  /// so writing a note there keeps it in the view you wrote it in. This is the
  /// only way to compose into a label on a phone (no quick-add bar there).
  final Set<String> labelIds;

  const NewNoteFabs({super.key, this.labelIds = const {}});

  @override
  State<NewNoteFabs> createState() => _NewNoteFabsState();
}

class _NewNoteFabsState extends State<NewNoteFabs>
    with SingleTickerProviderStateMixin {
  /// How far into the unfold each kind starts after the one below it.
  static const double _stagger = 0.12;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.base,
    reverseDuration: Motion.fast,
  );
  bool _open = false;
  Timer? _foldTimer;

  @override
  void dispose() {
    _foldTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _setOpen(bool open) {
    _foldTimer?.cancel();
    if (_open == open) {
      return;
    }

    setState(() => _open = open);
    if (Motion.reduced(context)) {
      _controller.value = open ? 1 : 0;
    } else if (open) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  // Folded once the editor has grown over the menu, so the kind it grew
  // from holds still while the morph reads its position.
  void _foldAfterOpening() {
    _foldTimer?.cancel();
    _foldTimer = Timer(Motion.slow, () {
      if (mounted) {
        _setOpen(false);
      }
    });
  }

  /// The [index]th kind up from the button: fades in and rises into place,
  /// a beat after the one below it; folding runs the same steps backwards.
  /// Never scaled: the morph lays the kind's face out at its on-screen size.
  Widget _unfolding(int index, Widget child) {
    final start = index * _stagger;
    final animation = CurvedAnimation(
      parent: _controller,
      curve: Interval(
        start,
        start + 1 - 3 * _stagger,
        curve: Motion.emphasized,
      ),
    );
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.25),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    );
  }

  Widget _noteKind(IconData icon, String label, NoteKind kind) {
    final scheme = Theme.of(context).colorScheme;
    return NoteZoom(
      closedElevation: 3,
      closedColor: scheme.surface,
      openColor: scheme.surface,
      closedShape: kRoundedShape,
      closedBuilder: (context, open) => InkWell(
        customBorder: kRoundedShape,
        onTap: () {
          openNoteEditor(
            context,
            openFullscreen: open,
            kind: kind,
            labelIds: widget.labelIds,
            sourceRect: morphSourceRect(context),
          );
          _foldAfterOpening();
        },
        child: _KindFace(icon: icon, label: label),
      ),
      openBuilder: (context) =>
          EditorScreen(noteId: null, kind: kind, labelIds: widget.labelIds),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final transcriptionAvailable = context
        .watch<SettingsStore>()
        .audioTranscriptionCapable;

    // Top to bottom, so the kind nearest the button is the last one here.
    final kinds = [
      _AudioNoteFab(
        labelIds: widget.labelIds,
        transcriptionAvailable: transcriptionAvailable,
        onRecord: () => _setOpen(false),
      ),
      _noteKind(Icons.article_outlined, 'Markdown', NoteKind.markdown),
      _noteKind(Icons.check_box_outlined, 'Checklist', NoteKind.checklist),
      _noteKind(Icons.edit_outlined, 'Note', NoteKind.text),
    ];

    return TapRegion(
      onTapOutside: (_) => _setOpen(false),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IgnorePointer(
            ignoring: !_open,
            child: ExcludeSemantics(
              excluding: !_open,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < kinds.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: kSpaceSm),
                      child: _unfolding(kinds.length - 1 - i, kinds[i]),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: kSpaceXs),
          Tooltip(
            message: _open ? 'Close' : 'New note',
            child: _HoverLift(
              child: Material(
                color: scheme.primaryContainer,
                elevation: 4,
                clipBehavior: Clip.antiAlias,
                shape: kRoundedShape,
                child: InkWell(
                  onTap: () => _setOpen(!_open),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    // A quarter of a half turn: the plus becomes a cross.
                    child: RotationTransition(
                      turns: Tween(begin: 0.0, end: 0.125).animate(
                        CurvedAnimation(
                          parent: _controller,
                          curve: Motion.emphasized,
                        ),
                      ),
                      child: Icon(
                        Icons.add,
                        size: 28,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A kind's face: its icon and name on a raised pill, sized for a thumb.
class _KindFace extends StatelessWidget {
  final IconData icon;
  final String label;

  const _KindFace({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: kSpaceLg),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: kCompactIconSize, color: scheme.onSurfaceVariant),
            const SizedBox(width: kSpaceMd),
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Audio: records a clip in a focused sheet, then drops it into a new audio
/// note. Transcription is requested only when the optional Whisper service is
/// connected; recording and playback never depend on that service.
class _AudioNoteFab extends StatelessWidget {
  final Set<String> labelIds;
  final bool transcriptionAvailable;

  /// Folds the menu the sheet opens over.
  final VoidCallback onRecord;

  const _AudioNoteFab({
    this.labelIds = const {},
    required this.transcriptionAvailable,
    required this.onRecord,
  });

  Future<void> _record(BuildContext context) async {
    final store = context.read<NotesStore>();
    onRecord();
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
    return Material(
      color: scheme.surface,
      elevation: 3,
      clipBehavior: Clip.antiAlias,
      shape: kRoundedShape,
      child: InkWell(
        onTap: () => _record(context),
        child: const _KindFace(icon: Icons.mic_none, label: 'Audio'),
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
