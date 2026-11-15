# Motion audit B: notes, editor, board, reminders

Scope: `features/notes`, `features/editor`, `features/board`,
`features/reminders`, against the Flutter sources they port
(`app/lib/widgets/{masonry,note_card,quick_add_bar,swipe_to_archive,...}`,
`note_card/*`, `checklist/*`, `editor/*`, `board/*`, `reminders/*`,
`screens/{editor_screen,history_screen}.dart`, the grid parts of
`home_screen.dart`, `util/motion.dart`).

Status is what the web client did before this pass:

- matches: same idiom, timing and curve (within the token set).
- missing: Flutter animates it, the web did nothing.
- snaps: the web shows the change in one frame.
- timing: animated, but with the wrong duration, curve or idiom.

Shared pieces added for this pass live in `features/notes/motion-kit.tsx`:
`useFollowHeight` (`AnimatedSize` for a box whose height is its content's,
on a spring that keeps its speed when retargeted), `StateCrossFade`
(overlapping block cross-fade), `FadingPattern` (a note pattern that
cross-fades) and `PresenceRow` (`AnimatedPresence` row that clips only while
it resizes).

## Grid (`masonry.dart`, `home_screen.dart`)

| Flutter | Web | Status | Change |
| --- | --- | --- | --- |
| `_SpringPositioned`: cards glide to new slots on `Motion.spring`, keeping velocity when retargeted | `Tile` animates x/y with `TRANSITION.spring` | matches | none |
| `_snapFrame`: width/column changes place cards outright | `snap` from geometry key, two frames | matches | constant `SNAP` transition so tiles stay memoized |
| `_TilePresence` arriving: fade + scale 0.95, BASE emphasized | `Tile` `arriving` | matches | none |
| `_TilePresence` leaving: reverse FAST standard, paints first | `LeavingTile` | matches | none |
| Staggered opening grid | `staggerIndex` 18ms, capped 200ms | matches | none |
| Grid height follows layout | `transition-[height] duration-240 ease-emphasized` | matches | none |
| `_DragFeedback`: lift 1.04, 0.84 opacity, shadow, label | `DragOverlay` + `motion.div` | matches | none |
| Ghost at 0.30 while dragged | `GHOST_OPACITY` | matches | none |
| Reorder settles after 50ms on a target | `REORDER_SETTLE_MS` | matches | none |
| Tile cache survives parent rebuilds (`itemBuildKey`) | every pack re-rendered every tile (new children, new slot objects, inline `guardClick`) | timing (perf) | cards cached per order, slot compared by value, stable `guardClick`: a re-pack only re-renders tiles that move |
| Pinned section comes and goes; grid below keeps its place | Pinned label faded, grid jumped by the section's height; "Others" label snapped | snaps | pinned section and "Others" label grow/fold with `PresenceRow` |
| View/collection/workspace switch: old grid fades as one layer (BASE in, FAST out) | keyed `motion.div` with `popLayout` | matches | none |
| Loading skeleton cross-fade | `loading` key | matches | none |
| Card height change (`AnimatedSize`, BASE emphasized) | card box jumped, neighbours glided | snaps | `useFollowHeight` on the card |
| `Motion.fadeInFrame` for pictures | `NoteImage` opacity on load | matches | none |
| Picture's box grows to its aspect once known | in-memory aspect cache only | snaps (after reload) | aspect ratios persisted (localStorage, capped 400) |
| A card that is deleted forever leaves with its last content | the leaving tile renders the note from the store, which is gone | missing | not changed (needs a note snapshot in the store; rare path) |

## Card (`note_card.dart`, `note_card/*`, `pin_icon.dart`)

