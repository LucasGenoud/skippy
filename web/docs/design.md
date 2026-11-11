# Skippy web design reference

The tokens, primitives and shared components every feature builds on. The
Flutter client (`app/lib/theme.dart` and the widgets named below) is the
specification; this is its web form.

## Design principles

The result must look polished and quiet, and stay simple.

- Build on the shadcn primitives in `components/ui` (Dialog, Popover,
  DropdownMenu, ContextMenu, Command, Tabs, Select, Switch, Checkbox,
  Calendar, Sheet, Drawer, Tooltip, Sonner). They are already restyled. Do
  not write a bespoke widget where a primitive fits.
- Restyle through tokens and variants, never one-off CSS. No hex colours, no
  inline shadows, no custom radii, no hand-picked durations in feature code.
- One radius: 6px (`rounded-md`) on every control, card, field, tag and
  dialog; 8px (`rounded-lg`) on menus and popovers only. No pills, no circle
  controls (avatars and radio buttons are the exceptions).
- Restrained colour. Surfaces are near-neutral; the accent appears sparingly:
  one filled primary button per surface, the checked checkbox, the selected
  row's wash, focus rings. Section headers are muted, not accented.
- Soft layered shadows (`shadow-card`, `shadow-raised`, `shadow-popover`,
  `shadow-dialog`), no heavy drop shadows, no ink ripples.
- Crisp, fast hover and press: a faint veil (`hover:bg-hover`,
  `active:bg-pressed`) at 150ms. Every interactive element shows a visible
  keyboard focus ring (`focus-visible:ring-[3px] focus-visible:ring-ring/50`,
  already built into the primitives).
- Nothing snaps. Every appearance, removal, reorder and size change animates,
  with the idiom that fits: fade/scale for overlays, height for collapses,
  layout springs for reorders, a pop for a check. Transforms and opacity only
  on anything that repeats per card.
- Generous spacing. Prefer the scales below over arbitrary values.

### Type scale

The UI font is `--font-app` (Inter by default); code is `font-mono`
(JetBrains Mono). Body text is 14/20.

| Use | Class | Size / line |
| --- | --- | --- |
| Section labels, chips, tags, counts, tooltips | `text-2xs` (+ `font-medium`, or the SectionLabel style) | 11 / 16 |
| Meta lines, descriptions, menu hints, card dates | `text-xs` | 12 / 16 |
| Dialog descriptions | `text-[13px] leading-5` | 13 / 20 |
| Body, controls, menu items, card text (default) | `text-sm` | 14 / 20 |
| Card and dialog titles, editor body | `text-base` (+ `font-semibold` for titles) | 16 / 24 |
| Editor title | `text-xl font-semibold` | 20 / 28 |
| Page titles (PageHeader) | `text-2xl font-semibold tracking-tight` | 24 / 32 |

Weights: 400 body, 500 labels and controls, 600 titles. 700 only in
SectionLabel.

### Spacing scale

Tailwind's 4px step. Use these and nothing in between:

| Token | px | Typical use |
| --- | --- | --- |
| `1` | 4 | icon-to-text in chips, tight stacks |
| `1.5` / `2` | 6 / 8 | gaps between chips, menu padding, card grid gap |
| `3` | 12 | gaps inside a card, between swatches |
| `4` | 16 | card padding, gaps between groups, page gutters |
| `5` | 20 | modal inset (dialogs and sheets use `p-5`) |
| `6` / `8` | 24 / 32 | section spacing, empty states |

Dialogs come in two widths: 360px (`sm:max-w-[360px]`, a confirmation or one
field; AlertDialog's default) and 420px (DialogContent's default).

## Colour tokens

Defined in `src/app/globals.css`, generated from `src/lib/theme/accent.ts`.
Every token is a Tailwind colour (`bg-*`, `text-*`, `border-*`, `ring-*`,
with `/NN` opacity) and a CSS variable (`var(--surface)`).

### The depth model

| Layer | Token / class | Use |
| --- | --- | --- |
| Canvas | `bg-canvas` (`--canvas`, also `bg-background`) | The page background, and nothing else. |
| Surface | `bg-surface` (`bg-card`, `bg-popover`, `bg-sidebar`) | Cards, top bar, docked sidebar, dialogs, menus, toasts. |
| Trough | `bg-trough`, edge `border-trough-border` | Board columns: a region cards are dropped into. |

The docked sidebar is always `bg-surface` (or `bg-sidebar`), never the canvas.
Chrome seams (top bar underline, sidebar edge, separators) use
`border-hairline` / `bg-hairline`.

