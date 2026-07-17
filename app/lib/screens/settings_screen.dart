import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/notify_channels.dart';
import '../state/notes_store.dart';
import '../state/settings_store.dart';
import '../theme.dart';
import '../util/download.dart';
import '../util/note_export.dart';
import '../util/snack.dart';
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
              const _AccentColorTile(),
              SwitchListTile(
                secondary: const Icon(Icons.view_agenda_outlined),
                title: const Text('Open in single-column list'),
                subtitle: const Text('Default layout when the app starts'),
                value: settings.defaultListMode,
                onChanged: settings.setDefaultListMode,
              ),
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
              _FeatureToggle(
                icon: Icons.mic_none,
                title: 'Audio notes',
                available:
                    'Record voice notes and transcribe them with local Whisper',
                capable: settings.audioTranscriptionCapable,
                value: settings.audioNotesEnabled,
                onChanged: settings.setAudioNotesEnabled,
              ),
              const Divider(height: 32),
              const _SectionHeader('AI'),
              const _LlmConfigTile(),
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
              const Divider(height: 32),
              const _SectionHeader('Notifications'),
              const _NotifyConfigTile(),
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
              const Divider(height: 32),
              const _SectionHeader('Date & time'),
              ListTile(
                leading: const Icon(Icons.calendar_today_outlined),
                title: const Text('Date format'),
                subtitle: Text('Today: ${settings.formatDate(now)}'),
                trailing: DropdownButton<AppDateFormat>(
                  value: settings.dateFormat,
                  underline: const SizedBox.shrink(),
                  onChanged: (f) {
                    if (f != null) settings.setDateFormat(f);
                  },
                  items: [
                    for (final format in AppDateFormat.values)
                      DropdownMenuItem(
                        value: format,
                        child: Text(format.example),
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
                _PaletteRow(key: ValueKey(entry.key), entry: entry),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('Add color'),
                      onPressed: () => _PaletteEditDialog.show(context, null),
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
              const _SectionHeader('Data'),
              const _ExportSection(),
              const Divider(height: 32),
              const _SectionHeader('Help'),
              ListTile(
                leading: const Icon(Icons.keyboard_outlined),
                title: const Text('Keyboard shortcuts'),
                subtitle: const Text('Also opens with ? on the notes screen'),
                onTap: () => showShortcutHelp(context),
              ),
            ],
          ),
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

/// Summary row for the user's LLM endpoint; taps into the config dialog.
/// Unlike [_FeatureToggle] there is no server capability — availability is
/// purely whether the user has configured an endpoint and model.
class _LlmConfigTile extends StatelessWidget {
  const _LlmConfigTile();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final String summary;
    if (settings.llmConfigured) {
      final host = Uri.tryParse(settings.llmBaseUrl)?.host;
      summary =
          '${settings.llmModel} @ ${(host == null || host.isEmpty) ? settings.llmBaseUrl : host}';
    } else {
      summary =
          'Not configured — works with Ollama or any OpenAI-compatible API';
    }
    return ListTile(
      leading: const Icon(Icons.smart_toy_outlined),
      title: const Text('AI provider'),
      subtitle: Text(summary),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _LlmConfigDialog.show(context),
    );
  }
}

/// Endpoint / API key / model editor with a connection probe. Testing uses
/// the current field values (not the saved settings), so the config can be
/// validated before Save.
class _LlmConfigDialog extends StatefulWidget {
  const _LlmConfigDialog();

  static Future<void> show(BuildContext context) {
    final settings = context.read<SettingsStore>();
    return showDialog<void>(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: settings,
        child: const _LlmConfigDialog(),
      ),
    );
  }

  @override
  State<_LlmConfigDialog> createState() => _LlmConfigDialogState();
}

