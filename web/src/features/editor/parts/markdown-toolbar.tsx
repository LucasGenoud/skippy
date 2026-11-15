"use client";

import { Bold, Code, Italic, Link, List, ListOrdered, Quote, Strikethrough, SquareCode } from "lucide-react";
import type { ReactNode } from "react";

import { IconButton } from "@/components/common/icon-button";
import { TooltipProvider } from "@/components/ui/tooltip";
import type { MarkdownAction } from "../lib/markdown-format";

// The formatting bar under a markdown body (`markdown_toolbar.dart`). Buttons
// keep focus in the body (pointer-down is cancelled), so the caret and
// selection the action applies to are still there.

const ACTIONS: readonly { action: MarkdownAction; label: string; icon: ReactNode }[] = [
  { action: "h1", label: "Heading 1", icon: <span className="text-[13px] font-bold">H1</span> },
  { action: "h2", label: "Heading 2", icon: <span className="text-[13px] font-bold">H2</span> },
  { action: "h3", label: "Heading 3", icon: <span className="text-[13px] font-bold">H3</span> },
  { action: "bold", label: "Bold", icon: <Bold /> },
  { action: "italic", label: "Italic", icon: <Italic /> },
  { action: "strike", label: "Strikethrough", icon: <Strikethrough /> },
  { action: "code", label: "Inline code", icon: <Code /> },
  { action: "codeBlock", label: "Code block", icon: <SquareCode /> },
  { action: "bullets", label: "Bulleted list", icon: <List /> },
  { action: "numbers", label: "Numbered list", icon: <ListOrdered /> },
  { action: "quote", label: "Quote", icon: <Quote /> },
  { action: "link", label: "Link", icon: <Link /> },
];

export function MarkdownToolbar({ onAction }: { onAction(action: MarkdownAction): void }) {
  return (
    <TooltipProvider>
      <div role="toolbar" aria-label="Formatting" className="flex h-11 items-center gap-0.5 overflow-x-auto border-t border-hairline px-3">
        {ACTIONS.map(({ action, label, icon }) => (
          <IconButton
            key={action}
            size="sm"
            label={label}
            icon={icon}
            side="top"
            onPointerDown={(e) => e.preventDefault()}
            onClick={() => onAction(action)}
          />
        ))}
      </div>
    </TooltipProvider>
  );
}
