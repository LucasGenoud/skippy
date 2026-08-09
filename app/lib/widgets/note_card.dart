import 'package:animations/animations.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../screens/editor_screen.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../util/mime.dart';
import '../util/note_export.dart';
import '../util/note_routes.dart';
import '../util/snack.dart';
import 'board/move_to_stage_sheet.dart';
import 'color_picker.dart';
import 'workspace_menu.dart';
import 'labels_sheet.dart';
import 'link_preview.dart';
import 'linked_text.dart';
import 'pick_image.dart';
import 'reminder_picker.dart';
import 'share_dialog.dart';
import 'transcribing_indicator.dart';
import '../util/highlight.dart';
import '../util/label_style.dart';
import '../util/linkify.dart';
import '../util/location_geofences.dart';
import '../util/note_image.dart';
import '../util/motion.dart';
import '../util/platform.dart';
import 'screen_width.dart';

/// A note in the grid. The whole tile is an [OpenContainer], so tapping it
/// morphs the card into the editor with a shared container transition.
class NoteTile extends StatefulWidget {
  final Note note;

  /// The active search query, used to highlight matches. Empty when not
  /// searching.
  final String query;
  final bool selectionMode;
  final bool selected;
  final ValueChanged<bool>? onSelectionChanged;

  /// Board cards retain the column picker when opened in the editor.
  final bool openedFromBoard;

  const NoteTile({
    super.key,
    required this.note,
    this.query = '',
    this.selectionMode = false,
    this.selected = false,
    this.onSelectionChanged,
    this.openedFromBoard = false,
  });

  @override
  State<NoteTile> createState() => _NoteTileState();
}

class _NoteTileState extends State<NoteTile> {
  bool _hovered = false;
  bool _menuOpen = false;
  bool _reminderPickerOpen = false;

  Future<void> _editReminder() async {
    if (_reminderPickerOpen) return;
    _reminderPickerOpen = true;
    final store = context.read<NotesStore>();
    final settings = context.read<SettingsStore>();
    final note = store.noteById(widget.note.id) ?? widget.note;
    try {
      final selection = await ReminderPicker.show(
        context,
        current: note.reminderAt,
        currentRepeat: note.reminderRepeat,
        currentLocation: settings.locationReminderForNote(note.id),
        savedLocations: settings.savedLocations,
        locationSupported: LocationGeofences.supported,
        use24hTime: settings.use24hTime,
      );
      if (!mounted || selection == null) return;
      if (selection.locationId != null) {
        final granted = await LocationGeofences.instance
            .requestReminderPermissions();
        if (!mounted) return;
        if (!granted) {
          showAppSnack(
            'Allow notifications and “all the time” location access so this '
            'reminder can fire while Skippy is closed.',
            icon: Icons.location_disabled_outlined,
            kind: SnackKind.warning,
          );
          return;
        }
        if (!settings.setLocationReminder(
          note.id,
          selection.locationId!,
          selection.locationTrigger!,
        )) {
          showAppSnack(
            'You can have up to 20 active location reminders.',
            icon: Icons.location_disabled_outlined,
            kind: SnackKind.warning,
          );
          return;
        }
        store.setReminder(note.id, null);
      } else {
        settings.removeLocationReminder(note.id);
        store.setReminder(note.id, selection.at, selection.repeat);
      }
    } finally {
      _reminderPickerOpen = false;
    }
  }

  Future<void> _share() async {
    final note = context.read<NotesStore>().noteById(widget.note.id);
    if (note == null) return;
    if (note.isEmpty) {
      showAppSnack('Add some content before sharing');
      return;
    }
    await ShareDialog.show(context, note.id);
  }

  void _pickColor() {
    final store = context.read<NotesStore>();
    ColorPickerSheet.show(
      context,
      selected: () => store.noteById(widget.note.id)?.color ?? 'default',
      onSelect: (color) => store.setColor(widget.note.id, color),
    );
  }

