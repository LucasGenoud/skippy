import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../models/share_link.dart';
import '../util/snack.dart';
import 'form_dialog.dart';

/// What a [PublicLinkDialog] publishes: one target, plus the words to describe
/// it. Built by the caller because only it knows whether "this" is a note, the
/// open workspace's grid, its board, or a label.
class PublicLinkTarget {
  final ShareTarget target;
  final String? noteId;
  final String? workspaceId;
  final String? labelId;

  /// What is being shared, in the user's words ("Focaccia", "Work board").
  final String title;

  /// One sentence spelling out what a holder of the link would see. Views can
  /// expose more than their owner has in mind (a workspace grid includes notes
  /// other members wrote), so this is not boilerplate.
  final String scopeDescription;

  const PublicLinkTarget({
    required this.target,
    required this.title,
    required this.scopeDescription,
    this.noteId,
    this.workspaceId,
    this.labelId,
  });

  bool matches(ShareLink link) =>
      link.target == target &&
      link.noteId == noteId &&
      link.workspaceId == workspaceId &&
      link.labelId == labelId;

  static PublicLinkTarget note(String noteId, String title) => PublicLinkTarget(
    target: ShareTarget.note,
    noteId: noteId,
    title: title.trim().isEmpty ? 'this note' : title.trim(),
    scopeDescription:
        'Anyone with the link can read this note and open its images. '
        'They cannot edit it, and they never see who else it is shared with.',
  );
}

/// How long a new link should last. Deliberately a short menu: the useful
/// answers are "until I revoke it" and "not for long".
enum _LinkLifetime {
  forever('Until I revoke it', null),
  day('1 day', Duration(days: 1)),
  week('7 days', Duration(days: 7)),
  month('30 days', Duration(days: 30));

  final String label;
  final Duration? span;
  const _LinkLifetime(this.label, this.span);
}

/// Publish, copy, or revoke the public link for one target.
///
/// Opening it does not publish anything: the link only exists once the user
/// asks for it, so a stray tap on "Share" never puts a page on the internet.
class PublicLinkDialog extends StatefulWidget {
  final PublicLinkTarget target;
  final Api api;

  const PublicLinkDialog({super.key, required this.target, required this.api});

  static Future<void> show(
    BuildContext context, {
    required PublicLinkTarget target,
    required Api api,
  }) => showFormDialog<void>(
    context,
    builder: (_) => PublicLinkDialog(target: target, api: api),
  );

  @override
  State<PublicLinkDialog> createState() => _PublicLinkDialogState();
}

class _PublicLinkDialogState extends State<PublicLinkDialog> {
  ShareLink? _link;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  _LinkLifetime _lifetime = _LinkLifetime.forever;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  /// Whether this target is already published. Asked on open rather than
  /// tracked in a store: links are rare, the list is small, and a stale answer
  /// here would be worse than a round trip.
  Future<void> _loadExisting() async {
    try {
      final links = await widget.api.fetchShareLinks();
      if (!mounted) return;
      setState(() {
        _link = links.where(widget.target.matches).firstOrNull;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Can't reach the server right now";
      });
    }
  }

  Future<void> _create() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final span = _lifetime.span;
      final link = await widget.api.createShareLink(
        target: widget.target.target,
        noteId: widget.target.noteId,
        workspaceId: widget.target.workspaceId,
        labelId: widget.target.labelId,
        expiresAt: span == null ? null : DateTime.now().add(span),
      );
      if (!mounted) return;
      // Clear the busy flag with the link rather than in `finally`: the
      // clipboard write below goes through a platform channel, and the dialog
      // must not sit disabled waiting on it (an embedder that never answers
      // would otherwise leave Revoke and Copy dead).
      setState(() {
        _link = link;
        _busy = false;
      });
      await _copy(silent: true);
      if (mounted) {
        showAppSnack(
          'Public link created and copied',
          icon: Icons.link,
          kind: SnackKind.success,
        );
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.serverMessage);
    } catch (_) {
      if (mounted) setState(() => _error = "Can't reach the server right now");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke() async {
    final link = _link;
    if (link == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke this link?'),
        content: const Text(
          'The page stops working immediately for everyone holding it. '
          'Nothing else about the notes changes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.deleteShareLink(link.token);
      if (!mounted) return;
      setState(() => _link = null);
      showAppSnack(
        'Public link revoked',
        icon: Icons.link_off,
        kind: SnackKind.danger,
      );
    } catch (_) {
      if (mounted) setState(() => _error = "Can't reach the server right now");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy({bool silent = false}) async {
    final link = _link;
    if (link == null) return;
    await Clipboard.setData(
      ClipboardData(text: publicShareUrl(widget.api.baseUrl, link)),
    );
    if (!silent && mounted) {
      showAppSnack('Link copied', icon: Icons.content_copy);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final link = _link;

    return FormDialog(
      title: const Text('Public link'),
      width: 440,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.target.scopeDescription,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (link != null) ...[
            _LinkRow(
              url: publicShareUrl(widget.api.baseUrl, link),
              onCopy: _copy,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  link.expiresAt == null
                      ? Icons.all_inclusive
                      : Icons.schedule_outlined,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    link.expiresAt == null
                        ? 'Works until you revoke it'
                        : 'Stops working on ${_dateLabel(link.expiresAt!)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ] else ...[
            Text(
              'Sharing ${widget.target.title}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<_LinkLifetime>(
              initialValue: _lifetime,
              decoration: const InputDecoration(
                labelText: 'Link lasts',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: [
                for (final option in _LinkLifetime.values)
                  DropdownMenuItem(value: option, child: Text(option.label)),
              ],
              onChanged: (value) =>
                  setState(() => _lifetime = value ?? _LinkLifetime.forever),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
        ],
      ),
      actions: [
        if (link != null)
          TextButton(
            onPressed: _busy ? null : _revoke,
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: const Text('Revoke'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
        if (link == null && !_loading)
          FilledButton.icon(
            onPressed: _busy ? null : _create,
            icon: const Icon(Icons.link, size: 18),
            label: const Text('Create link'),
          )
        else if (link != null)
          FilledButton.icon(
            onPressed: () => _copy(),
            icon: const Icon(Icons.content_copy, size: 18),
            label: const Text('Copy'),
          ),
      ],
    );
  }

  String _dateLabel(DateTime when) =>
      '${when.day.toString().padLeft(2, '0')}/'
      '${when.month.toString().padLeft(2, '0')}/${when.year}';
}

class _LinkRow extends StatelessWidget {
  final String url;
  final VoidCallback onCopy;

  const _LinkRow({required this.url, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(
            // Selectable, so a browser without clipboard permission (or a
            // user who just wants to read the token) is not stuck.
            child: SelectableText(
              url,
              maxLines: 1,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.content_copy, size: 18),
            tooltip: 'Copy link',
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }
}
