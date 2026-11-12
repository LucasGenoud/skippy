import 'package:flutter/foundation.dart'
    show kIsWeb, ValueListenable, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';

import '../models/collection.dart';
import '../models/note.dart';
import '../models/workspace.dart' show WorkspaceAi;
import '../screens/editor_screen.dart';
import '../state/note_availability.dart';
import '../state/note_links.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../theme.dart';
import '../util/highlight.dart';
import '../util/keyboard.dart';
import '../util/label_style.dart';
import '../util/motion.dart';
import '../util/note_image.dart';
import '../util/note_routes.dart';
import '../util/platform.dart';
import '../util/snack.dart';
import 'board/move_to_stage_sheet.dart';
import 'checklist/check_mark.dart';
import 'collection_settings.dart';
import 'color_picker.dart';
import 'labels_sheet.dart';
import 'link_preview.dart';
import 'link_summary_indicator.dart';
import 'linked_text.dart';
import 'masonry.dart';
import 'note_actions.dart';
import 'note_zoom.dart';
import 'pick_image.dart';
import 'pin_icon.dart';
import 'reminder_chip.dart';
import 'reminders/reminder_editing.dart';
import 'screen_width.dart';
import 'swipe_to_archive.dart';
import 'transcribing_indicator.dart';
import 'workspace_menu.dart';
import 'note_markdown.dart';
import 'note_pattern.dart';

part 'note_card/actions.dart';
part 'note_card/content.dart';
part 'note_card/labels.dart';

/// How far a card's edge leans from its fill toward the text colour: a
/// coloured card at rest in light and dark, and any card under the pointer.
const double _edgeInkLight = 0.09;
const double _edgeInkDark = 0.10;
const double _edgeInkHover = 0.16;

/// A note in the grid. Narrow layouts use [NoteZoom] to morph into the
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
    try {
      await editNoteReminder(context, noteId: widget.note.id);
    } finally {
      _reminderPickerOpen = false;
    }
  }

  Future<void> _addImage() async {
    // The picker is a native screen; anything still focused behind it (the
    // search field, a quick-add composer) comes back with the keyboard up.
    dismissKeyboard();
    final store = context.read<NotesStore>();
    try {
      final picked = await pickNoteImage(context);
      if (picked == null || withinUploadLimit([picked]).isEmpty) return;
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
          openFullscreen: () => Navigator.of(
            context,
          ).push(NoteZoomRoute(builder: (_) => EditorScreen(noteId: copy.id))),
        );
      },
    );
  }

  void _archive() {
    final store = context.read<NotesStore>();
    toggleArchive(store, store.noteById(widget.note.id) ?? widget.note);
  }

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
    // Every card draws its edge: the separation from the canvas is the edge's
    // job, not the fill's. A coloured card's edge is its own fill a step toward
    // the text colour, so it reads as the card's edge rather than an outline
    // drawn around it, on any palette.
    final light = brightness == Brightness.light;
    final edgeBase = fill ?? scheme.outlineVariant;
    final edgeInk = _hovered
        ? _edgeInkHover
        : (fill == null ? 0.0 : (light ? _edgeInkLight : _edgeInkDark));
    final borderColor = Color.lerp(edgeBase, scheme.onSurface, edgeInk)!;
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
        ? context.select<NotesStore, _Tag?>((store) {
            final collections = store
                .workspaceById(note.workspaceId)
                ?.collections;
            if (collections == null) return null;
            for (final collection in collections) {
              if (collection.id ==
                  (note.collectionId ??
                      NoteCollection.generalId(note.workspaceId))) {
                return _tagOf(
                  collection.name,
                  collection.color,
                  collection.icon,
                );
              }
            }
            return null;
          })
        : null;

    final cardShape = RoundedRectangleBorder(
      borderRadius: kCardBorderRadius,
      side: BorderSide(
        color: widget.selected ? scheme.primary : borderColor,
        width: widget.selected ? 2 : 1,
      ),
    );
    Widget closedCard(VoidCallback open) => InkWell(
      borderRadius: kCardBorderRadius,
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
          if (collection != null) _CollectionMarker(tag: collection),
          _PinButton(note: note, hovered: _hovered, hidden: isRewriting),
          if (isRewriting) const _NoteRewriteProgress(),
          // Positioned stays put so the row can fade out rather than vanish
          // with the pointer; at rest it holds nothing.
          Positioned(
            left: 8,
            right: 8,
            bottom: 4 + actionsBottomInset,
            height: 40,
            child: AnimatedSwitcher(
              duration: Motion.reduced(context) ? Duration.zero : Motion.fast,
              switchInCurve: Motion.standard,
              switchOutCurve: Motion.standard,
              child: desktopActions && actionsVisible
                  ? _NoteActions(
                      note: note,
                      rewriting: isRewriting,
                      showMoveToStage: widget.openedFromBoard,
                      onReminder: _editReminder,
                      onImage: _addImage,
                      onArchive: _archive,
                      onDuplicate: _duplicate,
                      onMenuOpened: () => setState(() => _menuOpen = true),
                      onMenuClosed: () => setState(() => _menuOpen = false),
                    )
                  // Keyed: the default transition keys on its child, and two
                  // unkeyed children would cut the exit short.
                  : const SizedBox.shrink(key: ValueKey('no-actions')),
            ),
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
            child: NotePatternBackground(
              pattern: note.pattern,
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
            ),
          )
        : NoteZoom(
            routeSettings: RouteSettings(name: noteRouteName(note.id)),
            closedColor: fill ?? scheme.surface,
            openColor: fill ?? scheme.surface,
            closedShape: cardShape,
            closedBuilder: (context, open) => NotePatternBackground(
              pattern: note.pattern,
              child: closedCard(open),
            ),
            openBuilder: (context) => EditorScreen(
              noteId: note.id,
              openedFromBoard: widget.openedFromBoard,
            ),
          );

    // The selection badge straddles the card's corner outside the clip.
    final cardContent = AnimatedContainer(
      duration: Motion.fast,
      curve: Motion.standard,
      decoration: BoxDecoration(
        borderRadius: kCardBorderRadius,
        boxShadow: cardShadow(
          scheme,
          _hovered ? CardLift.raised : CardLift.resting,
        ),
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

/// The archive-only collection marker is a quiet corner glyph rather than a
/// metadata chip. Its tooltip carries the collection name without competing
/// with the note's own tags.
class _CollectionMarker extends StatelessWidget {
  final _Tag tag;
  const _CollectionMarker({required this.tag});

  @override
  Widget build(BuildContext context) {
    final name = tag.name;
    final color = PaletteEntry.hexToColor(tag.color);
    final icon = labelIconFor(tag.icon);
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
          child: _BuiltOnceShown(
            shown: show,
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
          child: _BuiltOnceShown(
            shown: visible,
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
      ),
    );
  }
}

/// Builds [child] the first time it is [shown], and keeps it from then on so
/// it can fade out again.
///
/// For the controls a card only shows under the pointer. A grid mounts dozens
/// of cards at once and most are never hovered, while each of these is a
/// whole button (tooltip, ink, material) that cost about as much to build as
/// the card's own content.
class _BuiltOnceShown extends StatefulWidget {
  final bool shown;
  final Widget child;

  const _BuiltOnceShown({required this.shown, required this.child});

  @override
  State<_BuiltOnceShown> createState() => _BuiltOnceShownState();
}

class _BuiltOnceShownState extends State<_BuiltOnceShown> {
  bool _built = false;

  @override
  Widget build(BuildContext context) {
    _built |= widget.shown;
    return _built ? widget.child : const SizedBox.expand();
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
