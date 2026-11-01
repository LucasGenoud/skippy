part of '../note_card.dart';

// What a card shows of its note: title, body preview, checklist rows, images,
// files and the metadata chips under them.

class _NoteCardContent extends StatelessWidget {
  static const _maxSharedOwnerCharacters = 16;
  static const _maxAudioTranscriptLines = 12;
  static const _maxMarkdownPreviewHeight = 440.0;
  static const _maxTextPreviewLines = 20;
  static const _maxChecklistPreviewItems = 16;

  final Note note;
  final String query;
  final bool reserveActions;
  final bool showLabelsInBody;
  const _NoteCardContent({
    required this.note,
    this.query = '',
    this.reserveActions = false,
    this.showLabelsInBody = true,
  });

  static List<String> _linkPreviewUrls(Note note) =>
      linkPreviewUrls(noteLinkText(note));

  @override
  Widget build(BuildContext context) {
    // read for URL building; select for the one store-derived value (label
    // names) so the card body doesn't rebuild on every store notification.
    final store = context.read<NotesStore>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sharedBy = _sharedByLabel(note, store.currentUserId);
    // select, not read: the card rebuilds only when its own labels change.
    final labels = context
        .select<NotesStore, _CardLabels>((s) => _CardLabels.of(s, note))
        .tags;
    final locationReminderLabel = context.select<SettingsStore, String?>((s) {
      final reminder = s.locationReminderForNote(note.id);
      final location = s.savedLocationById(reminder?.locationId);
      if (reminder == null || location == null) return null;
      return '${reminder.label} · ${location.name}';
    });

    final visibleItems = note.items
        .where((i) => i.text.trim().isNotEmpty)
        .toList();
    final unchecked = visibleItems.where((i) => !i.done).toList();
    final checked = visibleItems.where((i) => i.done).toList();
    final previewItems = unchecked.take(_maxChecklistPreviewItems).toList();

    final images = note.attachments.where((a) => a.isImage).toList();
    // Audio clips are represented by the audio note's own player, not a chip.
    final files = note.attachments
        .where((a) => !a.isImage && !a.isAudio)
        .toList();
    // Narrow cards are read at a glance. Preserve the most useful metadata
    // (reminder, then one file and two labels) and summarize the rest instead
    // of letting a dense wrap push the note itself below the fold.
    final compactMetadata = !ScreenWidth.isAtLeast(context, kWideBreakpoint);
    final visibleFileCount = compactMetadata ? 1 : 2;
    final visibleLabelCount = compactMetadata ? 2 : 3;

    final linkPreviewUrls = _linkPreviewUrls(note);
    final hasLinkPreviews = linkPreviewUrls.isNotEmpty;

    final hasTextBlock =
        note.title.isNotEmpty ||
        note.isAudio ||
        (!note.isChecklist && note.content.isNotEmpty) ||
        (note.isChecklist && visibleItems.isNotEmpty) ||
        note.isEmpty; // truly empty draft shows the placeholder
    final hasFooter =
        note.reminderAt != null ||
        locationReminderLabel != null ||
        (showLabelsInBody && labels.isNotEmpty) ||
        files.isNotEmpty ||
        note.isShared;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasTextBlock)
          Flexible(
            fit: FlexFit.loose,
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  16,
                  16,
                  images.isNotEmpty || hasFooter
                      ? 0
                      : (hasLinkPreviews ? 12 : (reserveActions ? 4 : 16)),
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
                        child: _CardTitle(title: note.title, query: query),
                      ),
                    if (note.title.isNotEmpty &&
                        (note.content.isNotEmpty || previewItems.isNotEmpty))
                      const SizedBox(height: kSpaceSm),
                    if (note.isAudio) ...[
                      if (note.title.isNotEmpty)
                        const SizedBox(height: kSpaceSm),
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
                            maxLines: _maxAudioTranscriptLines,
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
                        constraints: const BoxConstraints(
                          maxHeight: _maxMarkdownPreviewHeight,
                        ),
                        child: ClipRect(
                          child: IgnorePointer(
                            child: SingleChildScrollView(
                              physics: const NeverScrollableScrollPhysics(),
                              child: _MarkdownPreview(
                                content: markdownNoteLinks(
                                  note.content,
                                  titleFor: store.linkTitleFor,
                                ),
                              ),
                            ),
                          ),
                        ),
                      )
                    else if (!note.isChecklist && note.content.isNotEmpty)
                      LinkedText(
                        text: note.content,
                        noteTitleFor: store.linkTitleFor,
                        query: query,
                        highlight: TextStyle(
                          backgroundColor: scheme.primary.withValues(
                            alpha: 0.30,
                          ),
                        ),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.45,
                        ),
                        maxLines: _maxTextPreviewLines,
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
                          padding: EdgeInsets.only(
                            top: unchecked.isEmpty ? 0 : 6,
                          ),
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
                    if (note.summarizingLinks)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: LinkSummaryIndicator(
                          compact: true,
                          onCancel: () => context
                              .read<NotesStore>()
                              .cancelLinkSummaries(note.id),
                        ),
                      ),
                  ],
                ),
              ),
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
                bottom: hasFooter || hasLinkPreviews || reserveActions
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
              hasLinkPreviews ? 12 : (reserveActions ? 4 : 16),
            ),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (note.reminderAt != null)
                  ReminderChip(
                    at: note.reminderAt!,
                    repeat: note.reminderRepeat,
                  ),
                if (locationReminderLabel != null)
                  _LocationReminderChip(label: locationReminderLabel),
                for (final file in files.take(visibleFileCount))
                  _FileChip(file: file),
                if (files.length > visibleFileCount)
                  _LabelChip(name: '+${files.length - visibleFileCount} files'),
                if (showLabelsInBody) ...[
                  for (final tag in labels.take(visibleLabelCount))
                    _LabelChip.of(tag),
                  if (labels.length > visibleLabelCount)
                    _LabelChip(name: '+${labels.length - visibleLabelCount}'),
                ],
                if (note.isShared)
                  Tooltip(
                    message: _sharedTooltip(note, sharedBy: sharedBy),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.people_alt_outlined,
                            size: 16,
                            color: scheme.onSurfaceVariant,
                          ),
                          if (sharedBy != null) ...[
                            const SizedBox(width: kSpaceXs),
                            Flexible(
                              child: Text(
                                sharedBy,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        // The action-icon overlay's reserved slot sits above the link
        // previews, so the previews stay the card's true bottom-most content
        // (see _NoteActions' matching bottom offset).
        if (reserveActions) const SizedBox(height: 48),
        // Full-bleed strips continue the note surface, rather than putting a
        // second rounded card inside it. Only the last strip rounds the base.
        for (var i = 0; i < linkPreviewUrls.length; i++)
          LinkPreviewCard(
            url: linkPreviewUrls[i],
            topDivider: true,
            outlined: false,
            borderRadius: i < linkPreviewUrls.length - 1
                ? BorderRadius.zero
                : const BorderRadius.vertical(bottom: kRadiusCorner),
          ),
      ],
    );
  }

  String? _sharedByLabel(Note note, String? currentUserId) {
    if (note.isOwnedBy(currentUserId)) return null;
    final name = note.owner?.name.trim() ?? '';
    if (name.isEmpty) return null;
    final characters = name.runes.toList();
    if (characters.length <= _maxSharedOwnerCharacters) return name;
    return '${String.fromCharCodes(characters.take(_maxSharedOwnerCharacters - 1))}…';
  }

  String _sharedTooltip(Note note, {required String? sharedBy}) {
    if (sharedBy != null && note.owner != null) {
      return 'Shared by ${note.owner!.name}';
    }
    final names = [
      if (note.owner != null) note.owner!.name,
      ...note.collaborators.map((c) => c.name),
    ];
    return 'Shared with ${names.join(', ')}';
  }
}

