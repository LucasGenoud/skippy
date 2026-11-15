"use client";

import { useState } from "react";
import { Check, ChevronDown, CloudOff, Pencil, Plus, Server, X } from "lucide-react";
import { cn } from "cn";
import { IconButton } from "@/components/common/icon-button";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Separator } from "@/components/ui/separator";
import { displayUrl } from "./server-url";
import { ServerUrlDialog, type ServerProbe } from "./server-url-dialog";

// The server switcher under the form (`_BackendUrlSelector`): the active
// server as a quiet chip, and a list of saved ones to switch to, edit or
// remove. A list in a popover rather than a menu, so the edit and remove
// buttons on each row are reachable from the keyboard.

/** Whether the active server answered the login screen's capabilities probe. */
export type Reachability = "checking" | "reachable" | "unreachable";

export interface ServerPickerProps {
  activeUrl: string;
  savedUrls: readonly string[];
  /** The server this page would use with nothing saved. */
  defaultUrl: string;
  reachability: Reachability;
  disabled?: boolean;
  onSelect(url: string): void;
  onAdd(url: string): void;
  onEdit(oldUrl: string, newUrl: string): void;
  onRemove(url: string): void;
  probe?: ServerProbe;
}

type Editing = { readonly mode: "add" } | { readonly mode: "edit"; readonly url: string };

export function ServerPicker(props: ServerPickerProps) {
  const { activeUrl, savedUrls, defaultUrl, reachability, disabled = false } = props;
  const [open, setOpen] = useState(false);
  // What the dialog edits outlives its opening, so it keeps its title while closing.
  const [editing, setEditing] = useState<Editing>({ mode: "add" });
  const [dialogOpen, setDialogOpen] = useState(false);
  const unreachable = reachability === "unreachable";
  const canRemove = savedUrls.length > 1;

  const openDialog = (next: Editing): void => {
    setOpen(false);
    setEditing(next);
    setDialogOpen(true);
  };

  return (
    <>
      <Popover open={open} onOpenChange={setOpen}>
        <PopoverTrigger asChild>
          <Button
            variant="ghost"
            size="sm"
            disabled={disabled}
            className="max-w-full text-xs font-normal text-on-surface-variant"
            title={unreachable ? "Can't reach this server" : undefined}
          >
            {unreachable ? <CloudOff aria-hidden className="text-error" /> : <Server aria-hidden />}
            <span className="truncate">{displayUrl(activeUrl)}</span>
            {unreachable ? <span className="sr-only">(can&apos;t reach this server)</span> : null}
            <ChevronDown aria-hidden className="size-3.5" />
          </Button>
        </PopoverTrigger>
        <PopoverContent align="center" className="w-80 p-1">
          <ul aria-label="Saved servers" className="flex flex-col">
            {savedUrls.map((url) => {
              const active = url === activeUrl;
              return (
                <li key={url} className="group flex items-center gap-0.5 rounded-sm hover:bg-hover">
                  <button
                    type="button"
                    aria-current={active || undefined}
                    className="flex min-h-9 min-w-0 flex-1 items-center gap-2.5 rounded-sm px-2.5 text-left text-sm outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50"
                    onClick={() => {
                      setOpen(false);
                      props.onSelect(url);
                    }}
                  >
                    <Check aria-hidden className={cn("size-4 shrink-0 text-primary", !active && "invisible")} />
                    <span className={cn("truncate", active && "font-semibold")}>{displayUrl(url)}</span>
                    {url === defaultUrl ? <span className="shrink-0 text-xs text-on-surface-variant">Default</span> : null}
                  </button>
                  <IconButton size="sm" label="Edit" icon={<Pencil className="size-3.5" />} onClick={() => openDialog({ mode: "edit", url })} />
                  {canRemove && !active ? (
                    <IconButton size="sm" label="Remove" icon={<X className="size-3.5" />} onClick={() => props.onRemove(url)} />
                  ) : null}
                </li>
              );
            })}
          </ul>
          <Separator className="my-1" />
          {!savedUrls.includes(defaultUrl) && defaultUrl !== "" ? (
            <button
              type="button"
              className="flex min-h-9 w-full items-center gap-2.5 rounded-sm px-2.5 text-left text-sm outline-none hover:bg-hover focus-visible:ring-[3px] focus-visible:ring-ring/50"
              onClick={() => {
                setOpen(false);
                props.onAdd(defaultUrl);
              }}
            >
              <Server aria-hidden className="size-4 text-on-surface-variant" />
              <span className="truncate">Use {displayUrl(defaultUrl)}</span>
            </button>
          ) : null}
          <button
            type="button"
            className="flex min-h-9 w-full items-center gap-2.5 rounded-sm px-2.5 text-left text-sm text-primary outline-none hover:bg-hover focus-visible:ring-[3px] focus-visible:ring-ring/50"
            onClick={() => openDialog({ mode: "add" })}
          >
            <Plus aria-hidden className="size-4" />
            Add server…
          </button>
        </PopoverContent>
      </Popover>

      <ServerUrlDialog
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        initial={editing.mode === "edit" ? editing.url : undefined}
        probe={props.probe}
        onSave={(url) => {
          if (editing.mode === "edit") {
            props.onEdit(editing.url, url);
          } else {
            props.onAdd(url);
          }
        }}
      />
    </>
  );
}