  Future<void> _addImage() async {
    final store = context.read<NotesStore>();
    try {
      final picked = await pickNoteImage(context);
      if (picked == null) return;
      if (picked.bytes.length > maxUploadBytes) {
        showAppSnack(
          'Files are limited to 25 MB',
          icon: Icons.error_outline,
          kind: SnackKind.warning,
        );
        return;
      }
      await store.uploadFile(
        widget.note.id,
        picked.bytes,
        picked.mime,
        picked.name,
      );
    } catch (_) {
      showAppSnack(
        "Couldn't upload the image",
        icon: Icons.error_outline,
        kind: SnackKind.danger,
      );
    }
  }

  void _moveToWorkspace() => MoveToWorkspaceSheet.show(context, widget.note.id);

  void _duplicate() {
    context.read<NotesStore>().duplicate(widget.note.id);
  }

  Future<void> _copyToClipboard() async {
    final note = context.read<NotesStore>().noteById(widget.note.id);
    if (note == null) return;
    // trimRight: the export's block form ends with a blank line to separate
    // notes; a paste shouldn't carry that.
    await Clipboard.setData(
      ClipboardData(text: noteToPlainText(note).trimRight()),
    );
  }

  void _delete() {
    final store = context.read<NotesStore>();
    if (!store.canTrash(widget.note.id)) return;
    store.moveToTrash(widget.note.id);
    showAppSnack(
      'Note moved to Trash',
      icon: Icons.delete_outline,
      kind: SnackKind.danger,
      actionLabel: 'Undo',
      onAction: () => store.restoreFromTrash(widget.note.id),
    );
  }

  void _archive() {
    final store = context.read<NotesStore>();
    final note = store.noteById(widget.note.id) ?? widget.note;
    final wasArchived = note.archived;
    store.setArchived(note.id, !wasArchived);
    showAppSnack(
      wasArchived ? 'Note unarchived' : 'Note archived',
      icon: wasArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
      actionLabel: 'Undo',
      onAction: () => store.setArchived(note.id, wasArchived),
    );
  }

  Future<void> _rewrite(NoteRewriteMode mode) async {
    final store = context.read<NotesStore>();
    if (store.isRewritingNote(widget.note.id)) return;
    try {
      await store.rewriteNote(widget.note.id, mode);
      if (!mounted) return;
      showAppSnack(
        mode == NoteRewriteMode.concise
            ? 'Note cleaned up'
            : 'Grammar corrected',
        icon: Icons.auto_fix_high_outlined,
      );
    } catch (_) {
      if (!mounted) return;
      showAppSnack(
        "Couldn't update the note with AI",
        icon: Icons.error_outline,
        kind: SnackKind.danger,
      );
    }
  }

  Future<void> _addLabel() => LabelsSheet.show(context, widget.note.id);

  /// Labels and columns are separate systems, so this is its own action rather
  /// than another entry in the labels sheet.
  Future<void> _moveToStage() => MoveToStageSheet.show(context, widget.note.id);

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
    final isRewriting = context.select<NotesStore, bool>(
      (store) => store.isRewritingNote(note.id),
    );
    // A coloured card used to go borderless at rest, losing the crisp edge
    // plain cards keep, worst on pale fills, which dissolve into the canvas.
    // The border is the same palette entry from the *opposite* theme (the dark
    // shade in light mode, the light one in dark mode), so it is always the
    // card's own hue at contrasting depth, and it honours a custom palette for
    // free. Lerped most of the way back toward the fill: at full strength it
    // reads as an outline drawn around the card rather than the card's edge.
    final counterFill = context.select<SettingsStore, Color?>(
      (s) => s.resolveColor(
        note.color,
        brightness == Brightness.light ? Brightness.dark : Brightness.light,
      ),
    );
    final borderColor = fill == null
        ? scheme.outlineVariant
        : Color.lerp(
            fill,
            counterFill ?? scheme.outlineVariant,
            _hovered ? 0.55 : 0.35,
          )!;
    // Two separate things: the footer slot the card always reserves (so its
    // height never depends on hover or selection), and whether the action
    // icons in that slot are live. Selection mode only silences the icons,
    // reserving the slot regardless is what keeps cards from resizing when
    // selection starts.
    final actionsSlot = !note.trashed && !isTouchPrimaryPlatform;
    final desktopActions = actionsSlot && !widget.selectionMode;
    // The compact control is for mouse users. Touch enters selection with a
    // long press anywhere on the card, which is much easier to hit.
    final showSelectionControl =
        !isTouchPrimaryPlatform && (widget.selectionMode || _hovered);
    // The popup lives in an overlay, so a pointer travelling from the card to
    // its menu triggers MouseRegion.onExit. Keep the footer visible until that
    // menu closes instead of making the controls vanish underneath the cursor.
    final actionsVisible = _hovered || _menuOpen;
    // Link previews are always the card's true bottom-most content, so the
    // action row's reserved slot has to float above their combined height.
    final actionsBottomInset =
        _NoteCardContent._linkPreviewUrls(note).length *
        kLinkPreviewStripHeight;