| Flutter | Web | Status | Change |
| --- | --- | --- | --- |
| Hover shadow lift (`AnimatedContainer` FAST) | `shadow-card`/`shadow-raised` transition | matches | none |
| Hover actions row (`AnimatedSwitcher` FAST, keyed empty slot) | `AnimatePresence` fade | matches | none |
| Pin button fade (`AnimatedOpacity` FAST) | `motion.div` opacity | matches | none |
| `PinIcon` pop on flip | `PinIcon` | matches | none |
| Selection badge fade + check pop (easeOutBack) | `SelectionBadge` | matches | none |
| Footer labels fade under the hover row | `FooterLabels` | matches | none |
| Card checklist tick pop + text colour fade | `CardChecklistRow` | matches | none |
| Progress ring tween (BASE standard) | `ProgressRing` | matches | none |
| All-done burst on the card | `AllDoneBurst` | matches | none |
| Card colour change | background swapped in one frame | snaps | `background-color` joins the card's transition |
| Pattern change | pattern swapped in one frame | snaps | `FadingPattern` |
| AI-rewriting spinner | appeared and vanished | snaps | fades in and out |
| Link summary indicator | `AnimatePresence` fade | matches | none |
| Link preview title host -> page (`StateCrossFade`) | `CrossFade` | matches | none |
| Link preview thumbnail fade | image fades | matches | favicon now fades in too (was snap) |
| Transcribing indicator equaliser and shimmer | CSS keyframes, capped | matches | none |
| Pressed feedback on card controls | hover only | missing | `active:bg-pressed` on every hoverable control in the four features |

## Swipe to archive (`swipe_to_archive.dart`)

| Flutter | Web | Status | Change |
| --- | --- | --- | --- |
| Follows the finger, panel warms, icon scales | `SwipeToArchive` | matches | none |
| Commit: flies off BASE emphasized | tween from rest | timing | spring carrying the release velocity |
| Spring back: FAST standard | tween from rest | timing | critically damped spring from the release velocity (the momentum fix) |
| Card that stays in view slides back | second glide | matches | none |

## Quick add (`quick_add_bar.dart`)

| Flutter | Web | Status | Change |
| --- | --- | --- | --- |
| Bar unfurls into the composer (`AnimatedSize` BASE emphasized + cross-fade) | `motion.div layout`: a scale transform that squashed the content, while the grid below jumped | timing | the box's height follows its content (`useFollowHeight`), grid glides |
| Collapse | layout scale | timing | same follow, so the grid slides back up |
| Body text <-> checklist (`StateCrossFade`) | swap in one frame | snaps | `StateCrossFade` |
| Pending files (`AnimatedPresence` horizontal) | per-file scale/fade | matches | none |
| Meta chips (`AnimatedReveal`) | appeared at once | snaps | fade in and out; the box's height follows |
| Upload spinner in the bar (`StateCrossFade`) | pop swap | matches | none |
| Colour/pattern of the draft | snapped | snaps | background transition + `FadingPattern` |

## Editor (`editor_screen.dart`, `editor/*`, `note_zoom.dart`)

