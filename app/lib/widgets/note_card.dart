import 'package:animations/animations.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../screens/editor_screen.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import 'link_preview.dart';
import 'linked_text.dart';
import 'transcribing_indicator.dart';
import '../util/highlight.dart';
import '../util/linkify.dart';
import '../util/note_image.dart';
import '../util/motion.dart';
import '../util/platform.dart';

/// A note in the grid. The whole tile is an [OpenContainer], so tapping it
/// morphs the card into the editor (Keep's signature transition).
class NoteTile extends StatefulWidget {
  final Note note;

  /// The active search query, used to highlight matches. Empty when not
  /// searching.
  final String query;
  const NoteTile({super.key, required this.note, this.query = ''});

  @override
  State<NoteTile> createState() => _NoteTileState();
}

class _NoteTileState extends State<NoteTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    // select, not watch: the tile only re-renders when its own resolved
    // fill changes, instead of on every settings notification.
    final fill = context.select<SettingsStore, Color?>(
      (s) => s.resolveColor(note.color, brightness),
    );
    final borderColor = fill == null
        ? scheme.outlineVariant
        : (_hovered
              ? scheme.outlineVariant.withValues(alpha: 0.5)
              : Colors.transparent);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.standard,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadius),
          boxShadow: [
            // A whisper of shadow at rest lifts the card off the grey canvas;
            // it deepens on hover for a tactile response.
            BoxShadow(
              color: Colors.black.withValues(alpha: _hovered ? 0.16 : 0.05),
              blurRadius: _hovered ? 14 : 4,
              offset: Offset(0, _hovered ? 5 : 1),
            ),
          ],
        ),
        child: OpenContainer<void>(
          transitionDuration: Motion.slow,
          transitionType: ContainerTransitionType.fade,
          closedElevation: 0,
          openElevation: 0,
          closedColor: fill ?? scheme.surface,
          middleColor: fill ?? scheme.surface,
          openColor: fill ?? scheme.surface,
          closedShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadius),
            side: BorderSide(color: borderColor),
          ),
          // Tap handling is ours: wide layouts open a centered modal
          // instead of letting the container expand fullscreen.
          tappable: false,
          closedBuilder: (context, open) => InkWell(
            borderRadius: BorderRadius.circular(kRadius),
            onTap: () =>
                openNoteEditor(context, openFullscreen: open, noteId: note.id),
            // The pin overlay is the only hover-dependent piece, and it sits
            // outside _NoteCardContent so hover flips never rebuild the card
            // body (markdown parse, image resolve).
            child: Stack(
              children: [
                _NoteCardContent(note: note, query: widget.query),
                _PinButton(note: note, hovered: _hovered),
              ],
            ),
          ),
          openBuilder: (context, close) => EditorScreen(noteId: note.id),
        ),
      ),
    );
  }
}

class _NoteCardContent extends StatelessWidget {
  final Note note;
  final String query;
  const _NoteCardContent({required this.note, this.query = ''});

  @override
  Widget build(BuildContext context) {
    // read for URL building; select for the one store-derived value (label
    // names) so the card body doesn't rebuild on every store notification.
    final store = context.read<NotesStore>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Joined with an unprintable separator (label names may contain spaces)
    // because select needs a value with a meaningful == — a freshly built
    // List never equals the previous one.
    final joinedLabels = context.select<NotesStore, String>(
      (s) =>
          ([
            for (final id in note.labelIds)
              if (s.labelById(id) case final Label label) label.name,
          ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))).join(
            '\u0000',
          ),
    );
    final labels = joinedLabels.isEmpty
        ? const <String>[]
        : joinedLabels.split('\u0000');

    final visibleItems = note.items
        .where((i) => i.text.trim().isNotEmpty)
        .toList();
    final unchecked = visibleItems.where((i) => !i.done).toList();
    final checked = visibleItems.where((i) => i.done).toList();
    final previewItems = unchecked.take(8).toList();

