import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../screens/workspace_settings_screen.dart';
import '../../state/auth_store.dart';
import '../../state/notes_store.dart';
import '../../state/settings_store.dart';
import '../../util/app_fonts.dart';
import '../../util/app_version.dart';
import '../page_header.dart';
import '../shortcut_help.dart';
import 'account_section.dart';
import 'accent_color.dart';
import 'ai_access_section.dart';
import 'device_notifications_tile.dart';
import 'embedding_section.dart';
import 'export_section.dart';
import 'grid_layout_section.dart';
import 'llm_section.dart';
import 'notify_section.dart';
import 'palette_section.dart';
import 'public_links_section.dart';
import 'saved_locations_section.dart';

/// The account's settings, grouped by what someone comes looking for rather
/// than by what backs them. Workspace settings (members, collections, which
/// AI a workspace allows) live on each workspace's own page.
enum SettingsPage {
  account('Account', Icons.person_outline),
  appearance('Appearance', Icons.palette_outlined),
  reminders('Reminders', Icons.notifications_none),
  ai('AI & search', Icons.auto_awesome_outlined),
  sharing('Sharing & access', Icons.link),
  data('Backup & import', Icons.inventory_2_outlined),
  about('About', Icons.info_outline);

  final String title;
  final IconData icon;

  const SettingsPage(this.title, this.icon);

  /// One line on where things stand, shown under the page's name in the index.
  String summary(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    switch (this) {
      case SettingsPage.account:
        return context.watch<AuthStore?>()?.user?.email ??
            'Your name, email, and password';
      case SettingsPage.appearance:
        final theme = switch (settings.themeMode) {
          ThemeMode.system => 'Automatic',
          ThemeMode.light => 'Light',
          ThemeMode.dark => 'Dark',
        };
        return '$theme theme · ${settings.gridDensity.label} grid';
      case SettingsPage.reminders:
        final places = settings.savedLocations.length;
        final parts = [
          if (settings.deviceNotificationsEnabled) 'On this device',
          if (settings.notifyConfigured &&
              settings.reminderNotificationsEnabled)
            'Push',
          if (places > 0) '$places ${places == 1 ? 'place' : 'places'}',
        ];
        return parts.isEmpty ? 'Not delivered anywhere yet' : parts.join(' · ');
      case SettingsPage.ai:
        return settings.llmConfigured
            ? 'Provider: ${settings.llmModel}'
            : 'No AI provider yet';
      case SettingsPage.sharing:
        return 'Public links and assistant tokens';
      case SettingsPage.data:
        return 'Backup, restore, Google Keep, export';
      case SettingsPage.about:
        return 'Version $clientVersion';
    }
  }
}

/// The rows of one [SettingsPage], as a scrolling sheet.
class SettingsPageBody extends StatelessWidget {
  final SettingsPage page;

  /// Opens with the page's name, for when no app bar carries it.
  final bool titled;

