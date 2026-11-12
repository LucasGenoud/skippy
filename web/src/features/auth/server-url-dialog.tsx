"use client";

import { useState, type FormEvent } from "react";
import { Server } from "lucide-react";
import { Reveal } from "@/components/common/reveal";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { errorMessage } from "@/lib/api/errors";
import { HttpApi } from "@/lib/api/http-api";
import { LoginField } from "./login-field";
import { ButtonSpinner } from "./auth-frame";
import { checkServerUrl } from "./server-url";
import { useOpeningKey } from "./use-opening-key";

// Adds a server, or edits a saved one when [initial] is given
// (`_ServerUrlDialog`). Before saving, the address is checked: it has to be an
// http(s) origin, and it is asked whether it answers. A server that does not
// answer can still be saved on purpose (it may only be down right now).

/** Probes a server's `/health`; rejects with the reason it is unreachable. */
export type ServerProbe = (url: string) => Promise<void>;

const probeServer: ServerProbe = (url) => new HttpApi({ baseUrl: url }).checkConnection();

type Check = { readonly state: "idle" } | { readonly state: "checking" } | { readonly state: "unreachable"; readonly url: string; readonly reason: string };

export function ServerUrlDialog({
  open,
  onOpenChange,
  initial,
  onSave,
  probe = probeServer,
}: {
  open: boolean;
  onOpenChange(open: boolean): void;
  /** The saved address being edited; absent to add one. */
  initial?: string;
  onSave(url: string): void;
  probe?: ServerProbe;
}) {
  const key = useOpeningKey(open);
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <ServerUrlForm
          key={key}
          initial={initial}
          probe={probe}
          onCancel={() => onOpenChange(false)}
          onSave={(url) => {
            onSave(url);
            onOpenChange(false);
          }}
        />
      </DialogContent>
    </Dialog>
  );
}

function ServerUrlForm({ initial, probe, onCancel, onSave }: { initial?: string; probe: ServerProbe; onCancel(): void; onSave(url: string): void }) {
  const editing = initial !== undefined;
  const [value, setValue] = useState(initial ?? "");
  const [error, setError] = useState<string | null>(null);
  const [check, setCheck] = useState<Check>({ state: "idle" });

  const submit = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    if (check.state === "checking") {
      return;
    }
    const parsed = checkServerUrl(value);
    if (!parsed.ok) {
      setError(parsed.error);
      return;
    }
    if (editing && parsed.url === initial) {
      onCancel();
      return;
    }
    // A second press on the same unreachable address saves it anyway.
    if (check.state === "unreachable" && check.url === parsed.url) {
      onSave(parsed.url);
      return;
    }
    setCheck({ state: "checking" });
    try {
      await probe(parsed.url);
      onSave(parsed.url);
    } catch (e) {
      setCheck({ state: "unreachable", url: parsed.url, reason: errorMessage(e, "It did not answer.") });
    }
  };

  const unreachable = check.state === "unreachable" ? check : null;
  return (
    <form onSubmit={submit} className="grid gap-4" noValidate>
      <DialogHeader>
        <DialogTitle>{editing ? "Edit server" : "Add server"}</DialogTitle>
        <DialogDescription>The address of a Skippy server, as you would open it in a browser.</DialogDescription>
      </DialogHeader>
      <div>
        <LoginField
          label="Server URL"
          icon={Server}
          type="url"
          inputMode="url"
          autoComplete="url"
          spellCheck={false}
          placeholder="https://notes.example.com"
          autoFocus
          value={value}
          error={error}
          onChange={(e) => {
            setValue(e.target.value);
            setError(null);
            setCheck({ state: "idle" });
          }}
        />
        <Reveal>
          {unreachable ? (
            <p role="status" className="pt-3 text-[13px] leading-5 text-on-surface-variant">
              <span className="font-medium text-on-surface">Couldn&apos;t reach that server.</span> {unreachable.reason}
            </p>
          ) : null}
        </Reveal>
      </div>
      <DialogFooter>
        <Button type="button" variant="ghost" onClick={onCancel}>
          Cancel
        </Button>
        <Button type="submit" disabled={check.state === "checking" || value.trim() === ""}>
          {check.state === "checking" ? <ButtonSpinner /> : null}
          {check.state === "checking" ? "Checking" : unreachable ? (editing ? "Save anyway" : "Add anyway") : editing ? "Save" : "Add"}
        </Button>
      </DialogFooter>
    </form>
  );
}