| Flutter | Web | Status | Change |
| --- | --- | --- | --- |
| `EditorMorph` open: card -> dialog, transform + clip, SLOW emphasized | `morphFrom` transform + clip-path | matches | none |
| Open: the whole surface is opaque at `t*4` (about 12% of the time) | only the face faded, over 25% | timing | the surface fades over the first 12% |
| Close: `standard.flipped` in reverse (eases into the card) | emphasized | timing | `EASE.standard` |
| Close: surface dissolves into the card over the second half | face faded over the last 25% | timing | surface opacity held to 37%, then fades |
| No source card: `FadeScaleTransition` | opacity + scale 0.96 | matches | scrim now fades with the panel's duration |
| Back button / route pop plays the same close | browser back unmounted the editor at once | missing | presence contract, below |
| Background colour change (`AnimatedContainer` BASE standard) | `transition-[background-color] duration-240` | matches | none |
| Pattern change | snapped | snaps | `FadingPattern` |
| Body kind change (`StateCrossFade`, overlapping) | `mode="wait"`: out, empty frame, in | timing | `StateCrossFade`; body field handle survives the overlap |
| Markdown source <-> preview (`StateCrossFade`) | `mode="wait"` | timing | same |
| Transcribing / failed / transcript (`AnimatedPresence`, each grows) | `popLayout` fade, no height | timing | `PresenceRow` per state |
| Link summary indicator (`AnimatedReveal`) | `Reveal` | matches | none |
| Attachments (`AnimatedPresence`) | `AttachmentTiles` presence | matches | none |
| Meta chips (`AnimatedPresence` horizontal) | `popLayout` chips | matches | none |
| Links section, link previews (`AnimatedReveal`) | `Reveal` | matches | none |
| Link picker, markdown toolbar (`AnimatedReveal`) | `Reveal` | matches | none |
| Upload progress (`AnimatedReveal`) | bar appeared and vanished | snaps | fades in and out |
| App bar find <-> actions (`_barCrossFade`, one slot) | actions vanished at once | snaps | actions fade out over the find field (`popLayout`) |
| Markdown mode button (`AnimatedSize` + `StateCrossFade`) | `CrossFade` | matches | none |
| Sync pill on phones | appeared and vanished | snaps | fades |
| Drop-files overlay | `AnimatePresence` fade | matches | none |
| Note zoom drag-to-dismiss with release velocity (phones) | not ported (web phones use the full-screen dialog) | missing | not changed |

## History (`history_screen.dart`)

| Flutter | Web | Status | Change |
| --- | --- | --- | --- |
| Page push | rose 12px and faded in, never left | timing | `pageVariants` (the shared page idiom), leaves the same way |
| Route pop plays the exit | unmounted at once | missing | presence contract, below |
| Loading / failed / list (`AnimatedSwitcher`) | `mode="wait"` fade | matches | none |
| Restore button -> spinner (`StateCrossFade`) | `CrossFade` | matches | none |
| Version cards arrive | all at once | snaps | `StaggeredEntrance` |

## Checklist (`checklist/*`)

| Flutter | Web | Status | Change |
| --- | --- | --- | --- |
| `PopCheckbox` pop on tick | `PopCheckbox` | matches | none |
| Ticked row held `Motion.slow` before filing away | `settling` timers | matches | none |
| Filed row glides into the checked section (`AnimatedPositioned`) | left the list (fold) and entered the section (slide) as two elements | timing | shared `layoutId` for a row crossing sections; the leaving copy goes at once |
| Unticked row glides back | same two-element swap | timing | same |
| Row into a collapsed section fades onto the header | folds | matches | none |
| New row: 20px slide + fade, BASE emphasized | `enter` variant | matches | none |
| Rows and composer glide on insert/remove | rows had `layout`; the composer jumped a row's height | snaps | composer is a `layout` element too |
| Checked section expand: rows appear in place | rows slid in from the side | timing | rows unfold (height + fade) |
| Chevron rotation | `rotate-90` FAST | matches | none |
| Composer "+" <-> checkbox in one slot (no travel) | `ComposerLeading` | matches | none |
| Indent padding (`AnimatedPadding` FAST) | `transition-[padding]` | matches | none |
| Row controls fade on hover/focus | `CONTROL_FADE` | matches | none |
| Subtask cascade: children file away with the task | cascade through `checklist-tree`; now glide with it | timing | covered by the shared `layoutId` |
| Drag reorder lands in place | `suppressLayout` frame | matches | layout sharing only for rows crossing sections, so a drop never replays as a glide |
| All-done burst | `AllDoneBurst` | matches | none |

## Board (`board/*`)