    final images = note.attachments.where((a) => a.isImage).toList();
    // Audio clips are represented by the audio note's own player, not a chip.
    final files = note.attachments
        .where((a) => !a.isImage && !a.isAudio)
        .toList();

    // A single rich preview for the note's first link (grid space is tight).
    final linkMatches = findUrls('${note.title}\n${note.content}');
    final firstLinkUrl = linkMatches.isEmpty ? null : linkMatches.first.url;

    final hasTextBlock =
        note.title.isNotEmpty ||
        note.isAudio ||
        (!note.isChecklist && note.content.isNotEmpty) ||
        (note.isChecklist && visibleItems.isNotEmpty) ||
        note.isEmpty; // truly empty draft shows the placeholder
    final hasFooter =
        note.reminderAt != null ||
        labels.isNotEmpty ||
        files.isNotEmpty ||
        note.isShared;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasTextBlock)
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              images.isNotEmpty || hasFooter
                  ? 0
                  : (firstLinkUrl != null ? 12 : 16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (note.title.isNotEmpty)
                  Padding(
                    // Always reserve room for the pin button (it appears
                    // on hover): tying this to hover made titles reflow
                    // under the cursor.
                    padding: EdgeInsets.only(right: note.trashed ? 0 : 28),
                    child: Text.rich(
                      TextSpan(
                        children: highlightSpans(
                          note.title,
                          query,
                          highlight: TextStyle(
                            backgroundColor: scheme.primary.withValues(
                              alpha: 0.30,
                            ),
                          ),
                        ),
                      ),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (note.title.isNotEmpty &&
                    (note.content.isNotEmpty || previewItems.isNotEmpty))
                  const SizedBox(height: 8),
                if (note.isAudio) ...[
                  if (note.title.isNotEmpty) const SizedBox(height: 8),
                  const _AudioPill(),
                  if (note.transcribing)
                    const Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: TranscribingIndicator(compact: true),
                    )
                  else if (note.transcriptFailed)
                    const Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: TranscriptFailed(compact: true),
                    )
                  else if (note.content.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: LinkedText(
                        text: note.content,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.45,
                        ),
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ] else if (note.kind == NoteKind.markdown &&
                    note.content.isNotEmpty)
                  // Rendered markdown preview, clipped like long text.
                  // The never-scrollable scroll view absorbs the
                  // unbounded height so tall content clips without a
                  // layout overflow.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: ClipRect(
                      child: IgnorePointer(
                        child: SingleChildScrollView(
                          physics: const NeverScrollableScrollPhysics(),
                          child: _MarkdownPreview(content: note.content),
                        ),
                      ),
                    ),
                  )
                else if (!note.isChecklist && note.content.isNotEmpty)
                  LinkedText(
                    text: note.content,
                    query: query,
                    highlight: TextStyle(
                      backgroundColor: scheme.primary.withValues(alpha: 0.30),
                    ),
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                    maxLines: 10,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (note.isChecklist) ...[
                  for (final item in previewItems)
                    _ChecklistRow(note: note, item: item),
                  if (unchecked.length > previewItems.length)
                    Padding(
                      padding: const EdgeInsets.only(left: 28, top: 2),
                      child: Text(
                        '+ ${unchecked.length - previewItems.length} more',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (checked.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: unchecked.isEmpty ? 0 : 6),
                      child: Text(
                        '${checked.length} checked ${checked.length == 1 ? 'item' : 'items'}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
                if (note.isEmpty)
                  Text(
                    'Empty note',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        // Images sit under the text (full bleed), chips under the images.
        if (images.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: hasTextBlock ? 12 : 0),
            child: _ImageStrip(
              images: images,
              store: store,
              borderRadius: BorderRadius.vertical(
                top: hasTextBlock ? Radius.zero : kRadiusCorner,
                bottom: hasFooter || firstLinkUrl != null
                    ? Radius.zero
                    : kRadiusCorner,
              ),
            ),
          ),
        if (hasFooter)
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              hasTextBlock || images.isNotEmpty ? 12 : 16,
              16,
              firstLinkUrl != null ? 12 : 16,
            ),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (note.reminderAt != null)
                  _ReminderChip(reminderAt: note.reminderAt!),
                for (final file in files.take(2)) _FileChip(file: file),
                if (files.length > 2)
                  _LabelChip(name: '+${files.length - 2} files'),
                for (final name in labels.take(3)) _LabelChip(name: name),
                if (labels.length > 3)
                  _LabelChip(name: '+${labels.length - 3}'),
                if (note.isShared)
                  Tooltip(
                    message: _sharedTooltip(note),
                    child: Icon(
                      Icons.people_alt_outlined,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        // The link preview is a full-bleed strip attached to the bottom of the
        // card — a continuation of the note square, not a card floating inside
        // it. Bottom corners follow the card; a hairline divides it from the
        // note body above.
        if (firstLinkUrl != null)
          LinkPreviewCard(
            url: firstLinkUrl,
            topDivider: true,
            borderRadius: const BorderRadius.vertical(
              bottom: kRadiusCorner,
            ),
          ),
      ],
    );
  }

  String _sharedTooltip(Note note) {
    final names = [
      if (note.owner != null) note.owner!.username,
      ...note.collaborators.map((c) => c.username),
    ];
    return 'Shared with ${names.join(', ')}';
  }
}

/// Pin control overlaying the card's top-right corner: revealed on hover
/// (web/desktop), always shown when pinned so its state is visible at a
/// glance. Lives beside — not inside — [_NoteCardContent] so hover flips
/// only touch this small overlay, never the card body.
class _PinButton extends StatelessWidget {
  final Note note;
  final bool hovered;
  const _PinButton({required this.note, required this.hovered});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final show = !note.trashed && (hovered || note.pinned);
    return Positioned(
      top: 4,
      right: 4,
      child: AnimatedOpacity(
        opacity: show ? 1 : 0,
        duration: Motion.fast,
        curve: Motion.standard,
        child: IgnorePointer(
          ignoring: !show,
          child: IconButton(
            // A little scale-pop when the pin state flips, so the action
            // reads as tactile rather than an instant glyph swap.
            icon: AnimatedSwitcher(
              duration: Motion.fast,
              switchInCurve: Curves.easeOutBack,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) =>
                  ScaleTransition(scale: animation, child: child),
              child: Icon(
                note.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                key: ValueKey(note.pinned),
                size: 20,
              ),
            ),
            color: scheme.onSurfaceVariant,
            tooltip: note.pinned ? 'Unpin note' : 'Pin note',
            onPressed: () => context.read<NotesStore>().togglePin(note.id),
          ),
        ),
      ),
    );
  }
}

