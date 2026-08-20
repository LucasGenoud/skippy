import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/notify_channels.dart';
import '../../state/settings_store.dart';
import '../form_dialog.dart';
import 'probe_row.dart';

/// Summary row for the user's notification channels; taps into the config
/// dialog. Like the AI-provider tile there is no server capability,
/// availability is purely whether at least one channel from [kNotifyChannels]
/// is configured.
class NotifyConfigTile extends StatelessWidget {
  const NotifyConfigTile({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final channels = settings.configuredNotifyChannels;
    final summary = channels.isEmpty
        ? 'Not configured, get reminders via ${_orList([for (final c in kNotifyChannels) c.label])}'
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

/// "a or b", "a, b, or c": the channel list reads as a sentence however many
/// connectors the registry grows to.
String _orList(List<String> items) => switch (items.length) {
  0 => '',
  1 => items.first,
  2 => '${items.first} or ${items.last}',
  _ => '${items.sublist(0, items.length - 1).join(', ')}, or ${items.last}',
};

/// Channel editor rendered entirely from [kNotifyChannels], with a delivery
/// probe. Testing uses the current field values (not the saved settings), so
/// the config can be validated before Save, the button literally sends a
/// test notification.
class _NotifyConfigDialog extends StatefulWidget {
  const _NotifyConfigDialog();

  static Future<void> show(BuildContext context) {
    final settings = context.read<SettingsStore>();
    return showFormDialog<void>(
      context,
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

  /// Dropdown fields keep their value here rather than in a controller.
  final Map<String, String> _choices = {};
  bool _testing = false;
  ({bool ok, String? error})? _testResult;

  @override
  void initState() {
    super.initState();
    final values = context.read<SettingsStore>().notifyValues;
    _fields = {
      for (final channel in kNotifyChannels)
        for (final field in channel.fields)
          if (!field.isChoice)
            field.key: TextEditingController(text: values[field.key] ?? ''),
    };
    for (final channel in kNotifyChannels) {
      for (final field in channel.fields) {
        if (!field.isChoice) continue;
        final stored = (values[field.key] ?? '').trim();
        // A blank value means the connector's own default, which is the first
        // choice, so the dropdown says what will actually happen.
        _choices[field.key] = field.options.any((o) => o.value == stored)
            ? stored
            : field.options.first.value;
      }
    }
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
    ..._choices,
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

  /// One field, locked when the server pins it. A deployment can supply its
  /// own mail server, leaving the user only their address to fill in, so this
  /// mirrors the AI-provider dialog: disabled, with a lock and a line saying
  /// where the value came from.
  Widget _field(NotifyField field) {
    final managed = context.read<SettingsStore>().isManaged(field.key);
    final label = field.mandatory ? field.label : '${field.label} (optional)';
    final helper = managed ? 'Set by the server' : field.helper;
    final lock = managed ? const Icon(Icons.lock_outline, size: 18) : null;
    if (field.isChoice) {
      return DropdownButtonFormField<String>(
        key: ValueKey('notify-field-${field.key}'),
        initialValue: _choices[field.key],
        decoration: InputDecoration(
          labelText: field.label,
          helperText: helper,
          suffixIcon: lock,
        ),
        items: [
          for (final option in field.options)
            DropdownMenuItem(value: option.value, child: Text(option.label)),
        ],
        onChanged: managed
            ? null
            : (value) => setState(() {
                if (value != null) _choices[field.key] = value;
              }),
      );
    }
    return TextField(
      key: ValueKey('notify-field-${field.key}'),
      controller: _fields[field.key],
      enabled: !managed,
      // A managed secret is never sent to the client, so there is nothing to
      // obscure and nothing to show but a masked placeholder.
      obscureText: field.obscure && !managed,
      keyboardType: field.numeric ? TextInputType.number : null,
      // Re-evaluate the probe button's enabled state.
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: label,
        hintText: managed && field.obscure
            ? '•••••• (set by the server)'
            : field.hint,
        helperText: helper,
        helperMaxLines: 2,
        suffixIcon: lock,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FormDialog(
      title: const Text('Notification channels'),
      // The fields scroll inside the dialog, so it manages its own scrolling.
      scrollable: false,
      content: Column(
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
                      _field(field),
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
            successText: 'Sent, check your device',
          ),
        ],
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