class _LlmConfigDialogState extends State<_LlmConfigDialog> {
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _model;
  bool _testing = false;
  ({bool ok, String? error})? _testResult;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsStore>();
    _url = TextEditingController(text: settings.llmBaseUrl);
    _key = TextEditingController(text: settings.llmApiKey);
    _model = TextEditingController(text: settings.llmModel);
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    ({bool ok, String? error}) result;
    try {
      result = await context.read<SettingsStore>().api.testLlm(
        baseUrl: _url.text.trim(),
        apiKey: _key.text.trim(),
        model: _model.text.trim(),
      );
    } on ApiException catch (e) {
      result = (ok: false, error: e.serverMessage);
    } catch (_) {
      result = (ok: false, error: 'could not reach the server');
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
  }

  void _save() {
    context.read<SettingsStore>().setLlmConfig(
      baseUrl: _url.text,
      apiKey: _key.text,
      model: _model.text,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final result = _testResult;
    return AlertDialog(
      title: const Text('AI provider'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'http://localhost:11434/v1',
                helperText:
                    'OpenAI-compatible endpoint, including /v1 '
                    '(Ollama, OpenAI, LM Studio, …)',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API key',
                helperText: 'Leave empty for Ollama',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _model,
              decoration: const InputDecoration(
                labelText: 'Model',
                hintText: 'gpt-5-mini, llama3.1, …',
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bolt_outlined, size: 18),
                  label: const Text('Test connection'),
                ),
                const SizedBox(width: 12),
                if (result != null)
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          result.ok ? Icons.check_circle : Icons.error_outline,
                          size: 18,
                          color: result.ok ? scheme.primary : scheme.error,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            result.ok
                                ? 'Connected'
                                : (result.error ?? 'failed'),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: result.ok
                                      ? scheme.onSurfaceVariant
                                      : scheme.error,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// Summary row for the user's notification channels; taps into the config
/// dialog. Like [_LlmConfigTile] there is no server capability — availability
/// is purely whether at least one channel from [kNotifyChannels] is
/// configured.
class _NotifyConfigTile extends StatelessWidget {
  const _NotifyConfigTile();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final channels = settings.configuredNotifyChannels;
    final summary = channels.isEmpty
        ? 'Not configured — get reminders via ${[for (final c in kNotifyChannels) c.label].join(' or ')}'
        : channels.join(' + ');
    return ListTile(
      leading: const Icon(Icons.send_to_mobile_outlined),
      title: const Text('Notification channels'),
      subtitle: Text(summary),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _NotifyConfigDialog.show(context),
    );
  }
}

/// Channel editor rendered entirely from [kNotifyChannels], with a delivery
/// probe. Testing uses the current field values (not the saved settings), so
/// the config can be validated before Save — the button literally sends a
/// test notification.
class _NotifyConfigDialog extends StatefulWidget {
  const _NotifyConfigDialog();

  static Future<void> show(BuildContext context) {
    final settings = context.read<SettingsStore>();
    return showDialog<void>(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: settings,
        child: const _NotifyConfigDialog(),
      ),
    );
  }

  @override
  State<_NotifyConfigDialog> createState() => _NotifyConfigDialogState();
}

class _NotifyConfigDialogState extends State<_NotifyConfigDialog> {
  late final Map<String, TextEditingController> _fields;
  bool _testing = false;
  ({bool ok, String? error})? _testResult;

  @override
  void initState() {
    super.initState();
    final values = context.read<SettingsStore>().notifyValues;
    _fields = {
      for (final key in kNotifyFieldKeys)
        key: TextEditingController(text: values[key] ?? ''),
    };
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Map<String, String> get _values => {
    for (final entry in _fields.entries) entry.key: entry.value.text.trim(),
  };

  bool get _anyConfigured =>
      kNotifyChannels.any((c) => c.configuredIn(_values));

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    ({bool ok, String? error}) result;
    try {
      result = await context.read<SettingsStore>().api.testNotify(_values);
    } on ApiException catch (e) {
      result = (ok: false, error: e.serverMessage);
    } catch (_) {
      result = (ok: false, error: 'could not reach the server');
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
  }

  void _save() {
    context.read<SettingsStore>().setNotifyValues(_values);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final result = _testResult;
    return AlertDialog(
      title: const Text('Notification channels'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Fields scroll; the probe row below stays pinned and visible.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final channel in kNotifyChannels) ...[
                      if (channel != kNotifyChannels.first)
                        const SizedBox(height: 20),
                      Text(
                        channel.label,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        channel.blurb,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      for (final field in channel.fields) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _fields[field.key],
                          obscureText: field.obscure,
                          // Re-evaluate the probe button's enabled state.
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            labelText: field.mandatory
                                ? field.label
                                : '${field.label} (optional)',
                            hintText: field.hint,
                            helperText: field.helper,
                            helperMaxLines: 2,
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _testing || !_anyConfigured ? null : _test,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(
                          Icons.notifications_active_outlined,
                          size: 18,
                        ),
                  label: const Text('Send test'),
                ),
                const SizedBox(width: 12),
                if (result != null)
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          result.ok ? Icons.check_circle : Icons.error_outline,
                          size: 18,
                          color: result.ok ? scheme.primary : scheme.error,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            result.ok
                                ? 'Sent — check your device'
                                : (result.error ?? 'failed'),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: result.ok
                                      ? scheme.onSurfaceVariant
                                      : scheme.error,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
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

/// A handful of pleasant seeds to pick from, the Keep amber ([kDefaultAccent])
/// first so the out-of-the-box state reads as selected. Any hex is reachable
/// through the custom picker.
const List<Color> kAccentPresets = [
  kDefaultAccent, // Amber (Keep)
  Color(0xFFFF7043), // Deep orange
  Color(0xFFEA4335), // Red
  Color(0xFFD81B60), // Pink
  Color(0xFF9334E6), // Purple
  Color(0xFF3F51B5), // Indigo
  Color(0xFF1A73E8), // Blue
  Color(0xFF00897B), // Teal
  Color(0xFF188038), // Green
  Color(0xFF5F6368), // Slate
];

/// Accent-color row: preset seeds plus a custom slot. The chosen seed reseeds
/// the whole Material scheme via [buildTheme] (see [SettingsStore.accentColor]),
/// so this recolors the app's chrome — FAB, checkboxes, selection, section
/// headers — while surfaces stay neutral.
class _AccentColorTile extends StatelessWidget {
  const _AccentColorTile();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final selected = settings.accentColor;
    final isPreset = kAccentPresets.any((c) => c == selected);
    return ListTile(
      leading: const Icon(Icons.palette_outlined),
      title: const Text('Accent color'),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final color in kAccentPresets)
              _AccentDot(
                color: color,
                selected: color == selected,
                onTap: () => settings.setAccentColor(color),
              ),
            _AccentDot(
              // A non-preset current value lives in the custom slot, selected.
              color: isPreset ? null : selected,
              custom: true,
              selected: !isPreset,
              onTap: () => _AccentCustomDialog.show(context, selected),
            ),
          ],
        ),
      ),
    );
  }
}

/// One tappable circle in the accent row. A [custom] dot with no [color] shows
/// a "+"; otherwise the fill is the seed, with a contrast-aware check when
/// selected.
class _AccentDot extends StatelessWidget {
  final Color? color;
  final bool selected;
  final bool custom;
  final VoidCallback onTap;

  const _AccentDot({
    required this.color,
    required this.onTap,
    this.selected = false,
    this.custom = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = color;
    final onFill =
        fill != null &&
            ThemeData.estimateBrightnessForColor(fill) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    final dot = InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: fill ?? scheme.surfaceContainerHighest,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.onSurface : scheme.outlineVariant,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: fill == null
            ? Icon(Icons.add, size: 18, color: scheme.onSurfaceVariant)
            : selected
            ? Icon(Icons.check, size: 18, color: onFill)
            : null,
      ),
    );
    // Tooltip asserts on a null message, so only wrap the custom slot (the one
    // dot whose purpose isn't obvious from its color).
    return custom ? Tooltip(message: 'Custom…', child: dot) : dot;
  }
}

/// Pick any accent by swatch or hex. A live chip previews the toned `primary`
/// the seed actually produces (Material mutes vivid seeds), so the choice is
/// WYSIWYG rather than a surprise.
class _AccentCustomDialog extends StatefulWidget {
  final Color initial;
  const _AccentCustomDialog({required this.initial});

