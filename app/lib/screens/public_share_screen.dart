import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../api/api_client.dart';
import '../models/note.dart';
import '../models/share_link.dart';
import '../state/settings_store.dart' show kDefaultPalette;
import '../theme.dart';
import '../util/attachment_image.dart';
import '../util/label_style.dart';
import '../widgets/app_logo.dart';
import '../widgets/linked_text.dart';
import '../widgets/masonry.dart';

/// The page behind a public link: someone else's notes, read only, with no
/// account and no session.
///
/// It runs completely outside the signed-in app. There is no `NotesStore` and
/// no `SettingsStore` here, on purpose: nothing on this page can mutate
/// anything, and a reader must never end up holding a store keyed to the
/// publisher. Everything it draws comes from the one payload it fetched.
class PublicShareScreen extends StatefulWidget {
  final String token;
  final Api api;

  const PublicShareScreen({super.key, required this.token, required this.api});

  @override
  State<PublicShareScreen> createState() => _PublicShareScreenState();
}

class _PublicShareScreenState extends State<PublicShareScreen> {
  late Future<PublicShare> _share = _load();

  Future<PublicShare> _load() => widget.api.fetchPublicShare(widget.token);

  void _retry() => setState(() => _share = _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<PublicShare>(
          future: _share,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final share = snapshot.data;
            if (share == null) return _Unavailable(onRetry: _retry);
            return _ShareBody(share: share, api: widget.api);
          },
        ),
      ),
    );
  }
}

