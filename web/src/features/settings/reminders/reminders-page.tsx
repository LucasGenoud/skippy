"use client";

import { BellRing, Send } from "lucide-react";
import { NOTIFY_CHANNELS } from "@/lib/models";
import { configuredNotifyChannels, notifyConfigured, useSettings, useSettingsController } from "@/lib/store";
import { SettingsRow, SettingsSection, SwitchRow } from "../kit/rows";
import { useDialog } from "../kit/use-dialog";
import { NotifyDialog } from "./notify-dialog";
import { orList } from "./notify-form";

const joinLabels = (a: readonly string[], b: readonly string[]): boolean => a.length === b.length && a.every((x, i) => x === b[i]);

/**
 * Where reminders are delivered. The web schedules nothing on the device and
 * has no saved places (both phone-only), so push channels are the whole page.
 */
export function RemindersPage() {
  const settings = useSettingsController();
  const channels = useSettings(configuredNotifyChannels, joinLabels);
  const configured = useSettings(notifyConfigured);
  const enabled = useSettings((s) => s.reminderNotificationsEnabled);
  const dialog = useDialog();
  const summary = channels.length === 0 ? `Not configured, get reminders via ${orList(NOTIFY_CHANNELS.map((c) => c.label))}` : channels.join(" + ");

  return (
    <SettingsSection title="Push notifications">
      <SettingsRow icon={Send} title="Notification channels" subtitle={summary} onClick={() => dialog.show(true)} />
      <SwitchRow
        icon={BellRing}
        title="Reminder notifications"
        subtitle={configured ? "Send a push when a note's reminder comes due" : "Configure a channel first"}
        checked={configured && enabled}
        onCheckedChange={configured ? (v) => settings.setReminderNotificationsEnabled(v) : undefined}
      />
      <NotifyDialog key={dialog.key} open={dialog.open} onOpenChange={dialog.onOpenChange} />
    </SettingsSection>
  );
}
