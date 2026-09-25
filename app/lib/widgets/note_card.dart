import 'collection_settings.dart';
import 'package:animations/animations.dart';
import 'package:flutter/foundation.dart' show kIsWeb, ValueListenable;
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
import 'link_summary_indicator.dart';
import 'link_preview.dart';
import 'linked_text.dart';
import 'masonry.dart';
import 'pick_image.dart';
import 'pin_icon.dart';
import 'reminder_chip.dart';
import 'reminder_picker.dart';
import 'share_dialog.dart';
import 'swipe_to_archive.dart';
import 'transcribing_indicator.dart';
import '../util/highlight.dart';
import '../util/keyboard.dart';
import '../util/label_style.dart';
import '../util/location_geofences.dart';
import '../util/location_reminder_grants.dart';
import '../util/note_image.dart';
import '../util/motion.dart';
import '../util/platform.dart';
import 'screen_width.dart';

/// A note in the grid. Narrow layouts use [OpenContainer] to morph into the
/// fullscreen editor; wide layouts open their own modal from the card.
class NoteTile extends StatefulWidget {
  final Note note;

  /// The active search query, used to highlight matches. Empty when not
  /// searching.
  final String query;
  final bool selectionMode;
  final ValueListenable<bool>? selectionModeListenable;
  final bool selected;
  final ValueChanged<bool>? onSelectionChanged;
  final bool showCollection;

  /// Board cards retain the column picker when opened in the editor.
  final bool openedFromBoard;

  /// Whether a horizontal swipe on this card archives it (touch only, see
  /// [SwipeToArchive]).
  ///
  /// Off by default because it is not the card's decision: the board pages
  /// between columns with the same gesture on a phone, and a card in the trash
  /// has nothing to archive.
  final bool swipeToArchive;

  const NoteTile({
    super.key,
    required this.note,
    this.query = '',
    this.selectionMode = false,
    this.selectionModeListenable,
    this.selected = false,
    this.onSelectionChanged,
    this.showCollection = false,
    this.openedFromBoard = false,
    this.swipeToArchive = false,
  });

  @override
  State<NoteTile> createState() => _NoteTileState();
}

class _NoteTileState extends State<NoteTile> {
  bool _hovered = false;
  bool _menuOpen = false;
  bool _reminderPickerOpen = false;
  Note? _bodyNote;
  String? _bodyQuery;
  bool? _bodyActionsSlot;
  Widget? _body;

  bool get _selectionModeNow =>
      widget.selectionModeListenable?.value ?? widget.selectionMode;

  void _selectionModeChanged() {
    if (_hovered || _menuOpen) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.selectionModeListenable?.addListener(_selectionModeChanged);
  }

