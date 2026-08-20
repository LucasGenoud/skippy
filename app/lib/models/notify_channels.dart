/// Reminder-notification channels (ntfy, Telegram, …), described as data so
/// the Settings UI, persistence and "configured" checks all render from one
/// list. Adding a channel here, with a matching `Connector` on the backend,
/// which reads the same keys out of the settings document, is all the app
/// needs: the config dialog grows its fields, the summary line and the
/// enabled checks pick it up automatically.
library;

/// One fixed choice for a [NotifyField] rendered as a dropdown.
class NotifyChoice {
  /// Stored verbatim in the settings document and read by the connector.
  final String value;
  final String label;

  const NotifyChoice(this.value, this.label);
}

/// One field a channel needs. [key] is the settings-JSON key, shared verbatim
/// with the backend connector.
class NotifyField {
  final String key;
  final String label;
  final String? hint;
  final String? helper;

  /// Hide the value while typing (tokens).
  final bool obscure;

  /// Whether the channel counts as configured without it.
  final bool mandatory;

  /// Another field that satisfies this one when it is blank, mirroring a
  /// connector's own fallback (an empty SMTP sender means "the account you
  /// authenticate as"). Without it the UI would call a working configuration
  /// incomplete and refuse to send a test the server would have accepted.
  final String? filledBy;

  /// Fixed choices, rendered as a dropdown instead of a text field. The first
  /// one is what a blank value means, which is also what the connector
  /// assumes.
  final List<NotifyChoice> options;

  /// Digits only (a port).
  final bool numeric;

  const NotifyField({
    required this.key,
    required this.label,
    this.hint,
    this.helper,
    this.obscure = false,
    this.mandatory = true,
    this.filledBy,
    this.options = const [],
    this.numeric = false,
  });

  bool get isChoice => options.isNotEmpty;

  /// Whether [values] satisfies this field, following [filledBy].
  bool satisfiedBy(Map<String, String> values) {
    if (!mandatory) return true;
    if ((values[key] ?? '').trim().isNotEmpty) return true;
    final fallback = filledBy;
    return fallback != null && (values[fallback] ?? '').trim().isNotEmpty;
  }
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

  /// Configured = every mandatory field has a value, or something that
  /// stands in for it.
  bool configuredIn(Map<String, String> values) =>
      fields.every((field) => field.satisfiedBy(values));
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
  NotifyChannelSpec(
    key: 'email',
    label: 'Email',
    blurb:
        'Send reminders through an SMTP account. Your server may already '
        'provide one, in which case only the address below is yours to fill in.',
    fields: [
      NotifyField(
        key: 'smtp_host',
        label: 'SMTP server',
        hint: 'smtp.example.com',
      ),
      NotifyField(
        key: 'smtp_security',
        label: 'Security',
        mandatory: false,
        options: [
          NotifyChoice('tls', 'TLS (port 465)'),
          NotifyChoice('starttls', 'STARTTLS (port 587)'),
          NotifyChoice('none', 'None (port 25)'),
        ],
      ),
      NotifyField(
        key: 'smtp_port',
        label: 'Port',
        helper: 'Leave empty to use the standard port for the security above',
        mandatory: false,
        numeric: true,
      ),
      NotifyField(
        key: 'smtp_username',
        label: 'Username',
        helper: 'Usually the full email address',
        mandatory: false,
      ),
      NotifyField(
        key: 'smtp_password',
        label: 'Password',
        obscure: true,
        mandatory: false,
      ),
      NotifyField(
        key: 'smtp_from',
        label: 'From address',
        hint: 'skippy@example.com',
        helper: 'Defaults to the username',
        filledBy: 'smtp_username',
      ),
      NotifyField(
        key: 'smtp_to',
        label: 'Send to',
        hint: 'you@example.com',
        helper: 'Where your reminders arrive',
      ),
    ],
  ),
];

/// Every settings key any channel uses, in declaration order.
List<String> get kNotifyFieldKeys => [
  for (final channel in kNotifyChannels)
    for (final field in channel.fields) field.key,
];