  static Future<void> show(BuildContext context, Color initial) {
    final settings = context.read<SettingsStore>();
    return showDialog<void>(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: settings,
        child: _AccentCustomDialog(initial: initial),
      ),
    );
  }

  @override
  State<_AccentCustomDialog> createState() => _AccentCustomDialogState();
}

class _AccentCustomDialogState extends State<_AccentCustomDialog> {
  late Color _color = widget.initial;
  late final TextEditingController _hex = TextEditingController(
    text: PaletteEntry.colorToHex(widget.initial),
  );

  // A vivid board spanning the hue wheel — good starting points before hex.
  static const _board = [
    Color(0xFFFBBC04),
    Color(0xFFF9AB00),
    Color(0xFFFF7043),
    Color(0xFFEA4335),
    Color(0xFFD81B60),
    Color(0xFF9334E6),
    Color(0xFF7C4DFF),
    Color(0xFF3F51B5),
    Color(0xFF1A73E8),
    Color(0xFF039BE5),
    Color(0xFF00897B),
    Color(0xFF188038),
    Color(0xFF7CB342),
    Color(0xFF8D6E63),
    Color(0xFF5F6368),
  ];

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _select(Color c) {
    setState(() => _color = c);
    _hex.text = PaletteEntry.colorToHex(c);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final primary = ColorScheme.fromSeed(
      seedColor: _color,
      brightness: Theme.of(context).brightness,
    ).primary;
    return AlertDialog(
      title: const Text('Custom accent'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: primary,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.add,
                    size: 20,
                    color: scheme.brightness == Brightness.dark
                        ? Colors.black
                        : Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Preview of the accent this seed produces.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in _board)
                  InkWell(
                    onTap: () => _select(c),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c == _color
                              ? scheme.onSurface
                              : scheme.outlineVariant,
                          width: c == _color ? 2.5 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 130,
              child: TextField(
                controller: _hex,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  labelText: 'Hex',
                ),
                onChanged: (value) {
                  final parsed = PaletteEntry.hexToColor(value);
                  if (parsed != null) setState(() => _color = parsed);
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            context.read<SettingsStore>().setAccentColor(_color);
            Navigator.of(context).pop();
          },
          child: const Text('Use color'),
        ),
      ],
    );
  }
}

