"use client";

import { memo, useMemo } from "react";
import { Copy } from "lucide-react";
import { cn } from "cn";

import { IconButton } from "@/components/common/icon-button";
import { showAppSnack } from "@/components/common/snack";

import { highlightCode, type CodeTokenKind } from "./code-highlight";

const TOKEN_CLASS: Record<CodeTokenKind, string | undefined> = {
  plain: undefined,
  keyword: "font-semibold text-(--code-keyword)",
  string: "text-(--code-string)",
  number: "text-(--code-number)",
  comment: "italic text-(--code-comment)",
  type: "text-(--code-type)",
  call: "text-(--code-call)",
};

/**
 * A fenced block: highlighted, under its language label. In the editor it
 * scrolls sideways and offers copy; on a card it clips at its edge.
 */
export const CodeBlock = memo(function CodeBlock({ source, language, variant }: { source: string; language: string; variant: "card" | "editor" }) {
  const tokens = useMemo(() => highlightCode(source, language), [source, language]);
  const interactive = variant === "editor";
  const showHeader = language !== "" || interactive;

  const copy = async (): Promise<void> => {
    try {
      await navigator.clipboard.writeText(source);
      showAppSnack("Code copied", { icon: Copy });
    } catch {
      showAppSnack("Couldn't copy the code", { kind: "danger" });
    }
  };

  return (
    <div className="my-1 overflow-hidden rounded-md border border-hairline bg-code-fill">
      {showHeader ? (
        <div className={cn("flex items-center pl-3", interactive ? "pr-1" : "pt-2 pr-3 pb-0.5")}>
          <span className="flex-1 text-[10.5px] font-bold tracking-wider text-on-surface-variant uppercase">{language}</span>
          {interactive ? <IconButton label="Copy code" size="sm" icon={<Copy className="size-4" />} onClick={copy} /> : null}
        </div>
      ) : null}
      <pre
        className={cn(
          "px-3 pb-2.5 font-mono text-[0.9em] leading-normal text-on-surface",
          !showHeader && "pt-2.5",
          interactive ? "overflow-x-auto select-text" : "overflow-hidden",
        )}
      >
        <code>
          {tokens.map((token, i) => (
            <span key={i} className={TOKEN_CLASS[token.kind]}>
              {token.text}
            </span>
          ))}
        </code>
      </pre>
    </div>
  );
});