  const SettingsPageBody({super.key, required this.page, this.titled = false});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (titled) PageHeader(title: page.title),
        ..._rows(context),
      ],
    );
  }

  List<Widget> _rows(BuildContext context) {
    return switch (page) {
      SettingsPage.account => _account(),
      SettingsPage.appearance => _appearance(context),
      SettingsPage.reminders => _reminders(context),
      SettingsPage.ai => _ai(context),
      SettingsPage.sharing => _sharing(context),
      SettingsPage.data => const [ExportSection()],
      SettingsPage.about => _about(context),
    };
  }

  List<Widget> _account() => const [
    AccountSection(),
    Divider(height: 32),
    SectionHeader('Danger zone'),
    DeleteAccountTile(),
  ];

  List<Widget> _appearance(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final now = DateTime.now();
    return [
      const SectionHeader('Theme'),
      ListTile(
        leading: const Icon(Icons.brightness_6_outlined),
        title: const Text('Theme'),
        trailing: SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(value: ThemeMode.system, label: Text('Auto')),
            ButtonSegment(value: ThemeMode.light, label: Text('Light')),
            ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
          ],
          selected: {settings.themeMode},
          onSelectionChanged: (s) => settings.setThemeMode(s.first),
          showSelectedIcon: false,
        ),
      ),
      const AccentColorTile(),
      const _FontField(),
      const Divider(height: 32),
      const SectionHeader('Notes grid'),
      const GridLayoutSection(),
      const Divider(height: 32),
      const SectionHeader('Note colors'),
      const _Hint(
        'Personalize the colors available for your notes. '
        'Each color has a light-theme and a dark-theme shade.',
      ),
      for (final entry in settings.palette)
        PaletteRow(key: ValueKey(entry.key), entry: entry),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            TextButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add color'),
              onPressed: () => PaletteEditDialog.show(context, null),
            ),
            const Spacer(),
            TextButton(
              onPressed: settings.resetPalette,
              child: const Text('Reset to defaults'),
            ),
          ],
        ),
      ),
      const Divider(height: 32),
      const SectionHeader('Date & time'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: DropdownButtonFormField<AppDateFormat>(
          initialValue: settings.dateFormat,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Date format',
            helperText: 'Today: ${settings.formatDate(now)}',
            prefixIcon: const Icon(Icons.calendar_today_outlined),
            border: const OutlineInputBorder(),
          ),
          onChanged: (format) {
            if (format != null) {
              settings.setDateFormat(format);
            }
          },
          items: [
            for (final format in AppDateFormat.values)
              DropdownMenuItem(
                value: format,
                child: Text('${format.label} (${format.example})'),
              ),
          ],
        ),
      ),
      ListTile(
        leading: const Icon(Icons.schedule_outlined),
        title: const Text('Time format'),
        subtitle: Text('Now: ${settings.formatClock(now)}'),
        trailing: SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('12h')),
            ButtonSegment(value: true, label: Text('24h')),
          ],
          selected: {settings.use24hTime},
          onSelectionChanged: (s) => settings.setUse24hTime(s.first),
          showSelectedIcon: false,
        ),
      ),
    ];
  }

  List<Widget> _reminders(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    return [
      const SectionHeader('On this device'),
      const DeviceNotificationsTile(),
      const Divider(height: 32),
      const SectionHeader('Push notifications'),
      const NotifyConfigTile(),
      SwitchListTile(
        secondary: const Icon(Icons.notifications_active_outlined),
        title: const Text('Reminder notifications'),
        subtitle: Text(
          settings.notifyConfigured
              ? 'Send a push when a note\'s reminder comes due'
              : 'Configure a channel first',
        ),
        value:
            settings.notifyConfigured && settings.reminderNotificationsEnabled,
        onChanged: settings.notifyConfigured
            ? settings.setReminderNotificationsEnabled
            : null,
      ),
      const Divider(height: 32),
      const SectionHeader('Saved places'),
      const SavedLocationsSection(),
    ];
  }

  List<Widget> _ai(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    return [
      const SectionHeader('Search'),
      _FeatureToggle(
        icon: Icons.manage_search,
        title: 'Semantic search',
        available: 'Search your notes by meaning, not just keywords',
        capable: settings.semanticSearchCapable,
        value: settings.semanticSearchEnabled,
        onChanged: settings.setSemanticSearchEnabled,
      ),
      if (settings.semanticSearchCapable) const EmbeddingStatsTile(),
      const Divider(height: 32),
      const SectionHeader('Your AI provider'),
      const _Hint(
        'Runs labeling, chat, and editing in the workspaces you own, for '
        'everyone in them. Each workspace turns these on or off in its own '
        'settings.',
      ),
      const LlmConfigTile(),
      const LlmBehaviorTile(),
      const LlmRewriteTasksTile(),
      const _WorkspaceAiLink(),
    ];
  }

  List<Widget> _sharing(BuildContext context) => [
    const PublicLinksSection(),
    const AiAccessSection(),
    const _Hint(
      "A workspace's owner decides whether assistants can reach its notes.",
    ),
  ];

  List<Widget> _about(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    String server(bool capable, String yes) =>
        capable ? yes : 'Not set up on this server';
    return [
      const ListTile(
        leading: Icon(Icons.phone_android_outlined),
        title: Text('Client version'),
        subtitle: Text(clientVersion),
      ),
      ListTile(
        leading: const Icon(Icons.dns_outlined),
        title: const Text('Server version'),
        subtitle: Text(settings.serverVersion ?? 'Unavailable'),
      ),
      const Divider(height: 32),
      const SectionHeader('This server'),
      ListTile(
        leading: const Icon(Icons.manage_search),
        title: const Text('Semantic search'),
        subtitle: Text(
          server(settings.semanticSearchCapable, 'Finds notes by meaning'),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.mic_none),
        title: const Text('Voice transcription'),
        subtitle: Text(
          settings.audioTranscriptionCapable
              ? 'Whisper transcribes audio notes'
              : 'Not set up: audio notes record and play without a transcript',
        ),
      ),
      ListTile(
        leading: const Icon(Icons.image_search_outlined),
        title: const Text('Text in images'),
        subtitle: Text(
          server(
            settings.imageOcrCapable,
            'Words in pictures are read so search can find them',
          ),
        ),
      ),
      const Divider(height: 32),
      ListTile(
        leading: const Icon(Icons.keyboard_outlined),
        title: const Text('Keyboard shortcuts'),
        subtitle: const Text('Also opens with ? on the notes screen'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showShortcutHelp(context),
      ),
    ];
  }
}

