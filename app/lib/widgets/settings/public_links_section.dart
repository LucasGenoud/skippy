import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/share_link.dart';
import '../../state/notes_store.dart';
import '../../state/settings_store.dart';
import '../../util/snack.dart';
import '../form_dialog.dart';

/// Every public link this account has published, with a way to take each one
/// down.
///
/// Links are created from the thing they point at (a note's share dialog, the
/// view's share button), but "what have I put on the internet?" is a question
/// about the account, not about any one note, so it is answered here.
class PublicLinksSection extends StatefulWidget {
  const PublicLinksSection({super.key});

  @override
  State<PublicLinksSection> createState() => _PublicLinksSectionState();
}

class _PublicLinksSectionState extends State<PublicLinksSection> {
  List<ShareLink>? _links;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<NotesStore>().api;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final links = await api.fetchShareLinks();
      if (!mounted) return;
      setState(() {
        _links = links;
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

  Future<void> _revoke(ShareLink link) async {
    final api = context.read<NotesStore>().api;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: Text('Revoke the link to "${link.title}"?'),
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
    if (confirmed != true) return;
    try {
      await api.deleteShareLink(link.token);
      if (!mounted) return;
      setState(() => _links = _links?.where((l) => l != link).toList());
      showAppSnack(
        'Public link revoked',
        icon: Icons.link_off,
        kind: SnackKind.danger,
      );
    } catch (_) {
      showAppSnack(
        "Couldn't revoke the link",
        icon: Icons.error_outline,
        kind: SnackKind.danger,
      );
    }
  }

  Future<void> _copy(ShareLink link) async {
    final api = context.read<NotesStore>().api;
    await Clipboard.setData(
      ClipboardData(text: publicShareUrl(api.baseUrl, link)),
    );
    showAppSnack('Link copied', icon: Icons.content_copy);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final links = _links;

    if (_loading) {
      return const ListTile(
        leading: Icon(Icons.public),
        title: Text('Public links'),
        subtitle: Text('Loading…'),
      );
    }
    if (_error != null) {
      return ListTile(
        leading: Icon(Icons.public_off, color: scheme.error),
        title: const Text('Public links'),
        subtitle: Text(_error!),
        trailing: IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Try again',
          onPressed: _load,
        ),
      );
    }
    if (links == null || links.isEmpty) {
      return ListTile(
        leading: const Icon(Icons.public),
        title: const Text('Public links'),
        subtitle: const Text(
          'Nothing is shared publicly. Share a note or a view to create one.',
        ),
        trailing: IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
          onPressed: _load,
        ),
      );
    }

    final settings = context.watch<SettingsStore>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.public),
          title: const Text('Public links'),
          subtitle: Text(
            '${links.length} ${links.length == 1 ? 'link is' : 'links are'} '
            'readable by anyone holding the URL',
          ),
          trailing: IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
        ),
        for (final link in links)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 32, right: 8),
            leading: Icon(_iconFor(link.target), size: 20),
            title: Text(link.title, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              link.expiresAt == null
                  ? '${link.target.noun} · shared '
                        '${settings.formatDate(link.createdAt)}'
                  : '${link.target.noun} · expires '
                        '${settings.formatDate(link.expiresAt!)}',
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.content_copy, size: 18),
                  tooltip: 'Copy link',
                  onPressed: () => _copy(link),
                ),
                IconButton(
                  icon: const Icon(Icons.link_off, size: 18),
                  tooltip: 'Revoke link',
                  onPressed: () => _revoke(link),
                ),
              ],
            ),
          ),
      ],
    );
  }

  IconData _iconFor(ShareTarget target) => switch (target) {
    ShareTarget.note => Icons.sticky_note_2_outlined,
    ShareTarget.notes => Icons.grid_view_outlined,
    ShareTarget.board => Icons.view_kanban_outlined,
    ShareTarget.label => Icons.label_outline,
  };
}