/// Markdown parses its whole AST inside MarkdownBody.build — far too heavy
/// to re-run every time the grid rebuilds. Returning the previously built
/// instance when content and theme are unchanged makes Flutter skip the
/// subtree entirely (identical widget == no rebuild).
class _MarkdownPreview extends StatefulWidget {
  final String content;
  const _MarkdownPreview({required this.content});

  @override
  State<_MarkdownPreview> createState() => _MarkdownPreviewState();
}

class _MarkdownPreviewState extends State<_MarkdownPreview> {
  Widget? _built;
  String? _builtContent;
  ThemeData? _builtTheme;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_built == null ||
        _builtContent != widget.content ||
        _builtTheme != theme) {
      _builtContent = widget.content;
      _builtTheme = theme;
      _built = MarkdownBody(
        data: widget.content,
        styleSheet: MarkdownStyleSheet.fromTheme(
          theme,
        ).copyWith(p: theme.textTheme.bodyMedium?.copyWith(height: 1.45)),
      );
    }
    return _built!;
  }
}

/// Checkbox rows on the card itself. Only the checkbox is tappable so
/// checking an item from the grid never opens the editor; the rest of the
/// row still opens the note. On the web (any device) and desktop apps the
/// checkbox toggles in place; on native mobile it stays inert so the whole
/// tap opens the editor (avoids accidental checks on a tiny grid target).
class _ChecklistRow extends StatelessWidget {
  final Note note;
  final ChecklistItem item;
  const _ChecklistRow({required this.note, required this.item});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canToggle = !note.trashed && (kIsWeb || !isTouchPrimaryPlatform);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Enlarge the checkbox hit target without growing the visible icon.
          SizedBox(
            width: 18,
            height: 18,
            child: InkWell(
              onTap: canToggle
                  ? () => context.read<NotesStore>().toggleChecklistItem(
                      note.id,
                      item.id,
                    )
                  : null,
              borderRadius: BorderRadius.circular(kRadius),
              // Checking an item pops the box and fades the text toward its
              // done color, instead of both flipping on the same frame.
              child: AnimatedSwitcher(
                duration: Motion.fast,
                switchInCurve: Curves.easeOutBack,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: Icon(
                  item.done
                      ? Icons.check_box_outlined
                      : Icons.check_box_outline_blank,
                  key: ValueKey(item.done),
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: AnimatedDefaultTextStyle(
              duration: Motion.fast,
              curve: Motion.standard,
              style:
                  (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
                      .copyWith(
                        height: 1.35,
                        decoration: item.done
                            ? TextDecoration.lineThrough
                            : null,
                        color: item.done
                            ? scheme.onSurfaceVariant
                            : scheme.onSurface,
                      ),
              child: Text(
                item.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageStrip extends StatelessWidget {
  final List<Attachment> images;
  final NotesStore store;
  final BorderRadius borderRadius;
  const _ImageStrip({
    required this.images,
    required this.store,
    this.borderRadius = BorderRadius.zero,
  });

  @override
  Widget build(BuildContext context) {
    final first = images.first;
    final extra = images.length - 1;
    return ClipRRect(
      borderRadius: borderRadius,
      child: Stack(
        children: [
          // Grow to the image's aspect ratio (up to a cap) so image-forward
          // notes show as much of the picture as fits; SVGs render through the
          // vector path inside [NoteImage].
          NoteImage(
            attachment: first,
            url: store.fileUrl(first),
            maxHeight: 280,
          ),
          if (extra > 0)
            Positioned(
              right: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(kRadius),
                ),
                child: Text(
                  '+$extra',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReminderChip extends StatelessWidget {
  final DateTime reminderAt;
  const _ReminderChip({required this.reminderAt});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final past = reminderAt.isBefore(DateTime.now());
    // select: re-render only when the formatted label itself changes (date
    // or clock format edits), not on every settings notification.
    final label = context.select<SettingsStore, String>(
      (s) => s.reminderLabel(reminderAt),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadius),
        color: scheme.onSurface.withValues(alpha: 0.08),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.alarm, size: 13, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                decoration: past ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Non-image attachments show as a compact paperclip chip on the card.
class _FileChip extends StatelessWidget {
  final Attachment file;
  const _FileChip({required this.file});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      constraints: const BoxConstraints(maxWidth: 140),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadius),
        color: scheme.onSurface.withValues(alpha: 0.08),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.attach_file, size: 13, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              file.filename.isEmpty ? 'file' : file.filename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact "this is an audio note" affordance on a card; the real player lives
/// in the editor the card opens.
class _AudioPill extends StatelessWidget {
  const _AudioPill();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadius),
          color: scheme.onSurface.withValues(alpha: 0.06),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq, size: 15, color: scheme.primary),
            const SizedBox(width: 6),
            Text(
              'Audio',
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _LabelChip extends StatelessWidget {
  final String name;
  const _LabelChip({required this.name});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadius),
        border: Border.all(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Text(
        name,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}
