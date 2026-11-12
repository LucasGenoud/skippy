# Core API reference

What the CORE layer gives feature agents: stores and hooks, the router, the
ui (navigation) store, models, pure rules, and the `Api` methods features call
directly. Everything here is ported from the Flutter client in `app/lib`; when
in doubt the Dart behaviour is the specification.

Import paths:

| Path | What |
| --- | --- |
| `@/lib/store` | every hook, selector, store state type, settings helpers |
| `@/lib/store/hooks` | the same hooks (the barrel re-exports them) |
| `@/lib/models` | all domain types and wire parsers |
| `@/lib/router` | `useRoute`, `navigate`, `back`, `closeTo`, `SETTINGS_PAGES` |
| `@/lib/api/client` | the `Api` interface and its request/response types |
| `@/lib/api/errors` | `ApiError`, `NetworkError`, `AbortedError`, `errorMessage` |
| `@/lib/api/public-api` | `getPublicApi()` for signed-out pages |
| `@/lib/state/*` | pure rules (checklist tree, links, board, agenda, ...) |
| `@/lib/util/*` | pure helpers (search query, linkify, export, backup, ...) |

Every model is a plain readonly object. Dates are `Date`. Never mutate a
model; stores replace objects, and unchanged notes keep their identity across
refetches, which is what keeps cards from re-rendering.

## 1. How the stores fit together

```text
App (features/app)
  AuthProvider ─ AuthStore (global: session, saved servers)
  SessionManager ─ creates one Session per signed-in user
    SessionProvider ─ Session
      .notes     NotesStore      notes, workspaces, collections, labels,
                                 stages, smart views, sync queue
      .settings  SettingsStore   the per-user settings document
      .ui        UiController    navigation + transient UI state
      .linkPreviews              unfurl cache
      .api       Api             the HTTP client (for direct calls)
```

Two kinds of access:

- **Selector hooks** subscribe to the smallest slice and re-render only when
  it changes (`useNote(id)`, `useVisibleNoteIds()`, `useSettings(s => s.x)`).
  A selector's result is cached against the store state identity; pass an
  equality function when it returns a fresh array/object.
- **Controllers** (`useNotesController()`, `useSettingsController()`,
  `useUiController()`, `useAuthController()`, `useSession()`) are stable
  objects with the actions and imperative queries. Calling a query method
  (`notes.noteById(id)`) in an event handler is fine; in render, prefer a hook.

Rule of thumb for a card list: the list subscribes to ids
(`useVisibleNoteIds`), each card subscribes to its own note
(`useDisplayNote(id)`), and actions go through `useNotesController()`.

Session hooks throw outside `SessionProvider`, i.e. on signed-out pages
(login, reset, public share). Those use `useAuth*` and `getPublicApi()`.

## 2. Notes store (`NotesStore`)

`const notes = useNotesController();`

