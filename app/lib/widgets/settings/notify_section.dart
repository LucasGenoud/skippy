import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/notify_channels.dart';
import '../../state/settings_store.dart';
import 'probe_row.dart';

/// Summary row for the user's notification channels; taps into the config
/// dialog. Like the AI-provider tile there is no server capability —
/// availability is purely whether at least one channel from [kNotifyChannels]
/// is configured.
class NotifyConfigTile extends StatelessWidget {
  const NotifyConfigTile({super.key});

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
    final api = context.read<SettingsStore>().api;
    final result = await runSettingsProbe(() => api.testNotify(_values));
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
            ProbeRow(
              testing: _testing,
              result: _testResult,
              onTest: _anyConfigured ? _test : null,
              icon: Icons.notifications_active_outlined,
              label: 'Send test',
              successText: 'Sent — check your device',
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
