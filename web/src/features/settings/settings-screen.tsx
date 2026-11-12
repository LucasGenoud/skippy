"use client";

import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { ArrowLeft, ChevronRight } from "lucide-react";
import { IconButton } from "@/components/common/icon-button";
import { PageHeader } from "@/components/common/page-header";
import { closeTo, navigate, SETTINGS_PAGES, type SettingsPageId } from "@/lib/router";
import { useAuth } from "@/lib/store";
import { TRANSITION, transitionFor } from "@/lib/theme/motion";
import { cn } from "@/lib/utils";
import { AboutPage } from "./about/about-page";
import { AccountPage } from "./account/account-page";
import { AiPage } from "./ai/ai-page";
import { AppearancePage } from "./appearance/appearance-page";
import { DataPage } from "./data/data-page";
import { mediaMatches, SPLIT_QUERY, useMediaQuery } from "./kit/use-media-query";
import { PAGE_ICONS, pageTitle, usePageSummary } from "./pages";
import { RemindersPage } from "./reminders/reminders-page";
import { SharingPage } from "./sharing/sharing-page";

const PAGE_BODIES: Record<SettingsPageId, () => React.JSX.Element | null> = {
  account: AccountPage,
  appearance: AppearancePage,
  reminders: RemindersPage,
  ai: AiPage,
  sharing: SharingPage,
  data: DataPage,
  about: AboutPage,
};

/** What the screen shows for a route page at a width. */
export function settingsLayout(page: SettingsPageId | undefined, wide: boolean): { index: boolean; page: SettingsPageId | null } {
  if (wide) {
    return { index: true, page: page ?? "account" };
  }
  return page === undefined ? { index: true, page: null } : { index: false, page };
}

/**
 * The account's settings as an index of pages. A phone opens one page at a
 * time (`/settings/<page>` pushed over the index); a wide window keeps the
 * index beside the open page and swaps the page in place.
 *
 *   narrow                  wide
 *   +-------------+         +------------+------------------+
 *   | (Me)      > |         | Account    | Appearance       |
 *   | Appearance> |   -->   |#Appearance |  THEME           |
 *   | Reminders > |         | Reminders  |  Theme  [Auto]   |
 *   +-------------+         +------------+------------------+
 */
export function SettingsScreen({ page }: { page?: SettingsPageId }) {
  const wide = useMediaQuery(SPLIT_QUERY);
  const layout = settingsLayout(page, wide);
  const phonePage = !wide && layout.page !== null;

  function open(next: SettingsPageId) {
    // Beside the index a page swaps in place; on a phone it is a step deeper.
    navigate({ name: "settings", page: next }, { replace: mediaMatches(SPLIT_QUERY) });
  }

  function leave() {
    if (phonePage) {
      closeTo({ name: "settings", page: null });
      return;
    }
    closeTo({ name: "home" });
  }

  return (
    <div className="flex h-dvh flex-col bg-surface text-on-surface">
      <header className="flex h-14 shrink-0 items-center gap-2 border-b border-hairline px-2">
        <IconButton label="Back" icon={<ArrowLeft />} onClick={leave} />
        <h1 className="truncate text-base font-semibold">{phonePage && layout.page ? pageTitle(layout.page) : "Settings"}</h1>
      </header>
      <div className="flex min-h-0 flex-1">
        {layout.index ? (
          <nav aria-label="Settings pages" className={cn("overflow-y-auto", wide ? "w-[300px] shrink-0 border-r border-hairline px-3 py-2" : "flex-1 px-4 py-2")}>
            <div className={wide ? "" : "mx-auto max-w-[640px]"}>{wide ? <WideIndex selected={layout.page} onOpen={open} /> : <NarrowIndex onOpen={open} />}</div>
          </nav>
        ) : null}
        {layout.page ? (
          <main className="min-w-0 flex-1 overflow-y-auto">
            <PageView page={layout.page} titled={wide} />
          </main>
        ) : null}
      </div>
    </div>
  );
}

function PageView({ page, titled }: { page: SettingsPageId; titled: boolean }) {
  const reduced = useReducedMotion();
  const Body = PAGE_BODIES[page];
  return (
    <AnimatePresence mode="wait" initial={false}>
      <motion.div
        key={page}
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0 }}
        transition={transitionFor(TRANSITION.fast, reduced)}
        className={cn("max-w-[640px] px-4 pb-8", titled ? "pl-6" : "mx-auto")}
      >
        {titled ? <PageHeader title={pageTitle(page)} /> : null}
        <Body />
      </motion.div>
    </AnimatePresence>
  );
}

/** The phone index: who is signed in first, then every other page with its summary. */
function NarrowIndex({ onOpen }: { onOpen: (page: SettingsPageId) => void }) {
  const name = useAuth((s) => s.user?.name.trim() ?? "");
  return (
    <ul className="flex flex-col gap-0.5">
      <li className="border-b border-hairline pb-2">
        <IndexButton page="account" onOpen={onOpen} avatar={name ? Array.from(name)[0]?.toUpperCase() : undefined} title={name || "Account"} />
      </li>
      {SETTINGS_PAGES.filter((p) => p.id !== "account").map((p) => (
        <li key={p.id} className="first-of-type:pt-2">
          <IndexButton page={p.id} onOpen={onOpen} title={p.title} />
        </li>
      ))}
    </ul>
  );
}

function IndexButton({ page, onOpen, title, avatar }: { page: SettingsPageId; onOpen: (page: SettingsPageId) => void; title: string; avatar?: string }) {
  const summary = usePageSummary(page);
  const Icon = PAGE_ICONS[page];
  return (
    <button
      type="button"
      onClick={() => onOpen(page)}
      className="flex min-h-14 w-full items-center gap-4 rounded-md px-3 py-2.5 text-left transition-colors duration-150 ease-standard outline-none hover:bg-hover active:bg-pressed focus-visible:ring-[3px] focus-visible:ring-ring/50"
    >
      {avatar !== undefined || page === "account" ? (
        <span aria-hidden className="inline-flex size-9 shrink-0 items-center justify-center rounded-full bg-primary-container text-sm font-semibold text-on-primary-container">
          {avatar ?? <Icon className="size-5" />}
        </span>
      ) : (
        <Icon aria-hidden className="size-5 shrink-0 text-on-surface-variant" />
      )}
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="truncate text-sm text-on-surface">{title}</span>
        <span className="truncate text-xs text-on-surface-variant">{summary}</span>
      </span>
      <ChevronRight aria-hidden className="size-4 shrink-0 text-on-surface-variant" />
    </button>
  );
}

/** The wide index: names only, since the page itself is open beside it. */
function WideIndex({ selected, onOpen }: { selected: SettingsPageId | null; onOpen: (page: SettingsPageId) => void }) {
  return (
    <ul className="flex flex-col gap-0.5">
      {SETTINGS_PAGES.map((p) => {
        const Icon = PAGE_ICONS[p.id];
        const active = p.id === selected;
        return (
          <li key={p.id}>
            <button
              type="button"
              aria-current={active ? "page" : undefined}
              onClick={() => onOpen(p.id)}
              className={cn(
                "flex h-10 w-full items-center gap-3 rounded-md px-3 text-left text-sm transition-colors duration-150 ease-standard outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50",
                active ? "bg-secondary-container text-on-secondary-container" : "text-on-surface hover:bg-hover active:bg-pressed",
              )}
            >
              <Icon aria-hidden className={cn("size-[18px] shrink-0", active ? "text-on-secondary-container" : "text-on-surface-variant")} />
              {p.title}
            </button>
          </li>
        );
      })}
    </ul>
  );
}
