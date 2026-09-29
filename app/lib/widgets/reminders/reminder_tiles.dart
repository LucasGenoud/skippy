import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/note.dart';
import '../../screens/editor_screen.dart';
import '../../state/notes_store.dart';
import '../../state/reminder_agenda.dart';
import '../../state/settings_store.dart';
import '../../theme.dart';
import '../../util/motion.dart';
import '../../util/note_routes.dart';
import '../../util/platform.dart';
import '../../util/widget_payload.dart';
import '../animated_presence.dart';
import '../note_zoom.dart';
import 'reminder_editing.dart';

/// Rows are at least this tall, a comfortable touch target.
const double _rowMinHeight = 56;

/// The leading slot every row shares, so titles line up down a group whether
/// the row leads with a checkbox or a badge.
const double _leadingSize = 40;

/// How a row writes its time.
enum ReminderTimeStyle {
  /// Under a day header, where the day is already said: "09:00".
  clock,

  /// Anywhere else: "Yesterday 09:00", "3 Oct, 09:00".
  dayAndClock,
}

/// A rounded surface holding a run of rows, rising off the canvas like a card.
/// Rows that leave (checked off, rescheduled, removed) shrink out instead of
/// popping.
///
/// Rows are opaque and run edge to edge, so their tap highlight fills the
/// rounded shape; the border is drawn over them rather than under.
class ReminderGroup extends StatelessWidget {
  final List<Widget> children;

  const ReminderGroup({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: kBorderRadius,
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: kBorderRadius,
        border: Border.all(color: hairlineColor(scheme)),
      ),
      child: ClipRRect(
        borderRadius: kBorderRadius,
        child: AnimatedPresence(
          layout: (children) => Column(children: children),
          children: children,
        ),
      ),
    );
  }
}

/// A group's title line: "Today  Wed 7 Oct ........ 3".
class ReminderGroupHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final int? count;

  /// Draws the title in the accent, for the one group that is "now".
  final bool highlighted;
  final Widget? trailing;

  const ReminderGroupHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.count,
    this.highlighted = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Padding(
      // Inset like the grid's section labels.
      padding: const EdgeInsets.fromLTRB(
        kSpaceSm,
        kSpaceLg,
        kSpaceSm,
        kSpaceSm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: highlighted ? scheme.primary : scheme.onSurface,
            ),
          ),
          const SizedBox(width: kSpaceSm),
          Expanded(
            child: Text(
              subtitle ?? '',
              style: muted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (count != null) Text('$count', style: muted),
          ?trailing,
        ],
      ),
    );
  }
}

/// One timed reminder: a note's own, or a checklist row's.
///
/// A row's reminder can be ticked off right here; a note's shows what it is
/// and opens the note. On a pointer device a stored reminder can be carried
/// onto a calendar day.
class ReminderTile extends StatelessWidget {
  final ReminderOccurrence reminder;
  final DateTime now;
  final ReminderTimeStyle timeStyle;

  const ReminderTile({
    super.key,
    required this.reminder,
    required this.now,
    this.timeStyle = ReminderTimeStyle.clock,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final reminder = this.reminder;
    final past = reminder.at.isBefore(now);
    final time = context.select<SettingsStore, String>(
      (s) => timeStyle == ReminderTimeStyle.clock
          ? s.formatClock(reminder.at)
          : s.reminderLabel(reminder.at),
    );
    final item = reminder.item;
    final tile = _OpensNote(
      note: reminder.note,
      builder: (open) => _TileBody(
        onTap: open,
        leading: item == null
            ? _NoteBadge(note: reminder.note, icon: Icons.alarm)
            : _CompleteButton(
                key: ValueKey(reminder.key),
                onCompleted: reminder.projected
                    ? null
                    : () => completeReminderItem(context, reminder),
              ),
        title: reminder.title,
        muted: past,
        meta: [
          if (item != null)
            _Meta(Icons.checklist, widgetDisplayTitle(reminder.note)),
          if (reminder.repeat case final ReminderRepeat repeat)
            _Meta(Icons.repeat, repeat.label),
          if (reminder.note.archived)
            const _Meta(Icons.archive_outlined, 'Archived'),
        ],
        trailing: Text(
          time,
          style: theme.textTheme.labelLarge?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
            color: past ? scheme.onSurfaceVariant : scheme.onSurface,
            decoration: past && reminder.repeat == null
                ? TextDecoration.lineThrough
                : null,
          ),
        ),
        menu: _menuFor(context),
      ),
    );
    if (isTouchPrimaryPlatform || reminder.projected) {
      return tile;
    }
    return Draggable<ReminderOccurrence>(
      data: reminder,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _DragFeedback(title: reminder.title),
      childWhenDragging: Opacity(opacity: 0.4, child: tile),
      child: tile,
    );
  }