class _CardTitle extends StatelessWidget {
  final String title;
  final String query;

  const _CardTitle({required this.title, required this.query});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
      height: 1.3,
    );
    if (!RegExp(
      r'(^#{1,6}\s|[*_`~]|\[[^\]]+\]\([^)]+\))',
      multiLine: true,
    ).hasMatch(title)) {
      return Text.rich(
        TextSpan(
          children: highlightSpans(
            title,
            query,
            highlight: TextStyle(
              backgroundColor: theme.colorScheme.primary.withValues(
                alpha: 0.30,
              ),
            ),
          ),
        ),
        style: style,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight:
            MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 16) *
            1.3 *
            3,
      ),
      child: ClipRect(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: IgnorePointer(
            child: MarkdownBody(
              data: title,
              styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                p: style,
                h1: style,
                h2: style,
                h3: style,
                h4: style,
                h5: style,
                h6: style,
                blockSpacing: 0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Markdown parses its whole AST inside MarkdownBody.build, far too heavy
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
    final textStyle =
        (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
          height: 1.35,
          decoration: item.done ? TextDecoration.lineThrough : null,
          color: item.done ? scheme.onSurfaceVariant : scheme.onSurface,
        );
    final painter = TextPainter(
      text: TextSpan(text: 'x', style: textStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    final lineHeight = painter.preferredLineHeight;
    painter.dispose();
    // The card's checkbox is visually 18px. Give it a first-line-sized band
    // and centre it there so larger text and wrapped labels never leave it
    // stuck at the top of the row.
    final controlBandHeight = lineHeight > 18 ? lineHeight : 18.0;
    return Padding(
      key: ValueKey('checklist-card-row-${item.id}'),
      padding: EdgeInsets.only(
        top: 2,
        bottom: 2,
        // Nesting shows on the card too, at a smaller step than the editor's:
        // the preview is a few lines wide and three full indents would leave
        // a subtask with nowhere to put its text.
        left: item.depth * 12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Enlarge the checkbox hit target without growing the visible icon,
          // while keeping the icon centred on the first text line.
          SizedBox(
            width: 18,
            height: controlBandHeight,
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: InkWell(
                  onTap: canToggle
                      ? () => context.read<NotesStore>().toggleChecklistItem(
                          note.id,
                          item.id,
                        )
                      : null,
                  borderRadius: kBorderRadius,
                  // Checking an item pops the box and fades the text toward
                  // its done color, instead of both flipping on the same
                  // frame.
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
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: AnimatedDefaultTextStyle(
              duration: Motion.fast,
              curve: Motion.standard,
              style: textStyle,
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
                  borderRadius: kBorderRadius,
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

class _LocationReminderChip extends StatelessWidget {
  final String label;

  const _LocationReminderChip({required this.label});

  @override
  Widget build(BuildContext context) => Chip(
    avatar: const Icon(Icons.location_on_outlined, size: 15),
    label: Text(label),
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
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
        borderRadius: kBorderRadius,
        color: scheme.onSurface.withValues(alpha: 0.08),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.attach_file, size: 13, color: scheme.onSurfaceVariant),
          const SizedBox(width: kSpaceXs),
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
          borderRadius: kBorderRadius,
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