/// Bulk-export every note (excluding trash) to a downloaded file. Web only:
/// the download is a no-op on native builds, which the app never ships as.
class _ExportSection extends StatelessWidget {
  const _ExportSection();

  void _export(BuildContext context, ExportFormat format) {
    final store = context.read<NotesStore>();
    final notes = store.notesForExport;
    if (notes.isEmpty) {
      showAppSnack('No notes to export');
      return;
    }
    final content = exportNotes(notes, format, labels: store.labels);
    downloadTextFile(exportFilename(format), content, format.mime);
    final n = notes.length;
    showAppSnack('Exported $n ${n == 1 ? 'note' : 'notes'} as ${format.label}');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = context.watch<NotesStore>().notesForExport.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            'Download a copy of your $count '
            '${count == 1 ? 'note' : 'notes'} (archived included, trash '
            'excluded). JSON is a complete backup; Markdown and plain text '
            'are for reading and sharing.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final format in ExportFormat.values)
                OutlinedButton.icon(
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: Text(format.label),
                  onPressed: count == 0 ? null : () => _export(context, format),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final IconData icon;
  const _Swatch({required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Icon(icon, size: 14, color: Colors.black.withValues(alpha: 0.35)),
    );
  }
}

class _PaletteRow extends StatelessWidget {
  final PaletteEntry entry;
  const _PaletteRow({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsStore>();
    return ListTile(
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Swatch(color: entry.light, icon: Icons.light_mode_outlined),
          const SizedBox(width: 6),
          _Swatch(color: entry.dark, icon: Icons.dark_mode_outlined),
        ],
      ),
      title: Text(entry.name),
      onTap: () => _PaletteEditDialog.show(context, entry),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            tooltip: 'Edit color',
            onPressed: () => _PaletteEditDialog.show(context, entry),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: 'Remove color',
            onPressed: settings.palette.length <= 1
                ? null
                : () => settings.removePaletteColor(entry.key),
          ),
        ],
      ),
    );
  }
}

