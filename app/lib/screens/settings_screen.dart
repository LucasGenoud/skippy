import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/auth_store.dart';
import '../theme.dart';
import '../util/motion.dart';
import '../widgets/screen_width.dart';
import '../widgets/settings/settings_pages.dart';
import '../widgets/state_cross_fade.dart';

export '../widgets/settings/settings_pages.dart' show SettingsPage;

/// The account's settings, as an index of [SettingsPage]s. A phone opens each
/// page on its own; a wide window keeps the index beside the open page.
///
/// ```text
///   narrow                  wide
///   ┌─────────────┐         ┌────────────┬──────────────────┐
///   │ (Me)      › │         │ Account    │ Appearance       │
///   │ Appearance› │   ──►   │▐Appearance │  THEME           │
///   │ Reminders › │         │ Reminders  │  Theme  [Auto]   │
///   └─────────────┘         └────────────┴──────────────────┘
/// ```
class SettingsScreen extends StatefulWidget {
  /// The page to open on. Null shows the index on a phone, and Account beside
  /// it on a wide window.
  final SettingsPage? page;

  const SettingsScreen({super.key, this.page});

  static Route<void> route({SettingsPage? page}) =>
      MaterialPageRoute(builder: (_) => SettingsScreen(page: page));

  /// Wide enough for the index and a page side by side.
  static const double splitBreakpoint = 840;
  static const double _indexWidth = 300;
  static const double _pageMaxWidth = 640;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsPage _selected = widget.page ?? SettingsPage.account;

  @override
  Widget build(BuildContext context) {
    // Settings is a sheet of rows, not cards on a canvas, so the whole page is
    // the surface those rows are printed on.
    final background = Theme.of(context).colorScheme.surface;
    if (ScreenWidth.isAtLeast(context, SettingsScreen.splitBreakpoint)) {
      return Scaffold(
        backgroundColor: background,
        appBar: AppBar(title: const Text('Settings')),
        body: _split(),
      );
    }

    final page = widget.page;
    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(title: Text(page?.title ?? 'Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: SettingsScreen._pageMaxWidth,
          ),
          child: page == null ? _index() : SettingsPageBody(page: page),
        ),
      ),
    );
  }

  Widget _index() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _AccountRow(onTap: () => _push(SettingsPage.account)),
        const Divider(height: 16),
        for (final page in SettingsPage.values)
          if (page != SettingsPage.account)
            ListTile(
              leading: Icon(page.icon),
              title: Text(page.title),
              subtitle: Text(page.summary(context)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _push(page),
            ),
      ],
    );
  }

  void _push(SettingsPage page) =>
      Navigator.of(context).push(SettingsScreen.route(page: page));

  Widget _split() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: SettingsScreen._indexWidth,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
            children: [
              for (final page in SettingsPage.values)
                _IndexRow(
                  page: page,
                  selected: page == _selected,
                  onTap: () => setState(() => _selected = page),
                ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: StateCrossFade(
            state: _selected,
            child: Align(
              alignment: AlignmentDirectional.topStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: SettingsScreen._pageMaxWidth,
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 16),
                  child: SettingsPageBody(page: _selected, titled: true),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The account as the index's first row: who is signed in.
class _AccountRow extends StatelessWidget {
  final VoidCallback onTap;

  const _AccountRow({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthStore?>()?.user;
    final scheme = Theme.of(context).colorScheme;
    final name = user?.name.trim() ?? '';
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        child: name.isEmpty
            ? Icon(SettingsPage.account.icon)
            : Text(name.characters.first.toUpperCase()),
      ),
      title: Text(name.isEmpty ? SettingsPage.account.title : name),
      subtitle: Text(SettingsPage.account.summary(context)),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// A page in the wide index. The selection fill fades in rather than
/// snapping, like the app sidebar's.
class _IndexRow extends StatelessWidget {
  final SettingsPage page;
  final bool selected;
  final VoidCallback onTap;

  const _IndexRow({
    required this.page,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final target = selected ? 1.0 : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: TweenAnimationBuilder<double>(
        // begin == end, so a row that starts selected doesn't fade in.
        tween: Tween<double>(begin: target, end: target),
        duration: Motion.fast,
        curve: Motion.standard,
        builder: (context, t, child) => Material(
          color: Color.lerp(Colors.transparent, scheme.secondaryContainer, t),
          borderRadius: BorderRadius.circular(kRadius),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
        // No summary: the page itself is open beside the index.
        child: ListTile(
          leading: Icon(page.icon),
          title: Text(page.title),
          onTap: onTap,
        ),
      ),
    );
  }
}
