/// Reminder-notification channels (ntfy, Telegram, …), described as data so
/// the Settings UI, persistence and "configured" checks all render from one
/// list. Adding a channel here — with a matching `Connector` on the backend,
/// which reads the same keys out of the settings document — is all the app
/// needs: the config dialog grows its fields, the summary line and the
/// enabled checks pick it up automatically.
library;

/// One text field a channel needs. [key] is the settings-JSON key, shared
/// verbatim with the backend connector.
class NotifyField {
  final String key;
  final String label;
  final String? hint;
  final String? helper;

  /// Hide the value while typing (tokens).
  final bool obscure;

  /// Whether the channel counts as configured without it.
  final bool mandatory;

  const NotifyField({
    required this.key,
    required this.label,
    this.hint,
    this.helper,
    this.obscure = false,
    this.mandatory = true,
  });
}

class NotifyChannelSpec {
  /// Stable key, matching the backend connector's name.
  final String key;

  /// Display name ("ntfy", "Telegram").
  final String label;

  /// One-line setup pointer shown under the channel's header.
  final String blurb;
  final List<NotifyField> fields;

  const NotifyChannelSpec({
    required this.key,
    required this.label,
    required this.blurb,
    required this.fields,
  });

  /// Configured = every mandatory field has a value.
  bool configuredIn(Map<String, String> values) => fields
      .where((f) => f.mandatory)
      .every((f) => (values[f.key] ?? '').trim().isNotEmpty);
}

const List<NotifyChannelSpec> kNotifyChannels = [
  NotifyChannelSpec(
    key: 'ntfy',
    label: 'ntfy',
    blurb:
        'Subscribe to the same topic in the ntfy app (ntfy.sh or self-hosted).',
    fields: [
      NotifyField(
        key: 'ntfy_url',
        label: 'Topic URL',
        hint: 'https://ntfy.sh/your-secret-topic',
      ),
      NotifyField(
        key: 'ntfy_token',
        label: 'Access token',
        helper: 'Only needed for protected topics',
        obscure: true,
        mandatory: false,
      ),
    ],
  ),
  NotifyChannelSpec(
    key: 'telegram',
    label: 'Telegram',
    blurb:
        'Create a bot with @BotFather and send it /start so it can message you.',
    fields: [
      NotifyField(
        key: 'telegram_bot_token',
        label: 'Bot token',
        hint: '123456:ABC-DEF…',
        obscure: true,
      ),
      NotifyField(
        key: 'telegram_chat_id',
        label: 'Chat ID',
        helper: 'Your numeric id (ask @userinfobot) or a @channelname',
      ),
    ],
  ),
];

/// Every settings key any channel uses, in declaration order.
List<String> get kNotifyFieldKeys => [
  for (final channel in kNotifyChannels)
    for (final field in channel.fields) field.key,
];