| Flutter | Web | Status | Change |
| --- | --- | --- | --- |
| Column collapse (`AnimatedContainer` width) | `motion.section` width + cross-fade | matches | none |
| Drop highlight | opacity rings | matches | none |
| Counts roll | `RollingCount` | matches | none |
| Cards enter/leave a column | `BoardCard` variants | matches | none |
| `_IncomingSlot`: an outline where the card will land | the card itself at 40% | timing | a primary outline over the placeholder |
| Column added or deleted | appeared/vanished, neighbours jumped | snaps | `PresenceColumn`: the slot opens/closes (width, its gap, fade) |
| Stage editor rows stagger in (`StaggeredEntrance`) | stagger in `stage-editor` | matches | none |
| Paged board page change | smooth `scrollTo` | matches | none |

## Reminders (`reminders/*`)

| Flutter | Web | Status | Change |
| --- | --- | --- | --- |
| Day groups and tiles fold (`AnimatedPresence`) | height + fade per tile/section | matches | none |
| Earlier section reveal + chevron (`AnimatedReveal`, `AnimatedRotation`) | `Reveal` + rotate | matches | none |
| Calendar month slide | directional `popLayout` slide | matches | none |
| Month title cross-fade | `CrossFade` | matches | none |
| Agenda / calendar / empty state (`AnimatedSwitcher`) | keyed fade | matches | none |
| Mark done: box fills, check scales in, then the row folds | `Checkbox` + `DURATION.base` wait | matches | none |
| Tile menu button fade on hover | `opacity` group-hover | matches | none |
| Editor grows out of the reminder row (`EditorMorph` source) | no source: loose fade | missing | rows carry `data-note-card`, so the editor morphs from and back into them |

## Counts

| Status | Count |
| --- | --- |
| matches | 64 |
| snaps | 16 |
| timing | 17 |
| missing | 6 |

Of the 39 gaps, 37 are fixed. Not changed: a card deleted forever has no
content to fade out with (the store no longer holds it), and the phone
note-zoom drag-to-dismiss is not part of the web client. Cards moved between
board columns from the menu still leave one column and arrive in the other
rather than travelling across: a shared layout there would fight dnd-kit's
drop animation.

## Desktop pass

The client is desktop-browser first; phones keep working.

- Right-click on a grid, list or board card opens the note's actions at the
  pointer (`NoteContextMenu`, the same rows as the "more" menu through one
  primitive kit). Its rows mount on the first right-click only. Off on touch,
  where a long press selects.
- Arrow keys move focus between cards by where they are drawn
  (`card-focus.ts`): right goes to the nearest column, down stays in the
  column. Works across the pinned and other sections and across board
  columns. Enter opens, Space selects (unchanged).
- A focused card answers P (pin), E (archive) and Delete/Backspace (trash,
  owner only); focus moves to a neighbour when the card leaves.
- Every hoverable control in these features has a pressed state.
- The page shows the grabbing cursor while a grid card is carried; mouse
  drags start after 4px, so a click still opens.

## Overlay presence (editor and history)

`useOverlayPresence()` (`components/common/overlay-presence.tsx`) tells an
overlay its route has left. The editor has one close path:

```text
Esc / close / outside      browser back (route already left)
         |                            |
         +------> playClose() <-------+   one morph, one shared promise
                      |
       route still here? -- yes --> onClose() navigates; the route leaving
                      |              then finds the morph done
                      no
                      v
               safeToRemove()  -> unmount -> finalize the draft once
```

- The morph runs once (`closingRun` holds its promise); a second request
  returns the same promise.
- `onClose()` is called only when the close started from inside and the
  route is still current, so browser back never navigates a second time.
- The draft is flushed by the existing unmount finalizer, which runs once.
- A close that starts mid-open keeps the transform; the opening no longer
  clears it on finish.
- While closing, the panel ignores the pointer.

History closes through one guarded `close()` (back, Escape, restore), which
only navigates; its exit plays when the route leaves (`pageVariants`
"leave") and then calls `safeToRemove()`. Under reduced motion it releases at
once.

`tests/note-editor.test.tsx` "NoteEditor closing" pins both paths: browser
back releases once without navigating; a double Escape navigates once and
releases once when the route then leaves.