Raised steps on a surface, for inset panels and inputs that need a fill:
`bg-surface-container-lowest`, `-low`, `bg-surface-container`, `-high`,
`-highest`, and `bg-surface-bright`.

### Text and lines

| Token | Use |
| --- | --- |
| `text-on-surface` (`text-foreground`) | Body text, titles. |
| `text-on-surface-variant` (`text-muted-foreground`) | Secondary text, icons at rest, meta. |
| `border-outline-variant` (`border-border`, `border-input`) | Control and card edges. |
| `border-outline` | A stronger edge (a field on hover). |
| `border-hairline` | Seams and separators. |

### The accent

| Token | Role |
| --- | --- |
| `bg-primary-container` + `text-on-primary-container` | The accent as a fill: primary button, checked checkbox and switch, selected calendar day, avatar, the all-done label. |
| `text-primary` (`ring-ring`) | The accent as text or an icon on a surface (readable tone): links, the selected swatch's check, a finished checklist ring, focus rings. Never a fill. |
| `bg-secondary-container` + `text-on-secondary-container` | The accent worn quietly: the selected sidebar row, an active chip or toggle, text selection. |
| `bg-excluded` | A filter that excludes (`-has:link`), the negative of the accent wash. |

### Status and utility

`bg-error` / `text-error` / `text-on-error`, `bg-error-container` +
`text-on-error-container` (error banners, the danger snack chip).
`bg-hover` / `bg-pressed` (state veils), `bg-code-fill` (code spans and
blocks), `var(--code-keyword|string|number|comment|type|call)` (syntax
colours), `bg-pattern-ink` (note patterns; use NotePattern), `bg-tooltip`.

### Runtime theme

```ts
import { applyTheme, themeColors, ACCENT_PRESETS, DEFAULT_ACCENT } from "@/lib/theme/accent";

applyTheme(settings.accent, settings.themeMode); // "light" | "dark" | "system"
```

`applyTheme` injects the variables for any accent (both brightnesses) and sets
the `dark` class on `<html>`; "system" follows the OS live. Call it from an
effect whenever the accent or mode changes. `themeColors(hex, brightness)`
returns the same colours as hex strings, for canvas drawing or previews;
`accentPreview(hex, brightness)` is the toned primary a custom accent
produces. `ACCENT_PRESETS` and `ACCENT_BOARD` are the Settings choices.

Dark mode in classes: `dark:` variants work, but tokens already switch, so
you should rarely need one.

### Note colours and labels

```ts
import { DEFAULT_PALETTE, noteColor, noteBackground } from "@/lib/theme/palette";
import { labelStyle, LabelIcon, labelIconFor, LABEL_ICONS } from "@/lib/theme/label-style";

noteColor("blue", "dark", settings.palette); // "#2D555E", or null for plain
<div style={{ background: noteBackground(note.color, brightness, palette) }} />
<span style={labelStyle(label.color)} />     // tinted chip colours
<LabelIcon iconKey={label.icon} className="size-4" />
```

`noteColor` falls back to the default palette for keys missing from the
user's palette, and to null (the surface) for "default" and unknown keys.

## Radius, shadow and motion utilities

| Utility | Value |
| --- | --- |
| `rounded-md` | 6px: everything (`--radius`) |
| `rounded-lg` | 8px: menus, popovers, select lists |
| `rounded-sm` | 4px: rows inside an 8px menu, tab triggers |
| `rounded-xs` | 3px: keycaps, slim bars |
| `rounded-check` | 3px: checkbox |
| `shadow-card` | A card at rest (contact + soft drop) |
| `shadow-raised` | A lifted card, dragged item, tooltip, toast |
| `shadow-popover` | Menus and popovers (with `border-outline-variant`) |
| `shadow-dialog` | Dialogs and sheets |
| `ease-emphasized` | Enter/exit, anything that grows or morphs |
| `ease-standard` | Hovers, fades, moves in place |
| `ease-back` | A check or swatch popping in |
| `duration-150` / `duration-240` / `duration-250` | FAST / BASE / SLOW |

Dark shadows are much denser automatically. Overlay primitives already
animate: in over 240ms emphasized, out over 150ms standard.

### Motion in code

```ts
import { DURATION, EASE, TRANSITION, OVERLAY, transitionFor } from "@/lib/theme/motion";
import { motion, useReducedMotion } from "motion/react";

const reduced = useReducedMotion();
<motion.div animate={{ opacity: 1 }} transition={transitionFor(TRANSITION.base, reduced)} />
<motion.div layout transition={TRANSITION.spring} />   // reorders, dragged cards
```

