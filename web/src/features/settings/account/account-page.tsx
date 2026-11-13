"use client";

import { IdCard, Mail, Lock, Trash2 } from "lucide-react";
import { useAuth } from "@/lib/store";
import { SettingsRow, SettingsSection } from "../kit/rows";
import { useDialog } from "../kit/use-dialog";
import type { AccountField } from "./account-errors";
import { DeleteAccountDialog } from "./delete-account-dialog";
import { EditAccountDialog } from "./edit-account-dialog";

export function AccountPage() {
  const user = useAuth((s) => s.user);
  const edit = useDialog<AccountField>();
  const del = useDialog();

  if (!user) {
    return null;
  }

  return (
    <>
      <SettingsSection>
        <SettingsRow icon={IdCard} title="Name" subtitle={user.name} onClick={() => edit.show("name")} />
        <SettingsRow icon={Mail} title="Email" subtitle={user.email} onClick={() => edit.show("email")} />
        <SettingsRow icon={Lock} title="Password" subtitle="Change your sign-in password" onClick={() => edit.show("password")} />
      </SettingsSection>
      <SettingsSection title="Danger zone">
        <SettingsRow icon={Trash2} tone="destructive" title="Delete account" subtitle="Permanently delete your notes and account" onClick={() => del.show(true)} />
      </SettingsSection>
      {edit.value ? <EditAccountDialog key={edit.key} field={edit.value} open={edit.open} onOpenChange={edit.onOpenChange} /> : null}
      <DeleteAccountDialog key={del.key} open={del.open} onOpenChange={del.onOpenChange} />
    </>
  );
}