  @override
  void didUpdateWidget(NoteTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectionModeListenable != widget.selectionModeListenable) {
      oldWidget.selectionModeListenable?.removeListener(_selectionModeChanged);
      widget.selectionModeListenable?.addListener(_selectionModeChanged);
    }
  }

  @override
  void dispose() {
    widget.selectionModeListenable?.removeListener(_selectionModeChanged);
    super.dispose();
  }

  Widget _cardBody(Note note, String query, bool actionsSlot) {
    if (!identical(_bodyNote, note) ||
        _bodyQuery != query ||
        _bodyActionsSlot != actionsSlot) {
      _bodyNote = note;
      _bodyQuery = query;
      _bodyActionsSlot = actionsSlot;
      _body = _NoteCardContent(
        note: note,
        query: query,
        reserveActions: actionsSlot,
        showLabelsInBody: !actionsSlot,
      );
    }
    return _body!;
  }

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
        locationMonitored: LocationGeofences.supported,
        use24hTime: settings.use24hTime,
      );
      if (!mounted || selection == null) return;
      if (selection.locationId != null) {
        final granted = await ensureLocationReminderGrants();
        if (!mounted || !granted) return;
        if (!settings.setLocationReminder(
          note.id,
          selection.locationId!,
          selection.locationTrigger!,
          repeats: selection.locationRepeats,
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
    // The picker is a native screen; anything still focused behind it (the
    // search field, a quick-add composer) comes back with the keyboard up.
    dismissKeyboard();
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
    final copy = context.read<NotesStore>().duplicate(widget.note.id);
    if (copy == null) return;
    // The copy lands at the front of the grid, which is not necessarily where
    // you are looking, so name it and offer the way in. Opening it outright
    // would get in the way of duplicating a few notes in a row.
    showAppSnack(
      'Duplicated as “${copy.title}”',
      icon: Icons.copy_all_outlined,
      actionLabel: 'Open',
      onAction: () {
        if (!mounted) return;
        openNoteEditor(
          context,
          noteId: copy.id,
          sourceRect: morphSourceRect(context),
          openFullscreen: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => EditorScreen(noteId: copy.id),
            ),
          ),
        );
      },
    );
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

  Future<void> _rewrite(NoteRewriteTask task) async {
    final store = context.read<NotesStore>();
    if (store.isRewritingNote(widget.note.id)) return;
    try {
      await store.rewriteNote(widget.note.id, task);
      if (!mounted) return;
      showAppSnack('${task.name} complete', icon: Icons.auto_fix_high_outlined);
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
    final desktopActions = actionsSlot && !_selectionModeNow;
    // The compact control is for mouse users. Touch enters selection with a
    // long press anywhere on the card, which is much easier to hit.
    Widget selectionBadge(bool mode) => _SelectionButton(
      selected: widget.selected,
      visible: !isTouchPrimaryPlatform && (mode || _hovered),
      onPressed: () => widget.onSelectionChanged?.call(!widget.selected),
    );
    // The popup lives in an overlay, so a pointer travelling from the card to
    // its menu triggers MouseRegion.onExit. Keep the footer visible until that
    // menu closes instead of making the controls vanish underneath the cursor.
    final actionsVisible = _hovered || _menuOpen;
    // Link previews are always the card's true bottom-most content, so the
    // action row's reserved slot has to float above their combined height.
    final previewCount = _NoteCardContent._linkPreviewUrls(note).length;
    final actionsBottomInset = previewCount * (kLinkPreviewStripHeight + 1);
    final collection = widget.showCollection
        ? context.select<NotesStore, String?>((store) {
            final collections = store
                .workspaceById(note.workspaceId)
                ?.collections;
            if (collections == null) return null;
            for (final collection in collections) {
              if (collection.id ==
                  (note.collectionId ?? '${note.workspaceId}-general')) {
                return '${collection.name}\u0001${collection.color ?? ''}\u0001${collection.icon ?? ''}';
              }
            }
            return null;
          })
        : null;

    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(kRadius),
      side: BorderSide(
        color: widget.selected ? scheme.primary : borderColor,
        width: widget.selected ? 2 : 1,
      ),
    );
    Widget closedCard(VoidCallback open) => InkWell(
      borderRadius: BorderRadius.circular(kRadius),
      onTap: () {
        if (_selectionModeNow) {
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
      onLongPress:
          widget.selectionModeListenable != null || widget.selectionMode
          ? () {
              if (_selectionModeNow) {
                widget.onSelectionChanged?.call(!widget.selected);
              }
            }
          : null,
      // Keep the content widget identical while selection and hover change.
      child: Stack(
        children: [
          _cardBody(note, widget.query, actionsSlot),
          if (collection != null) _CollectionMarker(encoded: collection),
          _PinButton(note: note, hovered: _hovered, hidden: isRewriting),
          if (isRewriting) const _NoteRewriteProgress(),
          if (desktopActions && actionsVisible)
            _NoteActions(
              note: note,
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
              showMoveToStage: widget.openedFromBoard,
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
          if (actionsSlot && note.labelIds.isNotEmpty)
            _NoteFooterLabels(
              note: note,
              visible: !(desktopActions && actionsVisible),
              bottomInset: actionsBottomInset,
            ),
        ],
      ),
    );

    // The desktop editor uses its own modal morph, so only narrow layouts
    // need the container route and its widget subtree on every card.
    final surface = wantsModalEditor(context)
        ? Material(
            color: fill ?? scheme.surface,
            shape: cardShape,
            clipBehavior: Clip.antiAlias,
            child: closedCard(
              () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  settings: RouteSettings(name: noteRouteName(note.id)),
                  builder: (_) => EditorScreen(
                    noteId: note.id,
                    openedFromBoard: widget.openedFromBoard,
                  ),
                ),
              ),
            ),
          )
        : OpenContainer<void>(
            routeSettings: RouteSettings(name: noteRouteName(note.id)),
            transitionDuration: Motion.slow,
            transitionType: ContainerTransitionType.fade,
            closedElevation: 0,
            openElevation: 0,
            closedColor: fill ?? scheme.surface,
            middleColor: fill ?? scheme.surface,
            openColor: fill ?? scheme.surface,
            closedShape: cardShape,
            tappable: false,
            closedBuilder: (context, open) => closedCard(open),
            openBuilder: (context, close) => EditorScreen(
              noteId: note.id,
              openedFromBoard: widget.openedFromBoard,
            ),
          );

    // The selection badge straddles the card's corner outside the clip.
    final cardContent = AnimatedContainer(
      duration: Motion.fast,
      curve: Motion.standard,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: _hovered ? 0.16 : 0.05),
            blurRadius: _hovered ? 14 : 4,
            offset: Offset(0, _hovered ? 5 : 1),
          ),
        ],
      ),
      child: surface,
    );

    Widget cardSemantics(bool mode) => Semantics(
      button: true,
      label:
          '${mode ? (widget.selected ? 'Deselect' : 'Select') : 'Open'} ${note.title.isEmpty ? 'untitled note' : note.title}',
      child: cardContent,
    );

    final card = AnimatedSize(
      key: ValueKey('note-size-${note.id}'),
      duration: Motion.reduced(context) ? Duration.zero : Motion.base,
      curve: Motion.emphasized,
      alignment: Alignment.topCenter,
      child: widget.selectionModeListenable != null
          ? ValueListenableBuilder<bool>(
              valueListenable: widget.selectionModeListenable!,
              builder: (_, mode, _) => cardSemantics(mode),
            )
          : cardSemantics(widget.selectionMode),
    );

    final tile = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          card,
          if (widget.selectionModeListenable case final listenable?)
            ValueListenableBuilder<bool>(
              valueListenable: listenable,
              builder: (_, mode, _) => selectionBadge(mode),
            )
          else
            selectionBadge(widget.selectionMode),
        ],
      ),
    );

    return SwipeToArchive(
      // A mouse drag on a card lifts it for a reorder from the first pixel
      // (see AnimatedMasonry), so the swipe would eat that gesture. Selecting
      // is a mode of its own: while it is on, a card's tap toggles it and a
      // stray sideways drag must not archive anything.
      enabled:
          widget.swipeToArchive &&
          isTouchPrimaryPlatform &&
          !note.trashed &&
          !widget.selectionMode,
      archived: note.archived,
      onArchive: _archive,
      onActive: (active) => MasonryRaiseTileNotification(
        note.id,
        raised: active,
      ).dispatch(context),
      child: tile,
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
                      const Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: LinkSummaryIndicator(compact: true),
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

/// The archive-only collection marker is a quiet corner glyph rather than a
/// metadata chip. Its tooltip carries the collection name without competing
/// with the note's own tags.
class _CollectionMarker extends StatelessWidget {
  final String encoded;
  const _CollectionMarker({required this.encoded});

  @override
  Widget build(BuildContext context) {
    final parts = encoded.split('\u0001');
    final name = parts.first;
    final color = parts.length > 1 ? PaletteEntry.hexToColor(parts[1]) : null;
    final icon = parts.length > 2
        ? labelIconFor(parts[2])
        : Icons.folder_outlined;
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      top: 6,
      right: 38,
      width: 28,
      height: 28,
      child: Tooltip(
        message: name,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.surface.withValues(alpha: 0.75),
          ),
          child: Icon(icon, size: 15, color: color ?? scheme.onSurfaceVariant),
        ),
      ),
    );
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
            icon: PinIcon(pinned: note.pinned, size: 18),
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
  final bool showMoveToStage;
  final VoidCallback onCopyToClipboard;
  final VoidCallback onDelete;
  final ValueChanged<NoteRewriteTask> onRewrite;
  final VoidCallback onMenuOpened;
  final VoidCallback onMenuClosed;

  /// Extra lift above the card's bottom edge, so the reserved slot clears
  /// any attached link-preview cards instead of floating over them — those
  /// stay the card's true bottom-most content.
  final double bottomInset;

  const _NoteActions({
    required this.note,
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
    required this.showMoveToStage,
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
    final rewriteTasks = context.select<SettingsStore, List<NoteRewriteTask>>(
      (settings) => settings.llmRewriteTasks,
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
      child: DecoratedBox(
        key: ValueKey('note-actions-${note.id}'),
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
            MenuAnchor(
              onOpen: onMenuOpened,
              onClose: onMenuClosed,
              builder: (context, controller, child) => _button(
                icon: Icons.more_vert,
                tooltip: 'More note options',
                color: scheme.onSurfaceVariant,
                onPressed: controller.isOpen
                    ? controller.close
                    : controller.open,
              ),
              menuChildren: [
                if (aiEditingEnabled &&
                    rewriteTasks.isNotEmpty &&
                    note.kind != NoteKind.audio)
                  SubmenuButton(
                    leadingIcon: const Icon(Icons.auto_fix_high_outlined),
                    menuChildren: [
                      for (final task in rewriteTasks)
                        MenuItemButton(
                          onPressed: rewriting ? null : () => onRewrite(task),
                          child: Text(task.name),
                        ),
                    ],
                    child: const Text('AI edit'),
                  ),
                if (aiEditingEnabled &&
                    rewriteTasks.isNotEmpty &&
                    note.kind != NoteKind.audio)
                  const Divider(height: 1),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.person_add_alt_outlined),
                  onPressed: () async {
                    await Motion.waitForMenuDismissal(context);
                    if (context.mounted) onShare();
                  },
                  child: const Text('Share'),
                ),
                // Both live in the menu rather than the action row: six
                // controls already share a card's width.
                MenuItemButton(
                  leadingIcon: const Icon(Icons.content_copy_outlined),
                  onPressed: onCopyToClipboard,
                  child: const Text('Copy to clipboard'),
                ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.copy_all_outlined),
                  onPressed: onDuplicate,
                  child: const Text('Duplicate'),
                ),
                if (showMoveToStage)
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.view_kanban_outlined),
                    onPressed: () async {
                      await Motion.waitForMenuDismissal(context);
                      if (context.mounted) onMoveToStage();
                    },
                    child: const Text('Move to column'),
                  ),
                if (context.read<NotesStore>().workspaceById(
                      note.workspaceId,
                    ) !=
                    null)
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.folder_outlined),
                    onPressed: () async {
                      await Motion.waitForMenuDismissal(context);
                      if (!context.mounted) return;
                      final store = context.read<NotesStore>();
                      final target = await CollectionPicker.show(
                        context,
                        note.workspaceId,
                      );
                      if (target != null) {
                        store.moveToCollection(note.id, target);
                      }
                    },
                    child: const Text('Move to collection'),
                  ),
                if (canMove)
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.drive_file_move_outlined),
                    onPressed: () async {
                      await Motion.waitForMenuDismissal(context);
                      if (context.mounted) onMoveToWorkspace();
                    },
                    child: const Text('Move to workspace'),
                  ),
                MenuItemButton(
                  leadingIcon: Icon(
                    Icons.delete_outline,
                    color: canDelete ? scheme.error : null,
                  ),
                  onPressed: canDelete ? onDelete : null,
                  child: Text(
                    canDelete ? 'Move to Trash' : 'Only the owner can delete',
                    style: canDelete ? TextStyle(color: scheme.error) : null,
                  ),
                ),
              ],
            ),
          ],
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