  List<_MenuEntry> _menuFor(BuildContext context) {
    final reminder = this.reminder;
    final item = reminder.item;
    Future<void> edit() => item == null
        ? editNoteReminder(context, noteId: reminder.note.id)
        : editItemReminder(context, noteId: reminder.note.id, itemId: item.id);
    if (reminder.projected) {
      return [_MenuEntry(Icons.edit_calendar_outlined, 'Edit reminder', edit)];
    }
    final store = context.read<NotesStore>();
    return [
      _MenuEntry(Icons.edit_calendar_outlined, 'Edit reminder', edit),
      // Snoozing a repeating reminder would move the whole series.
      if (reminder.repeat == null)
        for (final snooze in ReminderSnooze.values)
          _MenuEntry(
            Icons.snooze,
            snooze.label,
            () async => rescheduleReminder(
              store,
              reminder,
              snooze.after(DateTime.now()),
            ),
          ),
      _MenuEntry(
        Icons.notifications_off_outlined,
        'Remove reminder',
        () async => removeReminder(context, reminder),
        danger: true,
      ),
    ];
  }
}

/// A note reminded at a saved place.
class PlaceReminderTile extends StatelessWidget {
  final PlaceReminder reminder;

  const PlaceReminderTile({super.key, required this.reminder});

  @override
  Widget build(BuildContext context) {
    final reminder = this.reminder;
    return _OpensNote(
      note: reminder.note,
      builder: (open) => _TileBody(
        onTap: open,
        leading: _NoteBadge(
          note: reminder.note,
          icon: Icons.location_on_outlined,
        ),
        title: reminder.title,
        meta: [
          _Meta(Icons.place_outlined, reminder.placeName),
          _Meta(
            reminder.reminder.repeats ? Icons.repeat : Icons.near_me_outlined,
            reminder.reminder.label,
          ),
          if (reminder.note.archived)
            const _Meta(Icons.archive_outlined, 'Archived'),
        ],
        menu: [
          _MenuEntry(
            Icons.edit_location_alt_outlined,
            'Edit reminder',
            () => editNoteReminder(context, noteId: reminder.note.id),
          ),
          _MenuEntry(
            Icons.location_off_outlined,
            'Remove reminder',
            () async => removePlaceReminder(context, reminder.reminder),
            danger: true,
          ),
        ],
      ),
    );
  }
}

/// Opens [note] from the row it wraps: morphing out of the row into a
/// fullscreen page on phones, or into the centred editor on wide screens.
class _OpensNote extends StatelessWidget {
  final Note note;
  final Widget Function(VoidCallback open) builder;

  const _OpensNote({required this.note, required this.builder});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final fill = context.select<SettingsStore, Color?>(
      (s) => s.resolveColor(note.color, brightness),
    );
    return NoteZoom(
      routeSettings: RouteSettings(name: noteRouteName(note.id)),
      closedColor: scheme.surface,
      openColor: fill ?? scheme.surface,
      closedShape: const RoundedRectangleBorder(),
      openBuilder: (context) => EditorScreen(noteId: note.id),
      closedBuilder: (context, open) => builder(
        () => openNoteEditor(
          context,
          noteId: note.id,
          openFullscreen: open,
          sourceRect: morphSourceRect(context),
        ),
      ),
    );
  }
}

class _MenuEntry {
  final IconData icon;
  final String label;
  final Future<void> Function() onSelected;
  final bool danger;

  const _MenuEntry(
    this.icon,
    this.label,
    this.onSelected, {
    this.danger = false,
  });
}

/// The layout every row shares:
///
/// ```text
///   [leading]  Title that may wrap                    09:00  [...]
///              (icon) meta   (icon) meta
/// ```
///
/// The options button stays visible on touch screens and appears on hover
/// with a pointer, like the grid's card actions.
class _TileBody extends StatefulWidget {
  final Widget leading;
  final String title;
  final bool muted;
  final List<_Meta> meta;
  final Widget? trailing;
  final List<_MenuEntry> menu;
  final VoidCallback onTap;

  const _TileBody({
    required this.onTap,
    required this.leading,
    required this.title,
    required this.meta,
    required this.menu,
    this.muted = false,
    this.trailing,
  });

  @override
  State<_TileBody> createState() => _TileBodyState();
}

class _TileBodyState extends State<_TileBody> {
  bool _hovered = false;
  bool _menuOpen = false;