/// Revoked, expired, mistyped, or simply gone: all of them look the same from
/// out here, and saying which would leak whether a token was ever real.
class _Unavailable extends StatelessWidget {
  final VoidCallback onRetry;
  const _Unavailable({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.link_off, size: 48, color: scheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(
                'This link is not available',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'It may have been revoked or expired. Ask whoever shared it '
                'for a new one.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShareBody extends StatelessWidget {
  final PublicShare share;
  final Api api;

  const _ShareBody({required this.share, required this.api});

  @override
  Widget build(BuildContext context) {
    final labels = {for (final label in share.labels) label.id: label};
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _Header(share: share)),
        if (share.notes.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyShare(target: share.target),
          )
        else if (share.target == ShareTarget.board)
          SliverToBoxAdapter(
            child: _BoardColumns(share: share, api: api, labels: labels),
          )
        else if (share.target == ShareTarget.note)
          SliverToBoxAdapter(
            child: _SingleNote(
              note: share.notes.first,
              api: api,
              labels: labels,
            ),
          )
        else
          SliverToBoxAdapter(
            child: _Grid(share: share, api: api, labels: labels),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 48)),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final PublicShare share;
  const _Header({required this.share});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const AppLogo(size: 26),
                  const SizedBox(width: 10),
                  Text(
                    'Skippy',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  // Says plainly what this page is, so nobody hunts for an
                  // edit affordance that was never going to be there.
                  Chip(
                    avatar: Icon(
                      Icons.visibility_outlined,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    label: const Text('Read only'),
                    labelStyle: theme.textTheme.labelSmall,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(share.title, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(
                share.sharedBy.isEmpty
                    ? 'Shared with you'
                    : 'Shared by ${share.sharedBy}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: hairlineColor(scheme)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyShare extends StatelessWidget {
  final ShareTarget target;
  const _EmptyShare({required this.target});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(48),
      child: Center(
        child: Text(
          target == ShareTarget.note
              ? 'This note is empty'
              : 'Nothing has been added here yet',
          style: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  final PublicShare share;
  final Api api;
  final Map<String, Label> labels;

  const _Grid({required this.share, required this.api, required this.labels});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = (constraints.maxWidth / 250).floor().clamp(1, 4);
              return AnimatedMasonry(
                notes: share.notes,
                columns: columns,
                spacing: 8,
                dragEnabled: false,
                itemBuilder: (context, note) => PublicNoteCard(
                  key: ValueKey(note.id),
                  note: note,
                  api: api,
                  labels: labels,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The board, laid out as side-by-side columns on a wide screen and stacked
/// sections on a phone. Read-only, so there is none of the drag machinery the
/// signed-in board carries.
class _BoardColumns extends StatelessWidget {
  final PublicShare share;
  final Api api;
  final Map<String, Label> labels;

  const _BoardColumns({
    required this.share,
    required this.api,
    required this.labels,
  });

  @override
  Widget build(BuildContext context) {
    final stages = [...share.stages]
      ..sort((a, b) => a.position.compareTo(b.position));
    final unassigned = share.notes.where((n) => n.stageId == null).toList();
    final columns = <(String, List<Note>)>[
      if (unassigned.isNotEmpty) ('Unassigned', unassigned),
      for (final stage in stages)
        (
          stage.name,
          share.notes.where((n) => n.stageId == stage.id).toList()
            ..sort((a, b) => a.stagePosition.compareTo(b.stagePosition)),
        ),
    ];
    final wide = MediaQuery.sizeOf(context).width >= 700;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: wide
              ? SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final column in columns)
                        SizedBox(
                          width: 300,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: _BoardColumn(
                              title: column.$1,
                              notes: column.$2,
                              api: api,
                              labels: labels,
                            ),
                          ),
                        ),
                    ],
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final column in columns)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: _BoardColumn(
                          title: column.$1,
                          notes: column.$2,
                          api: api,
                          labels: labels,
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _BoardColumn extends StatelessWidget {
  final String title;
  final List<Note> notes;
  final Api api;
  final Map<String, Label> labels;

  const _BoardColumn({
    required this.title,
    required this.notes,
    required this.api,
    required this.labels,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: boardColumnColor(scheme),
        borderRadius: kBorderRadius,
        border: Border.all(color: boardColumnBorderColor(scheme)),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${notes.length}',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          for (final note in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: PublicNoteCard(note: note, api: api, labels: labels),
            ),
        ],
      ),
    );
  }
}

class _SingleNote extends StatelessWidget {
  final Note note;
  final Api api;
  final Map<String, Label> labels;

  const _SingleNote({
    required this.note,
    required this.api,
    required this.labels,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          // The single-note page shows the whole note rather than a card's
          // preview, so nothing is clipped and there is nowhere to tap through
          // to.
          child: PublicNoteCard(
            note: note,
            api: api,
            labels: labels,
            expanded: true,
          ),
        ),
      ),
    );
  }
}

/// One note, drawn read-only.
///
/// Deliberately not `NoteCard`: that widget reads the signed-in stores for
/// colours, labels, and every mutation it offers. This one takes everything it
/// needs as arguments and offers nothing to press except the links in the text.
class PublicNoteCard extends StatelessWidget {
  final Note note;
  final Api api;
  final Map<String, Label> labels;

  /// Show the note in full (the single-note page) rather than as a capped
  /// preview (the grid and board).
  final bool expanded;

  const PublicNoteCard({
    super.key,
    required this.note,
    required this.api,
    required this.labels,
    this.expanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fill = _publicNoteColor(note.color, theme.brightness);
    final images = note.attachments.where((a) => a.isImage).toList();
    final noteLabels = [
      for (final id in note.labelIds)
        if (labels[id] case final Label label) label,
    ];

    return Container(
      decoration: BoxDecoration(
        color: fill ?? scheme.surface,
        borderRadius: kBorderRadius,
        border: Border.all(color: hairlineColor(scheme)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (note.title.trim().isNotEmpty) ...[
                  Text(
                    note.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: expanded ? null : 3,
                    overflow: expanded ? null : TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                ],
                if (note.isChecklist)
                  _Checklist(note: note, expanded: expanded)
                else if (note.kind == NoteKind.markdown)
                  MarkdownBody(
                    data: note.content,
                    shrinkWrap: true,
                    selectable: false,
                  )
                else if (note.content.trim().isNotEmpty)
                  LinkedText(
                    text: note.content,
                    style: theme.textTheme.bodyMedium,
                    maxLines: expanded ? null : 12,
                    overflow: expanded
                        ? TextOverflow.clip
                        : TextOverflow.ellipsis,
                  ),
                if (noteLabels.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final label in noteLabels) _LabelChip(label: label),
                    ],
                  ),
                ],
              ],
            ),
          ),
          // Images sit below the text, matching the signed-in card.
          for (final image in images)
            Image(
              image: AttachmentImage(
                attachmentId: image.id,
                url: api.attachmentUrl(image),
              ),
              fit: BoxFit.cover,
              width: double.infinity,
              errorBuilder: (context, _, _) => const SizedBox.shrink(),
            ),
        ],
      ),
    );
  }
}

class _Checklist extends StatelessWidget {
  final Note note;
  final bool expanded;
  const _Checklist({required this.note, required this.expanded});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Pending first, then what's already done: the same reading order the
    // home-screen widget uses.
    final items = [
      ...note.items.where((i) => !i.done),
      ...note.items.where((i) => i.done),
    ];
    final shown = expanded || items.length <= 8
        ? items
        : items.take(8).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final item in shown)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  item.done
                      ? Icons.check_box_outlined
                      : Icons.check_box_outline_blank,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      decoration: item.done ? TextDecoration.lineThrough : null,
                      color: item.done ? scheme.onSurfaceVariant : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (shown.length < items.length)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '+${items.length - shown.length} more',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _LabelChip extends StatelessWidget {
  final Label label;
  const _LabelChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = labelColor(label, scheme.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(kRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(labelIcon(label), size: 13, color: tint),
          const SizedBox(width: 5),
          Text(
            label.name,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: tint),
          ),
        ],
      ),
    );
  }
}

/// A note's fill on a public page.
///
/// Resolved from the stock palette rather than the publisher's customized one:
/// their palette is a private setting, and the server does not send it with
/// the share. A note wearing a colour they renamed or replaced falls back to
/// the plain surface, the same way the app treats a removed colour.
Color? _publicNoteColor(String key, Brightness brightness) {
  if (key == 'default') return null;
  for (final entry in kDefaultPalette) {
    if (entry.key == key) {
      return brightness == Brightness.light ? entry.light : entry.dark;
    }
  }
  return null;
}
