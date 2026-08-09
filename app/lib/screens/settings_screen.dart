import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/settings_store.dart';
import '../util/app_version.dart';
import '../widgets/settings/account_section.dart';
import '../widgets/settings/accent_color.dart';
import '../widgets/settings/device_notifications_tile.dart';
import '../widgets/settings/embedding_section.dart';
import '../widgets/settings/export_section.dart';
import '../widgets/settings/grid_layout_section.dart';
import '../widgets/settings/llm_section.dart';
import '../widgets/settings/notify_section.dart';
import '../widgets/settings/palette_section.dart';
import '../widgets/settings/public_links_section.dart';
import '../widgets/settings/saved_locations_section.dart';
import '../widgets/shortcut_help.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const SettingsScreen());

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              const _SectionHeader('Account'),
              const AccountSection(),
              const Divider(height: 32),
              const _SectionHeader('Appearance'),
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
              SwitchListTile(
                secondary: const Icon(Icons.view_agenda_outlined),
                title: const Text('Open in single-column list'),
                subtitle: const Text('Default layout when the app starts'),
                value: settings.defaultListMode,
                onChanged: settings.setDefaultListMode,
              ),
              const GridLayoutSection(),
              const Divider(height: 32),
              const _SectionHeader('Features'),
              _FeatureToggle(
                icon: Icons.auto_awesome,
                title: 'Semantic search',
                available: 'Search your notes by meaning, not just keywords',
                capable: settings.semanticSearchCapable,
                value: settings.semanticSearchEnabled,
                onChanged: settings.setSemanticSearchEnabled,
              ),
              if (settings.semanticSearchCapable) const EmbeddingStatsTile(),
              ListTile(
                leading: const Icon(Icons.mic_none),
                title: const Text('Audio notes'),
                subtitle: Text(
                  settings.audioTranscriptionCapable
                      ? 'Record and play voice notes; local Whisper transcribes them'
                      : 'Record and play voice notes; transcription needs local Whisper',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.image_search_outlined),
                title: const Text('Text in images'),
                subtitle: Text(
                  settings.imageOcrCapable
                      ? 'Uploaded pictures are read so you can search the words in them'
                      : 'Searching the words inside pictures needs local OCR',
                ),
              ),
              const Divider(height: 32),
              const _SectionHeader('AI'),
              const LlmConfigTile(),
              SwitchListTile(
                secondary: const Icon(Icons.label_outline),
                title: const Text('Automatic labeling'),
                subtitle: Text(
                  settings.llmConfigured
                      ? 'Apply your existing labels to new and edited notes'
                      : 'Configure an AI provider first',
                ),
                value: settings.llmConfigured && settings.llmLabelingEnabled,
                onChanged: settings.llmConfigured
                    ? settings.setLlmLabelingEnabled
                    : null,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.forum_outlined),
                title: const Text('Notes chat'),
                subtitle: Text(
                  !settings.semanticSearchCapable
                      ? 'Requires semantic search on this server'
                      : settings.llmConfigured
                      ? 'Ask questions about your notes'
                      : 'Configure an AI provider first',
                ),
                value:
                    settings.llmConfigured &&
                    settings.semanticSearchCapable &&
                    settings.llmChatEnabled,
                onChanged:
                    settings.llmConfigured && settings.semanticSearchCapable
                    ? settings.setLlmChatEnabled
                    : null,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.auto_fix_high_outlined),
                title: const Text('AI note editing'),
                subtitle: Text(
                  settings.llmConfigured
                      ? 'Add cleanup and grammar actions to each note menu'
                      : 'Configure an AI provider first',
                ),
                value: settings.llmConfigured && settings.llmWritingEnabled,
                onChanged: settings.llmConfigured
                    ? settings.setLlmWritingEnabled
                    : null,
              ),
              const Divider(height: 32),
              const _SectionHeader('Notifications'),
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
                    settings.notifyConfigured &&
                    settings.reminderNotificationsEnabled,
                onChanged: settings.notifyConfigured
                    ? settings.setReminderNotificationsEnabled
                    : null,
              ),
              const DeviceNotificationsTile(),
              const Divider(height: 32),
              const _SectionHeader('Saved locations'),
              const SavedLocationsSection(),
              const Divider(height: 32),
              const _SectionHeader('Date & time'),
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
                    if (format != null) settings.setDateFormat(format);
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
              const Divider(height: 32),
              const _SectionHeader('Note colors'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Personalize the colors available for your notes. '
                  'Each color has a light-theme and a dark-theme shade.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
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
              const _SectionHeader('Sharing'),
              const PublicLinksSection(),
              const Divider(height: 32),
              const _SectionHeader('Data'),
              const ExportSection(),
              const Divider(height: 32),
              const _SectionHeader('Help'),
              ListTile(
                leading: const Icon(Icons.keyboard_outlined),
                title: const Text('Keyboard shortcuts'),
                subtitle: const Text('Also opens with ? on the notes screen'),
                onTap: () => showShortcutHelp(context),
              ),
              const Divider(height: 32),
              const _SectionHeader('About'),
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
              const _SectionHeader('Danger zone'),
              const DeleteAccountTile(),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          letterSpacing: 1.2,
          color: Theme.of(context).colorScheme.primary,
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