| Token | Value |
| --- | --- |
| `DURATION.fast` | 150ms: state flips, hover, toggles |
| `DURATION.base` | 240ms: reflows, morphs, overlays |
| `DURATION.slow` | 250ms: the ceiling, larger entrances |
| `DURATION.celebration` | 1100ms: the all-done burst only |
| `EASE.emphasized` | `[0.2, 0, 0, 1]` |
| `EASE.standard` | `[0.215, 0.61, 0.355, 1]` (ease-out cubic) |
| `EASE.back` | `[0.175, 0.885, 0.32, 1.275]` |
| `TRANSITION.fast/base/slow/pop/spring` | ready `motion` transitions |
| `OVERLAY.open/close` | base in, fast out |

Nothing runs longer than 250ms except the celebration. Never linear easing.
Under `prefers-reduced-motion`, globals.css collapses CSS animations and
`transitionFor(t, true)` returns an instant transition. Do not put a
translation in a swap animation of one slot (the two controls would cross):
use CrossFade.

## Fonts

```ts
import { APP_FONTS, loadFont } from "@/lib/theme/fonts";
await loadFont(settings.font); // "system" | "inter" | "nunito" | "lora" | "jetBrainsMono"
```

The ids are the Dart `AppFont` names. `loadFont` fetches the four weights,
then sets `--font-app` (so text reflows once). The CSS starts in Inter
before settings load; "system" is the platform UI font. Faces live in
`public/fonts/<Family>/` with their OFL licences.

## Primitives (`components/ui`)

Standard shadcn APIs, restyled. Notes:

- `Button`: `default` is the accent fill (use one per surface), `outline`
  and `ghost` for everything else, `secondary` the accent wash, `destructive`
  for irreversible actions. Icon sizes `icon-sm` (32), `icon` (36),
  `icon-lg` (40). Prefer `IconButton` for icon-only buttons.
- `DropdownMenu` / `ContextMenu`: items take an icon first, then text. Use
  `MenuLabel` (or `DropdownMenuItemDescription`) for the grey one-line hint.
  `DropdownMenuLabel` renders as small caps. Keep menus flat: never nest a
  "More" inside a "More"; split by intent across surfaces instead.
- `Tooltip` works without a provider; wrap a toolbar in `TooltipProvider` to
  share the skip delay. Delay is 600ms.
- `Dialog` (420px) and `AlertDialog` (360px) use the 20px modal inset.
- `Checkbox`: accent fill when checked. Checked task text stays struck through
  in `text-on-surface-variant`.
- `Switch`, `Slider`, `Progress`, `Tabs`: squared to the radius scale.
- `Toaster` (`ui/sonner.tsx`): mount once at the app root; show toasts with
  `showAppSnack`, not `toast` directly.
- `surface-styles.ts`: `floatingSurface`, `floatingMotion`, `menuItem`,
  `menuDescription`, `scrim`, for the rare custom floating element.

## Shared components (`components/common`)

All are presentational: they take props and never read a store.

### EmptyState

`{ icon: LucideIcon; message: string; actionLabel?: string; onAction?(): void; actionIcon?: LucideIcon; mark?: "icon" | "logo" }`

```tsx
<EmptyState icon={Archive} message="Archived notes appear here" />
```

### PageHeader and SectionLabel

`PageHeader { title?: string; subtitle?: string; trailing?: ReactNode }`, the
subtitle cross-fades on change. `SectionLabel { children; className? }`, small
caps in the muted colour.

```tsx
<PageHeader title="Reminders" subtitle="3 upcoming" trailing={<Button variant="outline" size="sm">Today</Button>} />
<SectionLabel>Pinned</SectionLabel>
```

### IconButton and Kbd

`IconButton { label: string; icon: ReactNode; shortcut?: string; size?: "sm" | "default" | "lg"; active?: boolean; side?; ...button props }`.
The label is the tooltip and the accessible name. `Kbd { children }`.

```tsx
<IconButton label="Search" shortcut="/" icon={<Search />} onClick={focusSearch} />
<span>Press <Kbd>⌘</Kbd><Kbd>K</Kbd></span>
```

### SyncPill

`{ state: "synced" | "syncing" | "connecting" | "offline" | "error"; count?: number }`,
count is the number of queued writes.

```tsx
<SyncPill state="syncing" count={2} />
```