    // The selection badge straddles the card's top-left corner, so it hangs
    // outside the card's box: it can't live in the OpenContainer's stack,
    // which is clipped to the card shape.
    final card = AnimatedContainer(
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
        // See [noteRouteName]: naming the route it pushes is what lets a
        // widget tap raise this editor rather than open the note twice.
        routeSettings: RouteSettings(name: noteRouteName(note.id)),
        transitionDuration: Motion.slow,
        transitionType: ContainerTransitionType.fade,
        closedElevation: 0,
        openElevation: 0,
        closedColor: fill ?? scheme.surface,
        middleColor: fill ?? scheme.surface,
        openColor: fill ?? scheme.surface,
        closedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadius),
          // Painted on top of the card, never inset from it, so a selected
          // card keeps exactly the footprint it had.
          side: BorderSide(
            color: widget.selected ? scheme.primary : borderColor,
            width: widget.selected ? 2 : 1,
          ),
        ),
        // Tap handling is ours: wide layouts open a centered modal
        // instead of letting the container expand fullscreen. Either way the
        // editor grows out of this card and shrinks back into it.
        tappable: false,
        closedBuilder: (context, open) => InkWell(
          borderRadius: BorderRadius.circular(kRadius),
          onTap: () {
            if (widget.selectionMode) {
              widget.onSelectionChanged?.call(!widget.selected);
              return;
            }
            openNoteEditor(
              context,
              openFullscreen: open,
              noteId: note.id,
              openedFromBoard: widget.openedFromBoard,
              sourceRect: morphSourceRect(context),
            );
          },
          onLongPress: widget.selectionMode
              ? () => widget.onSelectionChanged?.call(!widget.selected)
              : null,
          // The pin overlay is the only hover-dependent piece, and it sits
          // outside _NoteCardContent so hover flips never rebuild the card
          // body (markdown parse, image resolve).
          child: Stack(
            children: [
              _NoteCardContent(
                note: note,
                query: widget.query,
                reserveActions: actionsSlot,
                showLabelsInBody: !actionsSlot,
              ),
              _PinButton(note: note, hovered: _hovered, hidden: isRewriting),
              if (isRewriting) const _NoteRewriteProgress(),
              if (desktopActions)
                _NoteActions(
                  note: note,
                  visible: actionsVisible,
                  rewriting: isRewriting,
                  canDelete: context.read<NotesStore>().canTrash(note.id),
                  onReminder: _editReminder,
                  onShare: _share,
                  onColor: _pickColor,
                  onLabel: _addLabel,
                  onImage: _addImage,
                  onArchive: _archive,
                  onDuplicate: _duplicate,
                  onMoveToWorkspace: _moveToWorkspace,
                  onMoveToStage: _moveToStage,
                  canMove:
                      widget.note.isOwnedBy(
                        context.read<NotesStore>().currentUserId,
                      ) &&
                      context.read<NotesStore>().workspaces.length > 1,
                  onCopyToClipboard: _copyToClipboard,
                  onDelete: _delete,
                  onRewrite: _rewrite,
                  onMenuOpened: () => setState(() => _menuOpen = true),
                  onMenuClosed: () => setState(() => _menuOpen = false),
                  bottomInset: actionsBottomInset,
                ),
              // In selection mode the action icons are gone, so the reserved
              // slot shows the labels for good instead of only at rest.
              if (actionsSlot)
                _NoteFooterLabels(
                  note: note,
                  visible: !(desktopActions && actionsVisible),
                  bottomInset: actionsBottomInset,
                ),
            ],
          ),
        ),
        openBuilder: (context, close) => EditorScreen(
          noteId: note.id,
          openedFromBoard: widget.openedFromBoard,
        ),
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          card,
          _SelectionButton(
            selected: widget.selected,
            visible: showSelectionControl,
            onPressed: () => widget.onSelectionChanged?.call(!widget.selected),
          ),
        ],
      ),
    );
  }
}

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

  // Keep repeated links from producing repeated cards, and cap the attached
  // preview stack so a link-heavy note does not dominate the grid.
  static List<String> _linkPreviewUrls(Note note) {
    final matches = findUrls('${note.title}\n${note.content}');
    final urls = <String>[];
    for (final match in matches) {
      if (!urls.contains(match.url)) {
        urls.add(match.url);
        if (urls.length == 3) break;
      }
    }
    return urls;
  }

  @override
  Widget build(BuildContext context) {
    // read for URL building; select for the one store-derived value (label
    // names) so the card body doesn't rebuild on every store notification.
    final store = context.read<NotesStore>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sharedBy = _sharedByLabel(note, store.currentUserId);
    // Joined with an unprintable separator (label names may contain spaces)
    // because select needs a value with a meaningful ==, a freshly built
    // List never equals the previous one.
    final joinedLabels = context.select<NotesStore, String>(
      (s) =>
          ([
            for (final id in note.labelIds)
              if (s.labelById(id) case final Label label)
                // name  color  icon (empty = unset); carries the
                // chip's styling through select without widening rebuilds.
                '${label.name}${label.color ?? ''}${label.icon ?? ''}',
          ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))).join(
            '\u0000',
          ),
    );
    final labels = joinedLabels.isEmpty
        ? const <String>[]
        : joinedLabels.split('\u0000');
    final locationReminderLabel = context.select<SettingsStore, String?>((s) {
      final reminder = s.locationReminderForNote(note.id);
      final location = s.savedLocationById(reminder?.locationId);
      if (reminder == null || location == null) return null;
      return '${reminder.trigger.label} · ${location.name}';
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
    final compactMetadata = !ScreenWidth.isAtLeast(context, 600);
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
                  _ReminderChip(
                    reminderAt: note.reminderAt!,
                    repeat: note.reminderRepeat,
                  ),
                if (locationReminderLabel != null)
                  _LocationReminderChip(label: locationReminderLabel),
                for (final file in files.take(visibleFileCount))
                  _FileChip(file: file),
                if (files.length > visibleFileCount)
                  _LabelChip(name: '+${files.length - visibleFileCount} files'),
                if (showLabelsInBody) ...[
                  for (final row in labels.take(visibleLabelCount))
                    _LabelChip.encoded(row),
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
                            const SizedBox(width: 4),
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
        // Up to three unique previews form one full-bleed stack attached to
        // the note. Each strip supplies the dividing hairline; only the final
        // one follows the card's bottom corners.
        for (var i = 0; i < linkPreviewUrls.length; i++)
          LinkPreviewCard(
            url: linkPreviewUrls[i],
            topDivider: true,
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

/// Pin control overlaying the card's top-right corner: revealed on hover
/// (web/desktop), always shown when pinned so its state is visible at a
/// glance. Lives beside, not inside, [_NoteCardContent] so hover flips
/// only touch this small overlay, never the card body.
class _PinButton extends StatelessWidget {
  /// Square tap target tucked into the corner. A default [IconButton] is
  /// 48x48, which pushed the glyph far enough in to read as floating in the
  /// middle of the card's top edge rather than sitting in its corner.
  static const double _size = 32;

  final Note note;
  final bool hovered;
  final bool hidden;
  const _PinButton({
    required this.note,
    required this.hovered,
    this.hidden = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final show = !hidden && !note.trashed && (hovered || note.pinned);
    return Positioned(
      top: 4,
      right: 4,
      width: _size,
      height: _size,
      child: AnimatedOpacity(
        opacity: show ? 1 : 0,
        duration: Motion.fast,
        curve: Motion.standard,
        child: IgnorePointer(
          ignoring: !show,
          child: IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(
              width: _size,
              height: _size,
            ),
            iconSize: 18,
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
                size: 18,
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

/// The badge for entering or extending a selection. It sits on top of the
/// card's top-left corner, half over the card, half over the canvas, shares
/// the card's accent colour once selected, and stays hidden on desktop until
/// the pointer is over the card.
///
/// The tap target is the badge itself and nothing more: an oversized target
/// around it would swallow clicks meant for the card's own corner.
class _SelectionButton extends StatelessWidget {
  /// Diameter of the badge, which is also the whole of its hit area.
  static const double _size = 20;

  /// How far the badge hangs past the card's corner. Enough to read as
  /// sitting on the corner, small enough that the badge stays mostly over the
  /// card, the sliver outside the card's box is drawn (the parent [Stack]
  /// doesn't clip) but, like any overflow in Flutter, can't take a pointer.
  static const double _overhang = 5;

  final bool selected;
  final bool visible;
  final VoidCallback onPressed;

  const _SelectionButton({
    required this.selected,
    required this.visible,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      top: -_overhang,
      left: -_overhang,
      width: _size,
      height: _size,
      child: AnimatedOpacity(
        duration: Motion.fast,
        curve: Motion.standard,
        opacity: visible ? 1 : 0,
        child: IgnorePointer(
          ignoring: !visible,
          child: Tooltip(
            message: selected ? 'Deselect note' : 'Select note',
            child: Material(
              // Opaque: the badge overlaps the canvas as well as the card, so
              // it has to read as one solid dot over both.
              color: selected ? scheme.primary : scheme.surface,
              shape: CircleBorder(
                side: BorderSide(
                  color: scheme.primary,
                  width: selected ? 1.5 : 1,
                ),
              ),
              elevation: 1,
              animationDuration: Motion.fast,
              child: InkWell(
                onTap: onPressed,
                customBorder: const CircleBorder(),
                child: AnimatedSwitcher(
                  duration: Motion.fast,
                  switchInCurve: Curves.easeOutBack,
                  switchOutCurve: Curves.easeIn,
                  child: selected
                      ? Icon(
                          Icons.check,
                          key: const ValueKey('selected'),
                          color: scheme.onPrimary,
                          size: 13,
                        )
                      : const SizedBox(key: ValueKey('unselected')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact, non-blocking signal that the server is applying an AI rewrite.
/// It occupies the pin's usual corner so it stays visible without covering
/// the note content or the desktop action footer.
class _NoteRewriteProgress extends StatelessWidget {
  const _NoteRewriteProgress();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      // Centred where the pin's glyph sits, so it stands in for it exactly.
      top: 11,
      right: 11,
      child: Semantics(
        label: 'AI editing note',
        child: SizedBox(
          key: const ValueKey('note-rewrite-progress'),
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2.25,
            color: scheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Pointer-only card actions. The card always reserves this footer on desktop
/// so revealing the controls never shifts text, images, or neighboring tiles.
class _NoteActions extends StatelessWidget {
  final Note note;
  final bool visible;
  final bool rewriting;
  final bool canDelete;
  final VoidCallback onReminder;
  final VoidCallback onShare;
  final VoidCallback onColor;
  final VoidCallback onLabel;
  final VoidCallback onImage;
  final VoidCallback onArchive;
  final VoidCallback onDuplicate;

  /// Moving a note changes who can see it, so it is the owner's call, and
  /// there has to be somewhere else to move it to.
  final VoidCallback onMoveToWorkspace;
  final bool canMove;

  /// Opens the column picker. The board's move gesture in v1, and the
  /// keyboard/screen-reader path on every platform.
  final VoidCallback onMoveToStage;
  final VoidCallback onCopyToClipboard;
  final VoidCallback onDelete;
  final ValueChanged<NoteRewriteMode> onRewrite;
  final VoidCallback onMenuOpened;
  final VoidCallback onMenuClosed;

  /// Extra lift above the card's bottom edge, so the reserved slot clears
  /// any attached link-preview cards instead of floating over them — those
  /// stay the card's true bottom-most content.
  final double bottomInset;

  const _NoteActions({
    required this.note,
    required this.visible,
    required this.rewriting,
    required this.canDelete,
    required this.onReminder,
    required this.onShare,
    required this.onColor,
    required this.onLabel,
    required this.onImage,
    required this.onArchive,
    required this.onDuplicate,
    required this.onMoveToWorkspace,
    required this.onMoveToStage,
    required this.canMove,
    required this.onCopyToClipboard,
    required this.onDelete,
    required this.onRewrite,
    required this.onMenuOpened,
    required this.onMenuClosed,
    this.bottomInset = 0,
  });

  Widget _button({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color? color,
  }) => IconButton(
    constraints: const BoxConstraints.tightFor(width: 36, height: 36),
    padding: EdgeInsets.zero,
    visualDensity: VisualDensity.compact,
    iconSize: 19,
    icon: Icon(icon),
    color: color,
    tooltip: tooltip,
    onPressed: onPressed,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final aiEditingEnabled = context.select<SettingsStore, bool>(
      (settings) => settings.noteWritingAvailable,
    );
    final hasReminder = context.select<SettingsStore, bool>(
      (settings) =>
          note.reminderAt != null ||
          settings.locationReminderForNote(note.id) != null,
    );
    return Positioned(
      left: 8,
      right: 8,
      bottom: 4 + bottomInset,
      height: 40,
      child: AnimatedOpacity(
        key: ValueKey('note-actions-${note.id}'),
        opacity: visible ? 1 : 0,
        duration: Motion.fast,
        curve: Motion.standard,
        child: IgnorePointer(
          ignoring: !visible,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.55),
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _button(
                  icon: Icons.palette_outlined,
                  tooltip: 'Note color',
                  onPressed: onColor,
                ),
                _button(
                  icon: Icons.label_outline,
                  tooltip: 'Add label',
                  onPressed: onLabel,
                ),
                _button(
                  icon: !hasReminder
                      ? Icons.notification_add_outlined
                      : Icons.notifications_active_outlined,
                  tooltip: !hasReminder ? 'Add reminder' : 'Edit reminder',
                  onPressed: onReminder,
                ),
                _button(
                  icon: Icons.image_outlined,
                  tooltip: 'Add image',
                  onPressed: onImage,
                ),
                _button(
                  icon: note.archived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                  tooltip: note.archived ? 'Unarchive note' : 'Archive note',
                  onPressed: onArchive,
                ),
                // PopupMenuButton's default icon target is 48 px. Use the
                // same 36 px circular ink target as the neighboring controls.
                PopupMenuButton<String>(
                  popUpAnimationStyle: Motion.menuFor(context),
                  borderRadius: BorderRadius.circular(18),
                  splashRadius: 18,
                  tooltip: 'More note options',
                  padding: EdgeInsets.zero,
                  onOpened: onMenuOpened,
                  onCanceled: onMenuClosed,
                  onSelected: (value) async {
                    onMenuClosed();
                    if (value == 'share' ||
                        value == 'move' ||
                        value == 'stage') {
                      await Motion.waitForMenuDismissal(context);
                      if (!context.mounted) return;
                    }
                    if (value == 'share') onShare();
                    if (value == 'duplicate') onDuplicate();
                    if (value == 'move') onMoveToWorkspace();
                    if (value == 'stage') onMoveToStage();
                    if (value == 'clipboard') onCopyToClipboard();
                    if (value == 'delete') onDelete();
                    if (value == 'concise') onRewrite(NoteRewriteMode.concise);
                    if (value == 'grammar') onRewrite(NoteRewriteMode.grammar);
                  },
                  itemBuilder: (context) => [
                    if (aiEditingEnabled && note.kind != NoteKind.audio) ...[
                      PopupMenuItem(
                        value: 'concise',
                        enabled: !rewriting,
                        child: ListTile(
                          leading: Icon(Icons.auto_fix_high_outlined),
                          title: Text('Clean up and make concise'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'grammar',
                        enabled: !rewriting,
                        child: ListTile(
                          leading: Icon(Icons.spellcheck_outlined),
                          title: Text('Fix grammar and syntax'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuDivider(),
                    ],
                    const PopupMenuItem(
                      value: 'share',
                      child: ListTile(
                        leading: Icon(Icons.person_add_alt_outlined),
                        title: Text('Share'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    // Both live in the menu rather than the action row: six
                    // controls already share a card's width.
                    const PopupMenuItem(
                      value: 'clipboard',
                      child: ListTile(
                        leading: Icon(Icons.content_copy_outlined),
                        title: Text('Copy to clipboard'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'duplicate',
                      child: ListTile(
                        leading: Icon(Icons.copy_all_outlined),
                        title: Text('Duplicate'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'stage',
                      child: ListTile(
                        leading: Icon(Icons.view_kanban_outlined),
                        title: Text('Move to column'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    if (canMove)
                      const PopupMenuItem(
                        value: 'move',
                        child: ListTile(
                          leading: Icon(Icons.drive_file_move_outlined),
                          title: Text('Move to workspace'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    PopupMenuItem(
                      value: 'delete',
                      enabled: canDelete,
                      child: ListTile(
                        leading: Icon(
                          Icons.delete_outline,
                          color: canDelete ? scheme.error : null,
                        ),
                        title: Text(
                          canDelete
                              ? 'Move to Trash'
                              : 'Only the owner can delete',
                          style: canDelete
                              ? TextStyle(color: scheme.error)
                              : null,
                        ),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: Center(
                      child: Icon(
                        Icons.more_vert,
                        size: 19,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The otherwise reserved desktop footer shows labels at rest. The action row
/// replaces it on hover without shifting a card.
class _NoteFooterLabels extends StatelessWidget {
  final Note note;
  final bool visible;
  final double bottomInset;
  const _NoteFooterLabels({
    required this.note,
    required this.visible,
    this.bottomInset = 0,
  });

  @override
  Widget build(BuildContext context) {
    final joinedLabels = context.select<NotesStore, String>(
      (store) =>
          ([
            for (final id in note.labelIds)
              if (store.labelById(id) case final Label label)
                '${label.name}\u0001${label.color ?? ''}\u0001${label.icon ?? ''}',
          ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))).join(
            '\u0000',
          ),
    );
    final labels = joinedLabels.isEmpty
        ? const <String>[]
        : joinedLabels.split('\u0000');
    return Positioned(
      left: 16,
      right: 16,
      bottom: 8 + bottomInset,
      height: 40,
      child: AnimatedOpacity(
        key: ValueKey('note-footer-labels-${note.id}'),
        opacity: visible ? 1 : 0,
        duration: Motion.fast,
        curve: Motion.standard,
        child: IgnorePointer(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const markerWidth = 24.0;
              const markerGap = 6.0;
              final fullLabelsWidth = labels.isEmpty
                  ? 0.0
                  : labels
                            .map((row) => _labelChipWidth(context, row))
                            .reduce((a, b) => a + markerGap + b) +
                        1;
              final compact = fullLabelsWidth > constraints.maxWidth;
              final markerSlots =
                  ((constraints.maxWidth + markerGap) /
                          (markerWidth + markerGap))
                      .floor();
              final showOverflow =
                  compact && markerSlots > 0 && labels.length > markerSlots;
              final visibleLabelCount = compact
                  ? (markerSlots - (showOverflow ? 1 : 0)).clamp(
                      0,
                      labels.length,
                    )
                  : labels.length;

              return Align(
                alignment: Alignment.centerLeft,
                child: compact
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (
                            var index = 0;
                            index < visibleLabelCount;
                            index++
                          ) ...[
                            _FooterLabelMarker(
                              row: labels[index],
                              key: ValueKey(
                                'note-footer-label-marker-${note.id}-$index',
                              ),
                            ),
                            if (index + 1 < visibleLabelCount || showOverflow)
                              const SizedBox(width: markerGap),
                          ],
                          if (showOverflow) const _FooterOverflowMarker(),
                        ],
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (
                            var index = 0;
                            index < labels.length;
                            index++
                          ) ...[
                            _LabelChip.encoded(labels[index]),
                            if (index + 1 < labels.length)
                              const SizedBox(width: markerGap),
                          ],
                        ],
                      ),
              );
            },
          ),
        ),
      ),
    );
  }

  double _textWidth(BuildContext context, String text, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return painter.width;
  }

  double _labelChipWidth(BuildContext context, String row) {
    final parts = row.split('\u0001');
    final name = parts.isEmpty ? '' : parts.first;
    final hasIcon = parts.length > 2 && parts[2].isNotEmpty;
    // The text width plus the chip's horizontal padding, optional icon and
    // border. This lets the footer switch layouts before RenderFlex overflows.
    return _textWidth(context, name, Theme.of(context).textTheme.labelSmall) +
        (hasIcon ? 36 : 22);
  }
}

class _FooterLabelMarker extends StatelessWidget {
  final String row;
  const _FooterLabelMarker({required this.row, super.key});

  @override
  Widget build(BuildContext context) {
    final parts = row.split('\u0001');
    final color = parts.length > 1 ? parts[1] : null;
    final iconKey = parts.length > 2 ? parts[2] : null;
    final scheme = Theme.of(context).colorScheme;
    final tint = PaletteEntry.hexToColor(color);
    final line = tint ?? scheme.onSurfaceVariant;
    return Tooltip(
      message: parts.isEmpty ? '' : parts.first,
      child: Container(
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadius),
          color: tint?.withValues(alpha: 0.14),
          border: Border.all(
            color: line.withValues(alpha: tint == null ? 0.4 : 0.55),
          ),
        ),
        child: Icon(labelIconFor(iconKey), size: 13, color: line),
      ),
    );
  }
}

class _FooterOverflowMarker extends StatelessWidget {
  const _FooterOverflowMarker();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadius),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Icon(Icons.more_horiz, size: 16, color: color),
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
      padding: const EdgeInsets.symmetric(vertical: 2),
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
                  borderRadius: BorderRadius.circular(kRadius),
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
  final ReminderRepeat? repeat;
  const _ReminderChip({required this.reminderAt, this.repeat});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final past = reminderAt.isBefore(DateTime.now());
    // select: re-render only when the formatted label itself changes (date
    // or clock format edits), not on every settings notification.
    final when = context.select<SettingsStore, String>(
      (s) => s.reminderLabel(reminderAt),
    );
    final label = '$when${repeat == null ? '' : ' · ${repeat!.label}'}';
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
  final String? color; // hex, or null for the theme default
  final String? iconKey; // curated icon key, or null for no leading icon
  const _LabelChip({required this.name, this.color, this.iconKey});

  /// Decode a `name<U+0001>color<U+0001>icon` row (as encoded in the card's
  /// label `select`) into a styled chip.
  factory _LabelChip.encoded(String row) {
    final parts = row.split('');
    String? at(int i) =>
        (i < parts.length && parts[i].isNotEmpty) ? parts[i] : null;
    return _LabelChip(
      name: parts.isEmpty ? '' : parts[0],
      color: at(1),
      iconKey: at(2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = PaletteEntry.hexToColor(color);
    final line = tint ?? scheme.onSurfaceVariant;
    return Container(
      padding: EdgeInsets.only(
        left: iconKey != null ? 7 : 10,
        right: 10,
        top: 3,
        bottom: 3,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadius),
        color: tint?.withValues(alpha: 0.14),
        border: Border.all(
          color: line.withValues(alpha: tint == null ? 0.4 : 0.55),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (iconKey != null) ...[
            Icon(labelIconFor(iconKey), size: 13, color: line),
            const SizedBox(width: 4),
          ],
          Text(
            name,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: line),
          ),
        ],
      ),
    );
  }
}