/// Create/edit one palette color: a name plus light and dark shades, picked
/// from swatches or typed as hex.
class _PaletteEditDialog extends StatefulWidget {
  final PaletteEntry? entry; // null = create
  const _PaletteEditDialog({this.entry});

  static Future<void> show(BuildContext context, PaletteEntry? entry) {
    final settings = context.read<SettingsStore>();
    return showDialog<void>(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: settings,
        child: _PaletteEditDialog(entry: entry),
      ),
    );
  }

  @override
  State<_PaletteEditDialog> createState() => _PaletteEditDialogState();
}

class _PaletteEditDialogState extends State<_PaletteEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.entry?.name ?? '',
  );
  late Color _light = widget.entry?.light ?? const Color(0xFFF28B82);
  late Color _dark = widget.entry?.dark ?? const Color(0xFF5C2B29);

  // A compact but broad swatch board (Material 200s for light, 900s for dark).
  static const _lightSwatches = [
    Color(0xFFF28B82),
    Color(0xFFFBBC04),
    Color(0xFFFFF475),
    Color(0xFFCCFF90),
    Color(0xFFA7FFEB),
    Color(0xFFAECBFA),
    Color(0xFFE8EAED),
    Color(0xFFFDCFE8),
    Color(0xFFD7AEFB),
    Color(0xFFE6C9A8),
    Color(0xFFB2EBF2),
    Color(0xFFFFCCBC),
  ];
  static const _darkSwatches = [
    Color(0xFF5C2B29),
    Color(0xFF614A19),
    Color(0xFF635D19),
    Color(0xFF345920),
    Color(0xFF16504B),
    Color(0xFF2D555E),
    Color(0xFF3C3F43),
    Color(0xFF5B2245),
    Color(0xFF42275E),
    Color(0xFF442F19),
    Color(0xFF1F4E5F),
    Color(0xFF6D3B2C),
  ];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final settings = context.read<SettingsStore>();
    final entry = widget.entry;
    if (entry == null) {
      settings.addPaletteColor(_name.text, _light, _dark);
    } else {
      settings.updatePaletteColor(
        entry.key,
        name: _name.text.trim().isEmpty ? entry.name : _name.text,
        light: _light,
        dark: _dark,
      );
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.entry == null ? 'Add color' : 'Edit color'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              _ShadeEditor(
                label: 'Light theme shade',
                color: _light,
                swatches: _lightSwatches,
                onChanged: (c) => setState(() => _light = c),
              ),
              const SizedBox(height: 16),
              _ShadeEditor(
                label: 'Dark theme shade',
                color: _dark,
                swatches: _darkSwatches,
                onChanged: (c) => setState(() => _dark = c),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _ShadeEditor extends StatefulWidget {
  final String label;
  final Color color;
  final List<Color> swatches;
  final ValueChanged<Color> onChanged;

  const _ShadeEditor({
    required this.label,
    required this.color,
    required this.swatches,
    required this.onChanged,
  });

  @override
  State<_ShadeEditor> createState() => _ShadeEditorState();
}

class _ShadeEditorState extends State<_ShadeEditor> {
  late final TextEditingController _hex = TextEditingController(
    text: PaletteEntry.colorToHex(widget.color),
  );

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _select(Color c) {
    _hex.text = PaletteEntry.colorToHex(c);
    widget.onChanged(c);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.outlineVariant),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 110,
              child: TextField(
                controller: _hex,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  labelText: 'Hex',
                ),
                onChanged: (value) {
                  final parsed = PaletteEntry.hexToColor(value);
                  if (parsed != null) widget.onChanged(parsed);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final swatch in widget.swatches)
              InkWell(
                onTap: () => _select(swatch),
                customBorder: const CircleBorder(),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: swatch,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: swatch == widget.color
                          ? scheme.primary
                          : scheme.outlineVariant,
                      width: swatch == widget.color ? 2 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