Every mutation below is **optimistic**: local state changes synchronously,
then a serializable operation goes on a persisted serial queue (IndexedDB,
per user and server). The queue runs one request at a time, creates before
updates, retries network failures every 5s (408 too; 401/425/429 wait 10s
without declaring offline), and drops permanent 4xx refusals as sync issues
(kept with the note's JSON so the user can copy, retry or dismiss). Methods
marked **awaited** call the server directly and reject with `ApiError` /
`NetworkError`; show `errorMessage(e)`.

### State (`NotesState`, via `useNotesSelector`)

| Field | Type | Meaning |
| --- | --- | --- |
| `notes` | `Record<string, Note>` | every note on this device, by id |
| `order` | `string[]` | ids in store order (position-sorted, drafts first) |
| `editingCards` | `Record<string, Note \| null>` | frozen cards while an editor is open |
| `labels`, `stages`, `workspaces` | arrays | all of them, every workspace |
| `checklistHistory` | `Record<noteId, string[]>` | suggestion source |
| `drafts` | `Record<id, true>` | local drafts not yet on the server |
| `rewriting` | `Record<id, true>` | AI rewrite running |
| `loading` | `boolean` | first load pending with nothing cached |
| `refreshing` | `boolean` | manual refresh running |
| `offline` | `boolean` | outage past the 5s grace |
| `syncStatus` | `"synced" \| "syncing" \| "connecting" \| "offline" \| "failed"` | the indicator |
| `pendingChanges` | `number` | queued writes + debounced edits |
| `hasPendingWork` | `boolean` | anything not acknowledged yet |
| `syncIssues` | `SyncIssue[]` | refused writes |
| `cacheFailure` | `string \| null` | IndexedDB write failed |
| `restoringBackup` | `boolean` | restore/import running |

### Queries (controller methods/getters, read the latest state)

| Member | Returns |
| --- | --- |
| `noteById(id)` | `Note \| null` |
| `displayNoteById(id)` | the card version (frozen while editing; null hides a new draft) |
| `allNotes()` | `Note[]` in store order |
| `labelById(id)`, `stageById(id)`, `workspaceById(id)` | entity or null |
| `workspaces`, `activeWorkspaceId`, `activeWorkspace`, `defaultWorkspace` | |
| `collections`, `activeCollection` | of the open workspace |
| `labelsInWorkspace(wsId = active)`, `stagesInWorkspace(wsId = active)` | sidebar order / left to right |
| `stages` | columns of the active collection |
| `stagesForNote(note)` | column choices for that note's collection |
| `savedViews`, `savedViewById(id)` | smart views of the open workspace |
| `notesInWorkspace(wsId)`, `notesInActiveWorkspace` | every view, trash included |
| `notesWithReminders` | across all workspaces |
| `ownedWorkspaces`, `notesForExport`, `notesForBackup`, `labelsForBackup`, `stagesForBackup` | export/backup inputs |
| `scopeFor(wsId)`, `workspaceScope`, `collectionScope` | `WorkspaceScope` for the pure filters |
| `canAutoDiscard(id)` | closing the editor may silently drop it |
| `isDraft(id)`, `isRewritingNote(id)`, `canTrash(id)`, `canDeleteWorkspace(id)` | |
| `aiIn(wsId)` | `WorkspaceAi` (none for a workspace the user is not in) |
| `linkTitleFor(id)` | live title for a `[[id\|..]]` link, or null |
| `backlinks(id)` | notes linking to it, newest first |
| `linkTargets(query, excludeId?)` | candidates while typing `[[query` |
| `suggestionsFor(noteId, query, exclude?)` | checklist suggestions from this note's history |
| `lastWorkspaceView(wsId)` | remembered `Destination` |
| `fileUrl(attachment)` | signed, absolute URL |
| `hasPendingWork`, `syncStatus`, `state` | |

### Lifecycle

| Method | |
| --- | --- |
| `load()` | hydrate the cache once, then fetch everything (independent reads in parallel); stale snapshots are rejected by generation and local write revision. The app calls it. |
| `refresh()` | manual re-pull (pull-to-refresh): flushes edits first |
| `retryNow()` | push the queue now (or reload when empty) |
| `checkConnectionNow()` | probe `/health`; recovery pushes and re-pulls |
| `onResumed()` | tab visible again (the app calls it) |
| `flushForBackground()` | tab hidden (the app calls it) |
| `retryCacheWrite()` | after a `cacheFailure` |
| `dismissSyncIssue(issue)`, `retrySyncIssue(issue)` | resolve a refused write |
| `startSync()`, `dispose()` | the app calls these |

### Editing notes

| Method | Optimistic | Notes |
| --- | --- | --- |
| `createDraft({ kind?, labelIds?, stageId? }) → Note` | local only | at the front of the active collection; reaches the server once it has content (or a reminder, file, or `finalizeNote(id, "keepEmpty")`) |
| `beginEditing(id, "existing" \| "new")`, `endEditing(id)` | | freeze the card while the editor is open; `"new"` hides a draft's card until closed |
| `updateNoteContent(id, { kind?, title?, content?, items?, pace? })` | yes | debounced 400ms patch; `pace: "typing"` throttles notifications to 200ms (use for keystrokes). Items are depth-normalized and item reminders of removed/checked rows pruned. |
| `finalizeNote(id, mode = "discardIfEmpty") → boolean` | yes | call when the editor closes; true when an empty note was discarded |
| `convertKind(id, kind)` | yes | text/markdown/checklist conversion |
| `toggleChecklistItem(noteId, itemId)`, `setChecklistItemDone(noteId, itemId, done)` | yes | cascades to subtasks; idempotent |
| `rememberCheckedText(noteId, text)` | local | |
| `togglePin(id)` | yes | pinning an archived note unarchives it |
| `setColor(id, key)`, `setPattern(id, pattern)`, `setGridSpan(id, 1..3)` | yes | |
| `setArchived(id, bool)` | yes | archiving unpins |
| `setReminder(id, at \| null, repeat?)` | yes | null clears (explicit nulls on the wire) |
| `setItemReminder(noteId, itemId, at \| null, repeat?)` | yes | own sub-resource; refused locally for a checked/missing row; no `updatedAt` bump |
| `moveToTrash(id)`, `restoreFromTrash(id, collectionId?)`, `deleteForever(id)`, `emptyTrash()` | yes | |
| `toggleLabelOnNote(noteId, labelId)`, `addLabelToNote(noteId, labelId) → boolean` | yes | |
| `reorder(orderedIds)` | yes | grid drag; renumbers like the server |
| `duplicate(id) → Note \| null` | yes | "Title (copy)" at the front |
| `removeCollaborator(noteId, userId)` | yes | removing yourself leaves the note |
| `addCollaborator(noteId, email)` | **awaited** | |
| `rewriteNote(id, task)` | **awaited** | flushes pending edits first; `rewriting[id]` while running |
| `noteVersions(id) → NoteVersion[]`, `restoreNoteVersion(id, versionId)` | **awaited** | flush pending edits first |
| `semanticSearch(query) → Note[]` | **awaited** | ranked, open workspace, no trash |

### Files and audio

| Method | |
| --- | --- |
| `uploadFile(noteId, blobOrBytes, mime, filename) → Attachment` | **awaited**; materializes a draft first |
| `createNoteWithFiles(files: DroppedFile[], labelIds?) → id \| null` | one note holding all files |
| `createTextNote(content, title?) → id \| null` | |
| `createAudioNote(blob, mime, { labelIds?, transcription?: "available" \| "unavailable" }) → id \| null` | shows transcribing at once when available |
| `retranscribe(id)` | optimistic, queued |
| `removeAttachment(noteId, attachmentId)` | optimistic, queued |
| `cancelLinkSummaries(id)` | awaited-ish; refreshes on failure |

Client upload cap: `MAX_UPLOAD_BYTES` (25 MB) in `@/lib/util/mime`;
`withinUploadLimit(files)` filters.

### Labels and stages (two independent systems; never share code)

| Method | |
| --- | --- |
| `createLabel(name, { color?, icon? }) → Label` | in the open workspace, appended |
| `updateLabel(id, { name?, color?, icon?, position? })` | color/icon are set exactly (null clears) |
| `moveLabel(id, newIndex)`, `deleteLabel(id)` | |
| `createStage(name, color?) → Stage` | in the active collection |
| `updateStage(id, { name?, color?, position? })`, `moveStage(id, newIndex)`, `deleteStage(id)` | delete keeps notes, unassigned |
| `setNoteStage(noteId, stageId \| null, position?)` | one patch with `stage_id` + `stage_position`; no position = end of column; a no-op drop queues nothing. Use `boardPositionForInsertion` / `boardPositionForReorder` from `@/lib/state/board-layout` for the position. |

`newIndex` is the resting index counted after removing the moved item (the
dnd-kit `arrayMove` target index).

### Workspaces, collections, smart views

| Method | |
| --- | --- |
| `setActiveWorkspace(id)` | switches and reopens its remembered destination |
| `selectCollection(id)` | in the active workspace |
| `rememberWorkspaceView(destination)` | the ui controller calls this for you |
| `createWorkspace(name) → Workspace` | optimistic, switches to it |
| `renameWorkspace(id, name)`, `updateWorkspaceViews(id, { notesEnabled, boardEnabled })`, `updateWorkspaceAi(id, AiSwitches)` | owner-only where the server says so |
| `deleteWorkspace(id)`, `leaveWorkspace(id)` | |
| `addWorkspaceMember(wsId, email)` | **awaited** |
| `removeWorkspaceMember(wsId, userId)` | yourself = leave |
| `duplicateWorkspace(id, name, "structure" \| "notes", { reminders? })` | **awaited**; refuses while offline; switches to the copy |
| `saveCollection(collection)` | create or update (layout, icon, color, sort are shared) |
| `moveCollection(id, newIndex)`, `deleteCollection(id)` | delete trashes its notes |
| `moveToCollection(noteId, collectionId)` | keeps labels, clears stage |
| `restoreToCollection(noteId, collectionId)` | also un-archives/un-trashes |
| `moveNoteToWorkspace(noteId, wsId)` | owner only; drops foreign labels and stage |
| `addSavedView({ name, query, icon?, color? }) → SavedView`, `updateSavedView(id, {...})`, `removeSavedView(id)`, `reorderSavedViews(oldIndex, newIndex)` | |

### Backup and import (**awaited**, refused while offline)

```ts
const bundle = await parseBackupArchive(bytes);           // @/lib/util/backup
await notes.restoreBackup(bundle, { workspaceIds?, onProgress?(done, total) });
const archive = await parseKeepArchive(bytes);            // @/lib/util/keep-import
await notes.importKeep(archive, { workspaceId, collectionId, trash?: "skip" | "include", onProgress? });
const zip = await createBackupArchive({ workspaces: notes.ownedWorkspaces, notes: notes.notesForBackup,
  labels: notes.labelsForBackup, stages: notes.stagesForBackup,
  readAttachment: async (a) => new Uint8Array(await (await fetch(notes.fileUrl(a))).arrayBuffer()) });
```

Failures throw `BackupFormatError` / `ImportFormatError` (parse) or
`BackupRestoreError` (`message`, `restoredNotes`). Filenames:
`backupFilename()`, `exportFilename(format)`.

## 3. Notes hooks

All from `@/lib/store`.

| Hook | Returns | Re-renders when |
| --- | --- | --- |
| `useNote(id)` | `Note \| null` | that note changes |
| `useDisplayNote(id)` | card version (`null` = hidden draft) | its card changes |
| `useVisibleNoteIds()` | `{ pinned: string[]; others: string[] }` | membership/order of the current view |
| `useBoard(showAllUnassigned?)` | `Board` (`columns: { stage, notes, totalCount }[]`) | the board's cards change |
| `useReminderOccurrences()` | `ReminderOccurrence[]` soonest first, workspace + search | |
| `useReminderNoteIds()` | ids of notes with reminders | |
| `useHasReminder(id)`, `useIsDraft(id)`, `useIsRewriting(id)` | `boolean` | |
| `useBacklinkIds(id)` | `string[]` | |
| `useNoteAvailability(id \| null)` | `NoteAvailability` (`canEdit`, `canArchive`, `canTrash`, `canCopy`, `canDuplicate`, `canShowHistory`, `canSetGridSpan`, `canMoveToCollection`, `canMoveToWorkspace`, `canMoveToStage`, `canRewrite`, `rewriteTasks`, `canSummarizeLinks`, `isOwner`) | |
| `useWorkspaces()`, `useWorkspace(id)`, `useActiveWorkspace()` | | |
| `useCollections()`, `useActiveCollection()` | | |
| `useLabels(wsId?)` (open workspace by default), `useLabel(id)` | | |
| `useStages()` (active collection), `useStagesForNote(id)` | | |
| `useSavedViews()` | | |
| `useAiIn(wsId)` | `WorkspaceAi` | |
| `useSyncStatus()`, `useSyncIssues()`, `useNotesLoading()` | | |
| `useWorkspaceStats(wsId)` | `WorkspaceStats` (see `@/lib/util/workspace-stats`) | any note change |
| `useNotesSelector(selector, isEqual?, deps?)` | anything | custom slice of `NotesState` |
| `useNav(selector(notes, ui), isEqual?, deps?)` | anything | custom slice over notes + ui |

`useVisibleNoteIds` already applies: destination (notes/label/smart view/
archive/trash/reminders), the active collection (or the whole workspace for
archive/trash/reminders), the effective query, the sort, and semantic ranking
when it is on. Grid views: archive/trash have no pinned section; reminders are
ordered soonest first.

Example card:

```tsx
function NoteCard({ id }: { id: string }) {
  const note = useDisplayNote(id);
  const notes = useNotesController();
  if (!note) return null;
  return <article onClick={() => navigate({ name: "note", noteId: id })}>
    <h3>{note.title}</h3>
    <button onClick={(e) => { e.stopPropagation(); notes.togglePin(id); }}>Pin</button>
  </article>;
}
```

Example board drop (dnd-kit `onDragEnd`):

```ts
const column = board.columns.find((c) => c.stage?.id === targetStageId);
const ordered = [...column.notes.filter((n) => n.id !== moved.id)];
ordered.splice(index, 0, moved);
const position = boardPositionForInsertion(moved, ordered);
notes.setNoteStage(moved.id, targetStageId ?? null, position);
```

## 4. Ui store (`UiController`) – navigation and transient UI

`const ui = useUiController();` `const q = useUi((s) => s.query);`

### State (`UiState`)

| Field | Meaning |
| --- | --- |
| `activeWorkspaceId` | the open workspace (the notes store owns reconciliation and persistence) |
| `collectionChoices` | workspace id to open collection id (use `useActiveCollection()`) |
| `lastWorkspaceViews` | workspace id to remembered destination |
| `destination` | `"notes" \| "archive" \| "trash" \| "reminders" \| { label: id } \| { smartView: id }` |
| `query`, `parsedQuery` | the search box as typed, and parsed (`SearchQuery`) |
| `layoutOverrides` | collection id to a device-local `"masonry" \| "list" \| "board"` |
| `sortOverrides` | collection id to a temporary `SortMode` |
| `selectedIds` | multi-selection; selection mode is `selectedIds.length > 0` |
| `searchFocusRequest` | counter; focus the search box when it increments |
| `semantic` | `{ ids: string[] \| null; busy: boolean; available: boolean }` |
| `sidebarOpen` | wide-screen sidebar |

`"notes"` renders a `BoardView` when the active collection's layout is
`board` (`useActiveLayout()`), otherwise the grid. The app root does this.

### Actions

| Method | |
| --- | --- |
| `selectDestination(d)` | user picked a sidebar entry: remembers it per workspace, clears the search and selection |
| `showDestination(d)` | show without those side effects |
| `setQuery(q)`, `clearQuery()` | also schedules semantic ranking when it is on |
| `requestSearchFocus()` | |
| `setLayoutOverride(collectionId, layout \| null)` | |
| `setSortOverride(collectionId, mode)`, `clearSortOverride(collectionId)` | the sort menu; saving to the collection is `notes.saveCollection({...c, sort})` |
| `setSelected(id, bool)`, `toggleSelected(id)`, `toggleSelectAll(ids)`, `clearSelection()` | |
| `setSidebarOpen(bool)`, `toggleSidebar()` | |
| `scheduleSemantic()` | re-rank now (called for you by `setQuery`) |

Toggle semantic ranking with `useSession().toggleSemanticRanking()` (flips
the setting and re-ranks).

### Navigation hooks

| Hook | Returns |
| --- | --- |
| `useViewSelection()` | `ViewSelection` (`{ view, labelId?, savedViewId? }`; `view` is `"board"` for a board collection) |
| `useActiveLayout()` | `"masonry" \| "list" \| "board"` (override, else shared) |
| `useActiveSort()` | `SortMode` |
| `useEffectiveQuery()` | the filtering query (smart view's query or `label:"Name"` plus the box) |
| `useHighlightQuery()` | free words to highlight in cards |
| `useSemanticActive()` | ranking shapes the view |
| `useComposeLabelIds()` | labels a note composed now should carry (the open label) |
| `useSelectedIds()`, `useIsSelected(id)` | |
| `useUi(selector, isEqual?)` | anything |

Selectors behind these are exported from `@/lib/store/selectors` (pure,
`(notesState, uiState) => ...`): `activeWorkspaceOf`, `activeCollectionOf`,
`activeLayoutOf`, `activeSortOf`, `viewSelectionOf`, `effectiveQueryOf`,
`highlightQueryOf`, `sectionsOf`, `boardOf`, `remindersOf`, `labelsOf`,
`stagesOfCollection`, `scopeOf`, `displayNotesOf`, `composeLabelIdsOf`.

## 5. Settings store (`SettingsStore`)

`const settings = useSettingsController();` `const dark = useSettings((s) => s.themeMode);`

Mutations are optimistic: state changes now, the whole document is PUT 600ms
later, retried with backoff (5s doubling to 60s) until it lands. A load never
clobbers an unsaved edit. Managed (server-pinned) keys are overlaid for
display, secrets blank, and never written back over the user's own value.

### State (`SettingsState`)

`loaded`, `themeMode` (`"system" | "light" | "dark"`), `accentColor` (`#RRGGBB`),
`font` (`APP_FONTS` ids), `dateFormat` (`DATE_FORMATS` ids), `use24hTime`,
`defaultListMode`, `gridDensity` (`GRID_DENSITIES`: `targetWidth`,
`maxColumns`), `gridWidth` (`GRID_WIDTHS`: `maxWidth`), `boardExitColumns`,
`palette: PaletteEntry[]` (`key, name, light, dark` hex), capabilities
(`semanticSearchCapable`, `audioTranscriptionCapable`, `imageOcrCapable`,
`passwordResetCapable`, `serverVersion`), `semanticSearchEnabled`,
`semanticRanking`, LLM (`llmBaseUrl`, `llmApiKey`, `llmModel`, `llmPrompt`,
`autoSummarizeLinks`, `linkSummaryLength`, `llmRewriteTasks`,
`llmChatCreateEnabled`, `llmChatEditEnabled`, `llmChatOrganizeEnabled`),
`managed: Record<key, ManagedSetting>`, `notifyValues: Record<key, string>`,
`reminderNotificationsEnabled`, `deviceNotificationsEnabled`,
`savedLocations`, `locationReminders` (native-only, passed through).

### Derived helpers (pure, take the state)

`semanticSearchAvailable(s)`, `llmConfigured(s)`, `isManaged(s, key)`,
`notifyConfigured(s)`, `configuredNotifyChannels(s)`, `boardExitsFor(s,
collectionId)`, `resolveNoteColor(s, key, "light" | "dark")` (null = plain
surface), `formatClock(t, use24h)`, `formatDate(t, format, withYear?)`,
`reminderLabel(t, s)`, `editedLabel(t, s)`.

### Actions

`load()`, `setThemeMode`, `cycleThemeMode`, `setAccentColor(hex)`, `setFont`,
`setDateFormat`, `setUse24hTime`, `setDefaultListMode`, `setGridDensity`,
`setGridWidth`, `setBoardExitColumn(collectionId, "archive" | "trash", visible)`,
`setSemanticSearchEnabled`, `setSemanticRanking`, `setLlmConfig({ baseUrl,
apiKey, model })`, `setLinkSummarySettings({ automatically, length })`,
`setLlmRewriteTasks(tasks)`, `setLlmBehavior({ prompt, create, edit, organize })`,
`setNotifyValues(values)`, `setReminderNotificationsEnabled`,
`setDeviceNotificationsEnabled`, `addPaletteColor(name, light, dark)`,
`updatePaletteColor(key, { name?, light?, dark? })`, `removePaletteColor(key)`,
`resetPalette()`, `toJson()`, `documentBytes()` (compare with
`SETTINGS_DOCUMENT_MAX_BYTES`, 16 KB), `hasPendingSave`.

Notification connectors: `NOTIFY_CHANNELS` / `NOTIFY_FIELD_KEYS` /
`channelConfiguredIn` / `fieldSatisfiedBy` in `@/lib/models`. Probes:
`api.testNotify(values)`, `api.testLlm({ baseUrl, apiKey, model })`.

## 6. Auth store (`AuthStore`)

Global (works signed out). `const auth = useAuthController();`
`const status = useAuth((s) => s.status);`

State: `status` (`"restoring" | "signedOut" | "signedIn"`), `user`, `busy`,
`error` (words for the form), `errorStatus` (401 both fields, 409 email taken),
`restoredSession`, `accountOrigin`, `savedUrls`, `activeUrl`, `prefillEmail`.

| Method | |
| --- | --- |
| `signIn(email, password) → Promise<boolean>` | sets `error` on failure |
| `registerAccount(name, email, password) → Promise<boolean>` | the new account gets starter notes |
| `signOut()` | local first, server told best effort |
| `clearError()` | |
| `requestPasswordReset(email)` | resolves whether or not the account exists; rejects with ApiError/NetworkError |
| `resetPassword(token, password) → email` | on the signed-in api; signed-out pages use `getPublicApi().resetPassword` |
| `setPrefillEmail(email \| null)` | the reset page sets it before navigating to `/` |
| `updateAccount({ name?, email?, currentPassword?, newPassword? })` | awaited, rejects with ApiError |
| `deleteAccount(currentPassword, beforeSignOut?)` | awaited; clears the offline cache |
| `addUrl(url)`, `setActiveUrl(url)`, `editUrl(old, new)`, `removeUrl(url)` | server picker; switching signs out |
| `defaultUrl()` | injected `window.stickyNotesApiBase`, else this page's origin |

Capabilities before sign-in (to offer "Forgot password?"):
`auth.api.fetchCapabilities()`.

API base resolution (from the Flutter client): the server saved at login,
else `window.stickyNotesApiBase`, else the page's origin. Signed-out pages
(public share, reset) use `getPublicApi()`, pinned to the page's origin.

## 7. Router (`@/lib/router`)

```ts
type Route =
  | { name: "home" }
  | { name: "note"; noteId: string }
  | { name: "history"; noteId: string }
  | { name: "settings"; page: SettingsPageId | null }
  | { name: "workspaceSettings"; workspaceId: string }
  | { name: "workspaceStats"; workspaceId: string }
  | { name: "chat" }
  | { name: "publicShare"; token: string }    // hex only
  | { name: "resetPassword"; token: string }; // hex only
```

- `useRoute(): Route`
- `navigate(pathOrRoute, { replace? })`: `navigate({ name: "note", noteId })`
  or `navigate("/settings/ai")`. A deployment sub-path is kept.
- `back()`: history back.
- `closeTo(route = home)`: close an overlay; goes back when the app pushed the
  current entry, otherwise replaces with [route] (a note opened from a link).
  `NoteEditor` and `HistoryScreen` get an `onClose` that already does this.
- `routePath(route)`, `parseRoute(path)`, `getRoute()`.
- `SETTINGS_PAGES`: `account, appearance, reminders, ai ("AI & search"),
  sharing ("Sharing & access"), data ("Backup & import"), about`, each with a
  `title`. `SettingsPageId` is the id union.

Opening a note pushes `/n/<id>`, so the browser back button closes it. A new
note: `const draft = notes.createDraft({ kind, labelIds: composeLabelIds });
notes.beginEditing(draft.id, "new"); navigate({ name: "note", noteId: draft.id })`.
On close the editor calls `notes.finalizeNote(id)` then `notes.endEditing(id)`.
A `/n/<id>` for a note this device does not have (a reload on an unsaved
draft) should close itself.

## 8. The `Api` surface features call directly

`const api = useApi();` (signed in) or `getPublicApi()` (signed out). All
methods reject with `ApiError` (`statusCode`, `serverMessage`,
`statusSummary`), `NetworkError` (`message` is the plain-language reason), or
`AbortedError`. Show `errorMessage(error)`.

| Area | Methods |
| --- | --- |
| Search | `semanticSearch(q, { limit?, workspaceId? }) → ids` (503 when disabled), `fetchSearchStats()`, `reindexEmbeddings() → count`, `fetchReindexStatus() → { running, done, total }` |
| Links | `unfurl(url) → LinkPreview \| null` (prefer `useLinkPreviews().preview(url)` / `.peek(url)`), `summarizeUrl(url, { noteId, length?, signal? }) → string` |
| Chat | `chat(message, history, { workspaceId? }) → ChatStream` (async iterable of `ChatEvent`; `cancel()`; ends after `done`/`error`; unknown frames are skipped). Events: `sources { notes }`, `created { action, note, undo }`, `delta { text }`, `done`, `error { message }` |
| Versions | prefer `notes.noteVersions(id)` / `notes.restoreNoteVersion(id, vid)` |
| Share links | `fetchShareLinks()`, `createShareLink({ target, noteId?, workspaceId?, collectionId?, labelId?, expiresAt? })`, `deleteShareLink(token)`; URL with `publicShareUrl(api.baseUrl, link)` |
| Public page | `getPublicApi().fetchPublicShare(token) → PublicShare` |
| Tokens (MCP) | `fetchApiTokens()`, `createApiToken(name, "read" \| "write") → { token, secret }`, `deleteApiToken(id)`; `mcpUrl(baseUrl)`, `claudeCodeCommand(baseUrl, secret)` |
| Probes | `testLlm({ baseUrl, apiKey, model })`, `testNotify(values) → { ok, error }` |
| Capabilities | `fetchCapabilities()` (also mirrored in the settings state), `fetchManagedSettings()` |
| Checklist history | `fetchChecklistHistory()` (the store already holds it) |
| Files | `attachmentUrl(attachment)` (or `notes.fileUrl`) |

Wire-level PATCH (`api.patchNote(id, fields)`) exists but features should use
the store's optimistic methods.

## 9. Models (`@/lib/models`)

- `Note` (fields as in Dart, camelCase; `labelIds` is an array used as a set;
  `itemReminders: Record<itemId, ItemReminder>`; `stageId`/`collectionId`/
  `reminderAt`/`reminderRepeat`/`owner` are `null` when absent).
  Helpers: `isNoteEmpty`, `hasReminder`, `nextReminderAt`,
  `orderedItemReminders`, `isNoteOwnedBy`, `noteCanAutoDiscard`,
  `isNoteShared`, `audioClip`, `isTranscribing`, `transcriptFailed`,
  `isChecklist`, `isAudioNote`, `makeNote` (defaults like the Dart
  constructor).
- `NoteKind` (`"text" | "checklist" | "markdown" | "audio"`), `NotePattern`
  (`NOTE_PATTERNS` with labels), `ReminderRepeat` (`REMINDER_REPEATS`),
  `ChecklistItem { id, text, done, depth }` (`MAX_ITEM_DEPTH` = 2),
  `ItemReminder { itemId, at, repeat }`, `Attachment` (`isImageAttachment`,
  `isAudioAttachment`; `ocrText`), `UserRef`, `NoteVersion`, `Label`, `Stage`,
  `AuthUser`, `NoteRewriteTask` (`DEFAULT_REWRITE_TASKS`).
- `Workspace { id, name, collections, savedViews, notesEnabled, boardEnabled,
  owner, members, isDefault, ai }`, `isWorkspaceOwnedBy`, `isWorkspaceShared`;
  `NoteCollection { id, workspaceId, name, icon, color, layout, sort,
  position }` (`COLLECTION_LAYOUTS`, `COLLECTION_SORTS`,
  `generalCollectionId`); `SavedView { id, name, query, icon, color,
  position }`; `AiSwitches` (`DEFAULT_AI_SWITCHES`, `switchesAllow`),
  `WorkspaceAi { switches, providerReady, rewriteTasks }` (`aiAllows(ai,
  "labeling" | "chat" | "writing")`).
- `ChatMessage`, `ChatEvent`, `ChatSource`, `LinkPreview` (`previewHost`,
  `previewHasRichContent`), `SearchStats`, `ShareLink` / `ShareTarget`
  (`SHARE_TARGETS`, `shareTargetNoun`), `PublicShare`, `ApiToken`,
  `TokenScope` (`TOKEN_SCOPES`), `ManagedSetting`, `Capabilities`,
  `DroppedFile { name, mime, bytes }`, `UrlSummaryLength`.
- `Destination` (from `@/lib/store`), `SyncIssue` (`@/lib/state/sync-issue`:
  `isConflictIssue`, `syncIssueLabel`, `syncIssueCopyText`).

## 10. Pure rules (`@/lib/state`, `@/lib/util`)

| Module | Exports |
| --- | --- |
| `state/checklist-tree` | `normalizeDepths`, `maxDepthAt`, `maxDepthInView`, `subtreeEnd`, `hasSubtasks`, `rootIndexOf`, `isFinished`, `setDoneCascading`, `viewPredecessor`, `canShiftDepth`, `shiftDepth`, `removeItem`, `moveSubtree`, `reopenWhereWritten` |
| `state/note-links` | `findNoteLinks`, `noteLinkToken`, `noteLinkTitle`, `plainNoteLinks`, `markdownNoteLinks`, `noteIdFromHref`, `NOTE_LINK_SCHEME`, `remapNoteLinks`, `openLinkQuery`, `backlinksTo`, `linkCandidates`, `snapOutOfLinks`, `widenLinkDeletion` (the `NoteLinkFormatter` rule: returns `{ text, caret }` or null) |
| `state/note-conversion` | `convertNoteKind`, `copyTitle` |
| `state/note-collection` | `selectNotes`, `filterNotes`, `scopeContains`, `scopeContainsWorkspace`, `ALL_SCOPE`, `NoteView`, `SortMode`, `SORT_MODES`, `ViewSelection` |
| `state/board-layout` | `buildBoard`, `boardPositionForReorder`, `boardPositionForInsertion`, `UNASSIGNED_PREVIEW_LIMIT`, `columnTitle`, `hiddenCount`, `isUnassignedColumn`, `boardHasNoStages`, `boardIsEmpty` |
| `state/sparse-position` | `POSITION_GAP`, `positionBetween`, `positionAt` |
| `state/reminder-agenda` | `scheduledReminders`, `occurrencesBetween`, `remindersByDay` (keys: local-midnight ms), `agendaFor`, `dayOf`, `occurrenceKey`, `occurrenceTitle`, `REMINDER_SNOOZES`, `snoozeAfter`, `movedToDay` |
| `state/note-availability` | `noteAvailability(source, note)` |
| `state/editor-history` | `EditorHistory` (`record(snapshot, "typing" \| "discrete")`, `undo`, `redo`, `resetTo`, `canUndo`, `canRedo`), `snapshotsEqual` |
| `state/display-title` | `noteDisplayTitle(note)` |
| `state/starter-notes` | starter texts |
| `util/search-query` | `parseSearchQuery`, `queryMatches`, `searchContext`, `queryText`, `stateOverride`, `filtersOnly`, `unknownFilters`, `tokenizeSearchQuery` (offsets for painting operators), `searchQueryHas`, `toggleSearchFilter`, `negateSearchFilter`, `cycleSearchFilter`, `filterToString`, `STATE_VALUES`, `HAS_VALUES`, `FILTER_FIELDS` |
| `util/linkify` | `findUrls`, `linkedSegments(text, query)`, `safeLinkHref(url)` (http/https only) |
| `util/highlight` | `highlightSegments(text, query)` |
| `util/mime` | `MAX_UPLOAD_BYTES`, `mimeFromName`, `extensionFromMime`, `pastedFileName`, `formatBytes`, `withinUploadLimit` |
| `util/note-export` | `EXPORT_FORMATS`, `exportNotes`, `exportFilename`, `noteToPlainText` (clipboard copy) |
| `util/backup` | `createBackupArchive`, `parseBackupArchive`, `backupFilename`, errors |
| `util/keep-import` | `parseKeepArchive`, `ImportFormatError` |
| `util/workspace-stats` | `computeWorkspaceStats`, `formatStatBytes`, `liveNotes`, `checklistProgress`, `busiestMonth`, `statsEmpty` |
| `util/network-error` | `describeConnectionFailure` |
| `util/public-route` | `publicShareToken`, `passwordResetToken` |

## 11. What the app root already does

- Mounts on the client only (`AppLoader`), wraps in
  `<MotionConfig reducedMotion="user">` and `TooltipProvider`, mounts
  `<Toaster />` (show toasts with `showAppSnack` from
  `@/components/common/snack`).
- Public routes (`/s/`, `/reset/`) render without auth.
- Auth gate: restoring shows a blank canvas, signed out shows `LoginScreen`,
  signed in creates the session (disposed on sign-out or user/server change).
- Signed in: `AppShell` around `RemindersView` (destination `reminders`),
  `BoardView` (destination `notes` and a board layout) or `NotesView`;
  `NoteEditor` over it for `/n/<id>`; `HistoryScreen` for `/n/<id>/history`;
  full pages for settings, workspace settings/stats and chat (lazy loaded).
- Appearance through the design layer: `applyTheme(accentColor, themeMode)`
  and `loadFont(font)` run in effects whenever those settings change (default
  accent and system mode while signed out); the explicit scheme is remembered
  for the next load's first paint. Label icons and colours live in
  `@/lib/theme/label-style` (DESIGN).
- Tab hidden: `flushForBackground()`; visible again: re-pull notes and
  settings.
- Semantic search turning out to be disabled shows a toast.

## 12. Not in CORE (and why)

- On-device notifications, geofenced reminders and saved places, home-screen
  widgets, share intake: out of scope on the web (as Flutter web). Their
  settings fields are carried through untouched.
- `rescheduleReminder` (reminders view and editor helper in
  `widgets/reminders/reminder_editing.dart`) is feature code: call
  `notes.setReminder` / `notes.setItemReminder` from it.
- Icons, colours, label styles, fonts, motion: DESIGN (`@/lib/theme`,
  `@/components`).
