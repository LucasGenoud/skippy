// Reminder-notification channels described as data, so the settings UI,
// persistence and "configured" checks render from one list. Every `key` is a
// settings-document key shared verbatim with the backend connector. Ported
// from `models/notify_channels.dart`.

export interface NotifyChoice {
  /** Stored verbatim and read by the connector. */
  readonly value: string;
  readonly label: string;
}

export interface NotifyField {
  readonly key: string;
  readonly label: string;
  readonly hint?: string;
  readonly helper?: string;
  /** Hide the value while typing (tokens). */
  readonly obscure?: boolean;
  /** Whether the channel counts as configured without it. Default true. */
  readonly mandatory?: boolean;
  /** Another field that satisfies this one when it is blank. */
  readonly filledBy?: string;
  /** Fixed choices; the first is what a blank value means. */
  readonly options?: readonly NotifyChoice[];
  /** Digits only (a port). */
  readonly numeric?: boolean;
}

export interface NotifyChannelSpec {
  /** Stable key, matching the backend connector's name. */
  readonly key: string;
  readonly label: string;
  readonly blurb: string;
  readonly fields: readonly NotifyField[];
}

export const isChoiceField = (field: NotifyField): boolean => (field.options?.length ?? 0) > 0;

/** Whether [values] satisfies [field], following `filledBy`. */
export function fieldSatisfiedBy(field: NotifyField, values: Readonly<Record<string, string>>): boolean {
  if (field.mandatory === false) {
    return true;
  }
  if ((values[field.key] ?? "").trim() !== "") {
    return true;
  }
  const fallback = field.filledBy;
  return fallback !== undefined && (values[fallback] ?? "").trim() !== "";
}

export function channelConfiguredIn(channel: NotifyChannelSpec, values: Readonly<Record<string, string>>): boolean {
  return channel.fields.every((field) => fieldSatisfiedBy(field, values));
}

export const NOTIFY_CHANNELS: readonly NotifyChannelSpec[] = [
  {
    key: "ntfy",
    label: "ntfy",
    blurb: "Subscribe to the same topic in the ntfy app (ntfy.sh or self-hosted).",
    fields: [
      { key: "ntfy_url", label: "Topic URL", hint: "https://ntfy.sh/your-secret-topic" },
      {
        key: "ntfy_token",
        label: "Access token",
        helper: "Only needed for protected topics",
        obscure: true,
        mandatory: false,
      },
    ],
  },
  {
    key: "telegram",
    label: "Telegram",
    blurb: "Create a bot with @BotFather and send it /start so it can message you.",
    fields: [
      { key: "telegram_bot_token", label: "Bot token", hint: "123456:ABC-DEF…", obscure: true },
      {
        key: "telegram_chat_id",
        label: "Chat ID",
        helper: "Your numeric id (ask @userinfobot) or a @channelname",
      },
    ],
  },
  {
    key: "email",
    label: "Email",
    blurb:
      "Send reminders through an SMTP account. Your server may already provide one, in which case only the address below is yours to fill in.",
    fields: [
      { key: "smtp_host", label: "SMTP server", hint: "smtp.example.com" },
      {
        key: "smtp_security",
        label: "Security",
        mandatory: false,
        options: [
          { value: "tls", label: "TLS (port 465)" },
          { value: "starttls", label: "STARTTLS (port 587)" },
          { value: "none", label: "None (port 25)" },
        ],
      },
      {
        key: "smtp_port",
        label: "Port",
        helper: "Leave empty to use the standard port for the security above",
        mandatory: false,
        numeric: true,
      },
      { key: "smtp_username", label: "Username", helper: "Usually the full email address", mandatory: false },
      { key: "smtp_password", label: "Password", obscure: true, mandatory: false },
      {
        key: "smtp_from",
        label: "From address",
        hint: "skippy@example.com",
        helper: "Defaults to the username",
        filledBy: "smtp_username",
      },
      { key: "smtp_to", label: "Send to", hint: "you@example.com", helper: "Where your reminders arrive" },
    ],
  },
];

/** Every settings key any channel uses, in declaration order. */
export const NOTIFY_FIELD_KEYS: readonly string[] = NOTIFY_CHANNELS.flatMap((c) => c.fields.map((f) => f.key));