/// Where the open workspace's AI switches live, and what they say.
class _WorkspaceAiLink extends StatelessWidget {
  const _WorkspaceAiLink();

  @override
  Widget build(BuildContext context) {
    final workspace = context.watch<NotesStore?>()?.activeWorkspace;
    if (workspace == null) {
      return const SizedBox.shrink();
    }
    final switches = workspace.ai.switches;
    final on = [
      if (switches.labeling) 'labeling',
      if (switches.chat) 'chat',
      if (switches.writing) 'editing',
    ];
    final String state;
    if (!switches.enabled || on.isEmpty) {
      state = 'AI is off here';
    } else {
      state = 'On: ${on.join(', ')}';
    }
    return ListTile(
      leading: const Icon(Icons.workspaces_outlined),
      title: Text('AI in ${workspace.name}'),
      subtitle: Text(state),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(
        context,
      ).push(WorkspaceSettingsScreen.route(workspace.id)),
    );
  }
}

/// A quiet line explaining the rows under a section header.
/// Picks the typeface the whole app is set in. Each option is drawn in its
/// own face, so opening the list starts loading every one.
class _FontField extends StatelessWidget {
  const _FontField();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();

    // The family a theme without one falls back to, so "System default"
    // previews the platform font even while another face is in use.
    final platformFamily = Theme.of(
      context,
    ).typography.black.bodyMedium?.fontFamily;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: DropdownButtonFormField<AppFont>(
        initialValue: settings.font,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Font',
          prefixIcon: Icon(Icons.text_fields),
          border: OutlineInputBorder(),
        ),
        onTap: () {
          for (final font in AppFont.values) {
            unawaited(AppFontLoader.instance.load(font));
          }
        },
        onChanged: (font) {
          if (font != null) {
            settings.setFont(font);
          }
        },
        items: [
          for (final font in AppFont.values)
            DropdownMenuItem(
              value: font,
              child: Text(
                font.label,
                style: TextStyle(fontFamily: font.family ?? platformFamily),
              ),
            ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;

  const _Hint(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A toggle for an optional, service-backed feature. When the server doesn't
/// advertise the capability the switch is disabled and explains why, so the
/// preference is still visible but clearly inert.
class _FeatureToggle extends StatelessWidget {
  final IconData icon;
  final String title;

  /// Subtitle shown when the backing service is running.
  final String available;
  final bool capable;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _FeatureToggle({
    required this.icon,
    required this.title,
    required this.available,
    required this.capable,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(title),
      subtitle: Text(capable ? available : 'Not available on this server'),
      // Off and inert when the service isn't running.
      value: capable && value,
      onChanged: capable ? onChanged : null,
    );
  }
}