### ColorPicker, PatternPicker, BackgroundPicker

```tsx
<ColorPicker value={note.color} onChange={setColor} brightness={brightness} palette={palette} />
<PatternPicker value={note.pattern} onChange={setPattern} fill={noteColor(note.color, brightness, palette)} />
<BackgroundPicker color={c} onColorChange={setC} pattern={p} onPatternChange={setP} brightness={b} palette={palette} />
```

Swatches are 40px squares (`Swatch`, `SwatchCheck` for custom rows).

### GlyphPicker

The colour + icon vocabulary of labels, smart views and collections.

`{ color: string | null; onColorChange(hex | null); icon: string | null; onIconChange(key | null); defaultIcon?: LucideIcon; customHex?: "shown" | "hidden" }`.
`GlyphColorRow` and `IconGrid` are exported for separate use.

```tsx
<GlyphPicker color={draft.color} onColorChange={...} icon={draft.icon} onIconChange={...} />
```

### NotePattern

`{ pattern: NotePatternId; className? }`. Place first inside a `relative`
card or editor; content after it paints on top. One element per card, one
memoized mask per pattern, inked in `--pattern-ink`.

```tsx
<article className="relative rounded-md shadow-card" style={{ background: noteBackground(...) }}>
  <NotePattern pattern={note.pattern} />
  <div className="relative p-4">...</div>
</article>
```

`NOTE_PATTERNS`, `notePatternFromWire` are in `lib/theme/patterns`.

### ReminderChip and ReminderPicker

`ReminderChip { at: Date; repeat?: ReminderRepeat | null; label?: string; now?: Date; onClick?(): void }`.
Calendar icon, struck through once past. Pass `label` to use the settings'
date format.

`ReminderPicker { value: { at: Date; repeat?: ReminderRepeat } | null; onChange(value | null); now?: Date; use24h?: boolean }`.
Presets apply at once; the custom view applies on Save; `null` removes. Place
it in a Popover (`w-[360px]`) or Dialog and close from `onChange`.

```tsx
<Popover open={open} onOpenChange={setOpen}>
  <PopoverTrigger asChild><Button variant="ghost" size="sm"><BellRing />Remind me</Button></PopoverTrigger>
  <PopoverContent className="w-[360px]">
    <ReminderPicker value={reminder} onChange={(v) => { setReminder(v); setOpen(false); }} />
  </PopoverContent>
</Popover>
```

`reminderPresets(now)`, `formatWhen`, `REPEAT_LABELS` come from
`common/reminder-format`.

### LabelChip, LabelMarker, LabelOverflowMarker

`LabelChip { name; color?: string | null; icon?: string | null }`, the
footer's compact `LabelMarker { name; color?; icon? }` and
`LabelOverflowMarker { count }`.

### ProgressRing and RollingCount

`ProgressRing { done: number; total: number }`, a 13px ring plus "3/5", in
the accent tone once complete. `RollingCount { count: number }`, an odometer.

### NotesSkeleton

`{ columns: number }`, the cold-load placeholder grid. For other placeholders
use `ui/skeleton`.

### AllDoneBurst

`{ onDone?(): void }`. Mount inside a `relative` box when a checklist is
finished; unmount on `onDone`; remount with a new key to replay.

### Reveal and CrossFade

`Reveal { children }`: grows and fades its child in and out (error lines,
probe results). `CrossFade { stateKey; children }`: swaps the content of one
slot without either side travelling.

### FormErrorBanner and AnimatedFormError

`FormErrorBanner { message }` (never empty), `AnimatedFormError { message: string | null }`
reveals it above a submit button.

### MenuLabel

`{ label: string; hint?: string; tone?: "default" | "destructive" }`.

```tsx
<DropdownMenuItem onSelect={duplicate}><Copy /><MenuLabel label="Duplicate" hint="Make a copy" /></DropdownMenuItem>
```

### AppLogo

`{ size?: number }` (default 28), from `/logo.svg`.

### showAppSnack

```ts
import { showAppSnack } from "@/components/common/snack";

showAppSnack("Note moved to trash", { undo: restore, icon: Trash2 });
showAppSnack("Could not reach the server", { kind: "danger", icon: CloudOff, action: { label: "Retry", onClick: retry } });
```

`{ action?: { label; onClick }; undo?(): void; icon?: LucideIcon; kind?: "normal" | "success" | "warning" | "danger" }`.
One toast at a time; 3s, or 5s with an action. Reserve for failures,
destructive changes with Undo, and significant background work.
