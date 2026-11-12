import { NOTIFY_CHANNELS, isChoiceField, type NotifyField } from "@/lib/models";

// The channel editor's values: every connector field from the registry, so a
// save never drops a channel-specific key, with choice fields resolved to what
// a blank value actually means.

/** Initial form values from the stored document. */
export function notifyFormValues(stored: Readonly<Record<string, string>>): Record<string, string> {
  const values: Record<string, string> = {};
  for (const channel of NOTIFY_CHANNELS) {
    for (const field of channel.fields) {
      values[field.key] = isChoiceField(field) ? resolvedChoice(field, stored[field.key]) : (stored[field.key] ?? "");
    }
  }
  return values;
}

/** A blank or unknown choice is the connector's default: the first option. */
export function resolvedChoice(field: NotifyField, stored: string | undefined): string {
  const options = field.options ?? [];
  const value = (stored ?? "").trim();
  return options.some((o) => o.value === value) ? value : (options[0]?.value ?? "");
}

/** What Save and Test send: every field, trimmed. */
export function trimmedValues(values: Readonly<Record<string, string>>): Record<string, string> {
  return Object.fromEntries(Object.entries(values).map(([key, value]) => [key, value.trim()]));
}

/** "a or b", "a, b, or c": the channel list reads as a sentence. */
export function orList(items: readonly string[]): string {
  if (items.length <= 1) {
    return items[0] ?? "";
  }
  if (items.length === 2) {
    return `${items[0]} or ${items[1]}`;
  }
  return `${items.slice(0, -1).join(", ")}, or ${items[items.length - 1]}`;
}