  Future<void> _showMenu(BuildContext anchor) async {
    final box = anchor.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(anchor).overlay!.context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      box.localToGlobal(Offset.zero, ancestor: overlay) & box.size,
      Offset.zero & overlay.size,
    );
    final scheme = Theme.of(context).colorScheme;
    setState(() => _menuOpen = true);
    final chosen = await showMenu<_MenuEntry>(
      context: context,
      position: position,
      popUpAnimationStyle: Motion.menuFor(context),
      items: [
        for (final entry in widget.menu)
          PopupMenuItem(
            value: entry,
            child: Row(
              children: [
                Icon(
                  entry.icon,
                  size: kCompactIconSize,
                  color: entry.danger ? scheme.error : null,
                ),
                const SizedBox(width: kSpaceMd),
                Text(
                  entry.label,
                  style: entry.danger ? TextStyle(color: scheme.error) : null,
                ),
              ],
            ),
          ),
      ],
    );
    if (!mounted) {
      return;
    }
    setState(() => _menuOpen = false);
    if (chosen == null) {
      return;
    }
    await Motion.waitForMenuDismissal(context);
    if (mounted) {
      await chosen.onSelected();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final showMenuButton = isTouchPrimaryPlatform || _hovered || _menuOpen;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _rowMinHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              kSpaceSm,
              kSpaceSm,
              kSpaceXs,
              kSpaceSm,
            ),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: _leadingSize,
                  child: Center(child: widget.leading),
                ),
                const SizedBox(width: kSpaceSm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: widget.muted
                              ? scheme.onSurfaceVariant
                              : scheme.onSurface,
                        ),
                      ),
                      if (widget.meta.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Wrap(
                            spacing: kSpaceMd,
                            runSpacing: 2,
                            children: widget.meta,
                          ),
                        ),
                    ],
                  ),
                ),
                if (widget.trailing != null) ...[
                  const SizedBox(width: kSpaceSm),
                  widget.trailing!,
                ],
                AnimatedOpacity(
                  opacity: showMenuButton ? 1 : 0,
                  duration: Motion.fast,
                  curve: Motion.standard,
                  child: Builder(
                    builder: (anchor) => IconButton(
                      tooltip: 'Reminder options',
                      icon: const Icon(Icons.more_vert, size: kCompactIconSize),
                      color: scheme.onSurfaceVariant,
                      onPressed: () => _showMenu(anchor),
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

/// A small "what else" fact under a row's title.
class _Meta extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Meta(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: kSpaceXs),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// A round swatch in the note's own colour, so a row is recognisable as the
/// card it came from.
class _NoteBadge extends StatelessWidget {
  final Note note;
  final IconData icon;

  const _NoteBadge({required this.note, required this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final fill = context.select<SettingsStore, Color?>(
      (s) => s.resolveColor(note.color, brightness),
    );
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fill ?? scheme.surfaceContainerHighest,
        border: Border.all(color: hairlineColor(scheme)),
      ),
      child: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
    );
  }
}

/// The round checkbox a checklist row's reminder is ticked off with. The
/// check lands with a small pop before the row leaves, so the tick is seen
/// rather than the row just vanishing.
class _CompleteButton extends StatefulWidget {
  /// Null for a forecast turn, which is not a task that can be done yet.
  final VoidCallback? onCompleted;

  const _CompleteButton({super.key, required this.onCompleted});

  @override
  State<_CompleteButton> createState() => _CompleteButtonState();
}

class _CompleteButtonState extends State<_CompleteButton> {
  bool _checked = false;

  Future<void> _check() async {
    if (_checked) {
      return;
    }
    setState(() => _checked = true);
    await Future<void>.delayed(
      Motion.reduced(context) ? Duration.zero : Motion.base,
    );
    if (mounted) {
      widget.onCompleted!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.onCompleted != null;
    return Semantics(
      checked: _checked,
      label: 'Mark done',
      child: InkResponse(
        onTap: enabled ? _check : null,
        radius: _leadingSize / 2,
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.standard,
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _checked ? scheme.primaryContainer : Colors.transparent,
            border: Border.all(
              width: 2,
              color: _checked
                  ? scheme.primaryContainer
                  : scheme.onSurfaceVariant.withValues(
                      alpha: enabled ? 1 : 0.4,
                    ),
            ),
          ),
          child: AnimatedScale(
            scale: _checked ? 1 : 0,
            duration: Motion.base,
            curve: Motion.emphasized,
            child: Icon(
              Icons.check,
              size: 14,
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}

/// What follows the pointer while a reminder is carried to another day.
class _DragFeedback extends StatelessWidget {
  final String title;

  const _DragFeedback({required this.title});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      borderRadius: kBorderRadius,
      color: scheme.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kSpaceMd,
            vertical: kSpaceSm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.alarm, size: 16, color: scheme.primary),
              const SizedBox(width: kSpaceSm),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
