# Sticky Notes

A cross-platform notes app: **Flutter** frontend (web + iOS + Android) with a **Rust** backend (axum + SQLite). Built for smoothness — every interaction is optimistic-first, every layout change animates, and collaboration syncs live over WebSockets.

<p align="center"><em>Masonry grid · drag-to-reorder · text, markdown, checklist, and audio notes · sharing and live co-editing · reminders · labels · kanban board · attachments · dark mode</em></p>

## Features

**Note types**
- Text, **markdown**, and **checklist** notes, with conversion between text-based kinds
- **Audio notes** recorded on web, iOS, or Android and transcribed by an optional self-hosted Whisper service
- **Image attachments** (including SVG) rendered inline, playable audio-note clips, and **any other file type** as a safe download with its original filename
- Rich link previews from Open Graph/HTML metadata, fetched through an SSRF-guarded backend endpoint and cached on both client and server
- Checklists **remember what you've checked off** and **suggest items while you type**, in a popup anchored under the row with the matched prefix bolded — type "mi" and get "Milk" from your history; your most frequent items surface when the field is empty. Perfect for grocery lists.
- Checking an item **animates it down into a collapsible "checked" section** where it stays visible; unchecking glides it back
- **Drag handles** (⠿) reorder checklist items with live animated reflow
- **Undo/redo** in the editor (bottom-bar arrows, Cmd/Ctrl+Z / Shift+Z): typing groups into bursts; checks, adds, removes, reorders, and conversions are each one step
- **Version history** groups content edits into sessions, attributes collaborator edits, and supports reversible restores

**Organization**
- **Workspaces**: every account starts with a default workspace and can create more, switching from the header of the drawer/sidebar. Notes, labels, archive, trash, search, and chat are all scoped to the open one, and a note can be moved between workspaces from its menu.
- An 8-color palette (white, red, orange, yellow, green, teal, blue, gray) with dark-mode variants
- Flat labels per workspace (create/rename/delete; filter from the drawer)
- **Board view**: a kanban board whose columns are the workspace's *stages* — a system deliberately separate from labels, so a note carries any number of labels and sits in at most one column. Columns are side by side on wide screens and paged behind a name strip on phones; cards move with "Move to column" from the card menu. Unplaced notes collect in a capped **Unassigned** column.
- Pinning, archive, trash (auto-purged after 7 days)
- **Drag-to-reorder** with animated reflow, edge auto-scroll, haptics
- Grid / single-column list toggle; responsive density and width presets support up to 8 columns
- **Sort by** custom order / recently edited / recently added / oldest
- Library-wide instant search + **find-in-note** with match highlighting
- **Semantic search** (meaning-ranking toggle in the search bar): notes are embedded by a self-hostable **OpenAI-compatible embeddings API** (Ollama, LM Studio, ...) and ranked by meaning — "internet access code" finds your "Wifi password" note. Vectors live in SQLite itself via the **sqlite-vec** extension, with one visibility-scoped row per note participant and no separate vector database. The server runs no model of its own, so its memory footprint doesn't depend on the model you choose.
- **Audio notes** (mic button, when transcription is enabled): record a voice clip in a focused overlay with a live level meter, then it's transcribed locally by a self-hosted **Whisper** service — no external AI. The clip stays playable in the note and the transcript is editable, searchable, and exportable text.
- **Feature detection**: semantic search and audio notes each have a Settings toggle, and disappear entirely when their backing service isn't running (`GET /api/capabilities`).

**Per-user settings** (synced across devices, gear icon in the drawer)
- Theme (system/light/dark), default grid vs list layout
- Accent color plus grid density and maximum-width presets
- Date format (5 styles) and 12h/24h time — applied to reminder chips and "Edited" stamps everywhere
- **Personalized note palette**: rename, recolor (light + dark shade each), delete, or add custom colors; notes with removed colors fall back gracefully
- Create portable zip backups of every owned workspace, including notes (also archived and trashed), labels, board columns, reminders, ordering, timestamps, and attachment bytes. Restore previews the workspaces in the archive and replaces owned workspace data with the selected backup workspaces; workspaces shared with the user are untouched. Readable JSON, Markdown, and plain-text exports remain available.
- Operators can create whole-system `.skb` archives from the server CLI while Skippy is online. These contain a consistent database snapshot plus every referenced attachment from disk or S3, can be scheduled with cron, and restore the complete instance offline with an automatic pre-restore safety backup.

**Optional AI integration**
- Each user can configure an OpenAI-compatible endpoint, API key, and model; Ollama, LM Studio, vLLM, and hosted providers can use the same path
- **Automatic labeling** asks the configured model which of the note's workspace labels apply after content edits; it never invents or removes labels
- **Opt-in AI note editing** can clean up and shorten a note or correct grammar and syntax; it only appears after an AI provider is configured and the feature is enabled in Settings
- **Notes chat** retrieves semantically relevant notes, streams answers over WebSocket, cites source notes, and can create or append notes after a model-planned write
- Self-hosters can pin and lock any LLM field or feature toggle with server environment variables; managed secrets are never sent to the app

**Reminders**
- Time-based reminders per note, shown as chips (overdue = struck through) and collected in a drawer "Reminders" view. No calendar integration.
- On phones, one reminder sheet provides quick presets for tomorrow morning, noon, evening, next week, and seven days from now, plus an inline custom date/time picker.
- **Push notifications via [ntfy](https://ntfy.sh) and/or Telegram** (Settings → Notifications): each user brings their own ntfy topic URL and/or Telegram bot token + chat id — no server-side setup. A background sweep (every 30 s) delivers due reminders to every participant of the note with a configured channel, exactly once per scheduled time (rescheduling re-arms it); checklist reminders list only the still-pending items. A "Send test" button delivers a real probe notification before you save. Channels are pluggable — a new one is a single `Connector` impl on the backend plus a spec entry in the app.

**Collaboration**
- User accounts with a display name and email + password sign-in (argon2-hashed, token sessions); name, email, and password are editable in Settings. Password-confirmed account deletion removes every workspace the account owns and all notes inside those workspaces, including notes authored by other users.
- Share a single note with other users by email; everyone can edit, only the owner can trash/delete/share
- **Or share a whole workspace**: invite people by email and they see and edit every note it holds. Only the owner renames it, deletes it, or changes the roster; members can leave. Deleting a workspace permanently deletes every note and attachment inside it, regardless of author. Leaving or being removed preserves that member's own notes by moving them to their default workspace.
- **Live sync over WebSockets**: collaborator edits (and your other devices) update in place, last-write-wins
- Labels are a workspace's shared taxonomy: everyone in it sees and applies the same set. Someone who only has a per-note share is not in that workspace and sees none of them.

**Platform integration**
- Web drag-and-drop and file picking; native file/image pickers on mobile
- Adaptive overlays: input-heavy editors use full-screen pages on phones and compact dialogs on web; quick choices use phone bottom sheets and centered web surfaces.
- Android/iOS share-sheet intake turns shared text/links into text notes and shared files into attachment notes
- Offline startup from a per-user local cache, with pending writes persisted and replayed after connectivity returns

**Out of scope:** drawings/handwriting, OCR, calendar synchronization, and CRDT-style conflict-free collaborative editing.

## Keyboard shortcuts

Web/desktop. Press **`?`** on the notes screen for the in-app cheat sheet (also in Settings → Help). Letter shortcuts never fire while you're typing in a text field — the keystroke goes into the field instead — and they match the *character* produced, so they work on any keyboard layout.

| Keys | Where | Action |
| --- | --- | --- |
| `c` or `n` | Notes screen | New note |
| `l` | Notes screen | New checklist |
| `m` | Notes screen | New markdown note |
| `/` or `Ctrl`/`⌘` `K` | Notes screen | Search |
| `Esc` | Notes screen | Exit selection mode, else clear search |
| `Ctrl`/`⌘` `G` | Notes screen | Toggle grid / list |
| `?` | Notes screen | Shortcut help |
| `Ctrl`/`⌘` `Z` · `Shift` + `Ctrl`/`⌘` `Z` | Editor | Undo · redo |
| `Esc` | Editor (modal) | Close and save |
| `Esc` | Quick add | Save and close |

## Architecture

```
sticky_notes/
├── backend/            Rust: axum + SQLite
│   ├── src/
│   │   ├── main.rs       process wiring, optional services, static web serving
│   │   ├── lib.rs        AppState + /api router (build_app), reused by tests
│   │   ├── handlers/     HTTP/WS handlers by feature area + background work
│   │   ├── store/        Repository trait, SQLite implementation/schema/rows
│   │   ├── models.rs     domain, request, and response types
│   │   ├── files.rs      FileStore trait, disk/S3 backends, signed file URLs
│   │   ├── system_backup.rs whole-instance archive, validation, and restore
│   │   ├── search.rs     embeddings API client + sqlite-vec index
│   │   ├── assist.rs     LLM settings, prompts, routing, and reply parsing
│   │   ├── llm.rs        OpenAI-compatible completion and streaming client
│   │   ├── notify.rs     reminder scheduler + ntfy/Telegram connectors
│   │   └── unfurl.rs     safe URL fetching and metadata parsing
│   └── tests/           API integration modules + S3 tests
└── app/                Flutter
    ├── lib/
    │   ├── api/          Api seam + HTTP/WS client
    │   ├── models/       wire/domain models
    │   ├── state/        auth, settings, optimistic notes, cache, share intake
    │   ├── screens/      login, home, editor, history, settings, chat
    │   ├── widgets/      masonry, cards, checklist, media, dialogs, settings
    │   ├── util/         platform adapters, links, export, downloads, motion
    │   └── theme.dart    Material light/dark themes
    └── test/           unit, store, integration-style widget tests + FakeApi
```

**Swappable storage.** All persistence goes through the `Repository` trait ([backend/src/store/mod.rs](backend/src/store/mod.rs)). SQLite is the only implementation today; to move to Postgres, implement the trait and change one constructor in `main.rs`. Attachment blobs live behind a separate `FileStore` trait ([backend/src/files.rs](backend/src/files.rs)) with two backends: local disk (default) and any S3-compatible object store — one bucket per user, requests signed with a minimal built-in SigV4 (no AWS SDK). `STICKY_NOTES_STORAGE=disk|s3` picks the backend; the compose stack bundles [Garage](https://garagehq.deuxfleurs.fr/) for the S3 side.

**Optimistic-first client.** Every action updates the UI immediately; writes flow through a serial queue that retries on network failure (a banner shows offline state). The network is never in the tap path — that's where the smoothness comes from.

**Custom animated masonry.** The grid is a masonry with drag-to-reorder; no Flutter package does both, so [app/lib/widgets/masonry.dart](app/lib/widgets/masonry.dart) implements it: tiles are measured after layout and absolutely positioned, so any reflow — reorder, edit, column change — glides tiles to their new spots. Long-press lifts a card; siblings flow around the pointer in real time.

## Running it

### Docker (everything in one command)

```sh
docker compose up -d        # builds web + server, starts Whisper + Garage → http://localhost:8787
```

The image builds the Flutter web app and the Rust server; volumes persist the SQLite DB, uploads, and the embedding model cache. Semantic search is built into the server (sqlite-vec) and a self-hosted Whisper service backs audio-note transcription inside the stack.

**Attachment storage** defaults to disk (the `app_data` volume). To keep attachments in the bundled [Garage](https://garagehq.deuxfleurs.fr/) object store instead — one S3 bucket per user, auto-created on first upload:

```sh
STICKY_NOTES_STORAGE=s3 docker compose up -d   # or set it in a .env file
```

Garage bootstraps itself (`--single-node --default-bucket`): no CLI setup, credentials come from the compose file — change the default `GARAGE_RPC_SECRET` / `STICKY_NOTES_S3_ACCESS_KEY` / `STICKY_NOTES_S3_SECRET_KEY` for anything beyond a LAN toy. Pick one backend per deployment: switching doesn't migrate already-uploaded blobs.

### Configuration

Every environment variable the server reads. All are optional — an unset variable takes the default in the second column, and the server runs with none of them set. `docker-compose.yml` lists the same set (the optional ones commented out) so you can uncomment what you need.

**Core**

| Variable | Default | What it does |
| --- | --- | --- |
| `STICKY_NOTES_ADDR` | `0.0.0.0:8787` | Listen address. |
| `STICKY_NOTES_DB` | `sticky_notes.db` (`/data/sticky_notes.db` in the image) | SQLite database path. Created if missing. |
| `STICKY_NOTES_UPLOADS` | `uploads` (`/data/uploads`) | Attachment directory. Disk storage only — ignored when `STICKY_NOTES_STORAGE=s3`. |
| `STICKY_NOTES_WEB` | `../app/build/web` (`/app/web`) | Flutter web bundle to serve alongside the API. Silently skipped when the directory has no `index.html`. |
| `STICKY_NOTES_PUBLIC_URL` | unset | The URL browsers should call. Stamped into `index.html` at startup as the app's default backend **and** used as the sole allowed CORS origin. Unset ⇒ same-origin, CORS open to any browser origin. |

**Semantic search**

| Variable | Default | What it does |
| --- | --- | --- |
| `STICKY_NOTES_EMBED_URL` | unset | Base URL of an OpenAI-compatible embeddings API, e.g. `http://ollama:11434/v1`. Probed once at startup; unset or unreachable ⇒ semantic search stays off for the life of the process. |
| `STICKY_NOTES_EMBED_MODEL` | `bge-m3` | Embedding model to request. Changing it (or its vector width) rebuilds the index and re-embeds every note. |
| `STICKY_NOTES_EMBED_API_KEY` | unset | Bearer token for the embeddings API. Omit for Ollama; required for OpenAI. |

**Audio transcription**

| Variable | Default | What it does |
| --- | --- | --- |
| `STICKY_NOTES_WHISPER_URL` | unset | Base URL of a Whisper ASR service. Probed once at startup; unset or unreachable ⇒ transcription stays off for the life of the process. |

**Attachment storage**

| Variable | Default | What it does |
| --- | --- | --- |
| `STICKY_NOTES_STORAGE` | `disk` | `disk` or `s3`. Any other value aborts startup. |
| `STICKY_NOTES_S3_URL` | — | **Required** when `s3`. Endpoint, e.g. `http://garage:3900`. |
| `STICKY_NOTES_S3_ACCESS_KEY` | — | **Required** when `s3`. Needs permission to create buckets. |
| `STICKY_NOTES_S3_SECRET_KEY` | — | **Required** when `s3`. |
| `STICKY_NOTES_S3_REGION` | `garage` | SigV4 region. |
| `STICKY_NOTES_S3_BUCKET_PREFIX` | `sticky-notes-` | Buckets are named `{prefix}{user-id}`. |

Missing a required `s3` variable is a hard startup failure, not a silent downgrade to disk.

**Notifications & link previews**

| Variable | Default | What it does |
| --- | --- | --- |
| `STICKY_NOTES_TELEGRAM_API` | `https://api.telegram.org` | Telegram Bot API base, for self-hosted bot-api servers or proxies. |
| `STICKY_NOTES_UNFURL_ALLOW_PRIVATE` | unset (off) | `1`/`true`/`yes`/`on` lets link previews resolve private and loopback hosts. Off by default as an SSRF guard — only turn it on to preview links on your own LAN. |
| `STICKY_NOTES_ALLOW_PRIVATE_USER_ENDPOINTS` | unset (off) | Allows per-user/managed LLM and ntfy URLs to resolve private or loopback addresses. Leave off on public-registration servers; enable only when users are trusted and need LAN services such as Ollama or a private ntfy. Public targets are DNS-pinned and redirects are refused. |

**Server-managed LLM settings**

Each one overrides the per-user value and locks that field in the app's Settings. Booleans accept `true`/`1`/`on`/`yes` and `false`/`0`/`off`/`no`; an empty or unparseable value leaves the field user-owned.

| Variable | Manages | Notes |
| --- | --- | --- |
| `STICKY_NOTES_LLM_BASE_URL` | `llm_base_url` | OpenAI-compatible endpoint, e.g. `http://ollama:11434/v1` (private hosts also require `STICKY_NOTES_ALLOW_PRIVATE_USER_ENDPOINTS=1`). |
| `STICKY_NOTES_LLM_API_KEY` | `llm_api_key` | **Secret** — drives the server, never sent to the app. |
| `STICKY_NOTES_LLM_MODEL` | `llm_model` | |
| `STICKY_NOTES_LLM_LABELING` | `llm_labeling` | Boolean. Auto-labeling on/off. |
| `STICKY_NOTES_LLM_CHAT` | `llm_chat` | Boolean. Notes chat on/off. |
| `STICKY_NOTES_LLM_WRITING` | `llm_writing` | Boolean. AI note editing on/off. |

**Other services in the compose stack** (read by those images, not by this server): `ASR_MODEL` (`base`; `tiny`/`small`/`medium`/`large-v3`) and `ASR_ENGINE` (`faster_whisper`) on Whisper; `GARAGE_RPC_SECRET`, `GARAGE_DEFAULT_ACCESS_KEY`, `GARAGE_DEFAULT_SECRET_KEY`, `GARAGE_DEFAULT_BUCKET` on Garage — the access/secret pair must match the `STICKY_NOTES_S3_*` keys given to the server, which is why the compose file feeds both from the same variables.

The Flutter app has one build-time knob rather than an environment variable: `--dart-define=API_BASE=<url>` sets the backend it targets by default (see [Local development](#local-development)).

### Local development

Prereqs: Rust 1.88+ (edition 2024) and Flutter 3.44+ / Dart 3.12+.

**Backend** (port 8787):

```sh
cd backend
cargo run
# or with Whisper for audio-note transcription:
docker compose up -d whisper
STICKY_NOTES_WHISPER_URL=http://localhost:9000 cargo run
```

Every knob is an environment variable and every one is optional — see [Configuration](#configuration) for the full list with defaults. The four settings worth understanding rather than just looking up:

Embeddings run **outside** this process, on any OpenAI-compatible endpoint (`STICKY_NOTES_EMBED_URL`) — typically an Ollama you already run: `ollama pull bge-m3`, then point the server at `http://…:11434/v1`. The server therefore holds no model weights and its memory stays flat no matter how large the embedding model is; the cost of a big model lands on the machine actually running it. Leave the URL unset and semantic search (and with it notes chat, which retrieves through the same index) simply stays off. The vector width is discovered from the endpoint at startup, so switching models needs no code change — the index notices the new signature and re-embeds.

Default backend URL for the bundled web app: when the binary also serves the Flutter web build, it normally targets its own origin. Behind a reverse proxy (e.g. `https://notes.example.com` on :443) that heuristic can miss, so set **`STICKY_NOTES_PUBLIC_URL`** to the URL browsers should call — the server stamps it into `index.html` at startup and the app uses it as the default, no rebuild needed. It also restricts HTTP CORS to that URL's origin (scheme, host, and port), rather than allowing every browser origin. Users can still switch servers from the login screen's server picker.

Attachment storage (`STICKY_NOTES_STORAGE`) works against any S3-compatible store, not just the bundled Garage — the app creates one bucket per user on that user's first upload, so the access key needs permission to create buckets (Garage's auto-provisioned default key has it). For dev: `docker compose up -d garage`, then run with the compose file's key pair.

Server-managed LLM config (optional): the LLM integration is normally per-user (each account sets its own endpoint/key/model in Settings). A self-hoster can instead **pin** any of the six `STICKY_NOTES_LLM_*` fields from the environment. A set value overrides the user's copy and **locks** that field in Settings (shown as "Managed by the server"), so you can point everyone at one provider without exposing the key. Overrides are per-field — pin the endpoint + model and still let users bring their own key, or the reverse. The API key is a **secret**: it drives the server but its value is never sent to the app.

**Flutter app** — pick a device:

```sh
cd app
flutter run -d chrome                 # web (dev)
flutter run -d <ios-or-android-id>    # mobile
```

The app talks to `http://localhost:8787` by default. Override with `--dart-define=API_BASE=http://<host>:8787` — needed on Android emulators (`http://10.0.2.2:8787`) or real phones (your machine's LAN IP).

You can also set the backend URL directly from the login screen — tap the server chip below the title to switch between saved servers or add a new one. The selection is persisted locally on the device.

### iOS device deployment

**Build the release binary:**

```sh
cd app
flutter build ios --release
```

**Deploy to a connected iPhone** (USB or wireless):

```sh
flutter devices                               # find your device ID
flutter run --release --device-id <device-id>  # build + install + launch
# or just install without launching:
flutter install --device-id <device-id>
```

**First-time setup on the iPhone:**

1. **Enable Developer Mode** — Settings → Privacy & Security → Developer Mode → toggle on (requires restart).
2. **Trust the developer certificate** — after the first install, go to Settings → General → VPN & Device Management and trust your developer profile.
3. **Keep the phone unlocked** while the install command runs.

**Fallback — deploy via Xcode:**

```sh
open ios/Runner.xcworkspace
```

Select your iPhone as the run destination in the toolbar and press Run. Xcode gives better error messages for signing or provisioning issues.

**Connecting to the backend from a physical device:**

`localhost` won't work from a phone. Either:

- Use the login screen's server selector to point at your Mac's LAN IP (e.g. `http://192.168.1.42:8787`).
- Or pass it at build time: `flutter run --release --dart-define=API_BASE=http://192.168.1.42:8787`.

Make sure the backend is running with `STICKY_NOTES_ADDR=0.0.0.0:8787` (the default) and that your Mac's firewall allows port 8787.

**Single-binary production deploy:** build the web app, then run the server — it detects and serves the bundle:

```sh
cd app && flutter build web --release
cd ../backend && cargo run            # → open http://localhost:8787
```

## Whole-system backup and restore

The Settings backup is portable and user-scoped. Server operators also have a
whole-system backup containing the complete SQLite database (accounts, password
hashes, active sessions, settings, all workspaces and notes, history, server
metadata, and search tables) plus every referenced attachment byte. Environment
variables, the container image, and external Whisper/LLM service state are not
included.

Create a backup while the server is running:

```sh
cd backend
cargo run -- system-backup /safe/path/skippy-20260729-030000.skb
```

With Docker Compose, `./backups` is mounted at `/backups` by default. Override
the host path with `STICKY_NOTES_BACKUPS_DIR` in `.env`. A host crontab entry
for a daily 03:15 UTC backup is:

```cron
15 3 * * * cd /srv/skippy && docker compose exec -T --user sticky-notes server /app/sticky-notes-server system-backup /backups/skippy-$(date -u +\%Y\%m\%d-\%H\%M\%S).skb
```

Each backup is written to a private temporary file, checksummed, and renamed
into place only after the SQLite snapshot and every attachment succeed. Copy or
sync `/backups` off the Skippy host and apply retention there; a backup stored
only beside the live server is not disaster recovery.

Restore is intentionally offline and refuses to run while the server holds the
database lock:

```sh
docker compose stop server
docker compose run --rm --no-deps server \
  /app/sticky-notes-server system-restore \
  /backups/skippy-20260729-030000.skb --confirm
docker compose up -d server
```

The archive and its database are fully validated before current data changes.
The command then creates `/data/system-backups/pre-restore-*.skb`, restores
attachments through the configured disk/S3 backend, atomically replaces the
database, and removes now-unreferenced blobs. If the current database is too
damaged to make the safety archive, `--skip-safety-backup` is the explicit
last-resort override.

## Tests

```sh
cd backend && cargo test
cd backend && cargo clippy --all-targets -- -D warnings
cd app && flutter test
cd app && flutter analyze
```

Backend tests run the real router against in-memory SQLite and deterministic fakes for embeddings, Whisper, LLMs, notification connectors, outbound unfurls, and S3. They cover auth, permissions, sharing, versions, checklist history, reminders, signed/range-capable file serving, semantic indexing, chat/write flows, managed settings, and optional-service behavior. Flutter tests cover models and pure utilities, the optimistic/offline store, settings persistence, share intake, media flows, keyboard shortcuts, and integration-style widget behavior with `FakeApi`.

## API sketch

All under `/api`, JSON, `Authorization: Bearer <token>` (from `/auth/register` or `/auth/login`).

| Endpoint | Purpose |
| --- | --- |
| `GET /health`, `/capabilities` | Health and optional-service detection |
| `GET /managed-settings` | Server-pinned setting descriptors; secrets are redacted |
| `POST /auth/register` · `/auth/login` · `/auth/logout`, `GET/PATCH/DELETE /auth/me` | Accounts, profile changes, deletion & sessions |
| `GET/POST /workspaces`, `PATCH/DELETE /workspaces/{id}` | Workspaces (the default cannot be deleted; deleting another permanently deletes all notes and attachments inside it) |
| `POST /workspaces/{id}/members`, `DELETE /workspaces/{id}/members/{user_id}` | Workspace roster; removing yourself leaves it |
| `GET/POST /notes`, `GET/PATCH/DELETE /notes/{id}` | Notes (PATCH is partial; `reminder_at: null` and `stage_id: null` clear; `workspace_id` moves the note) |
| `POST /notes/{id}/rewrite` | Opt-in LLM cleanup/concise or grammar-only note edit |
| `POST /notes/reorder` | Persist drag order (renumbers the given ids) |
| `GET /notes/{id}/versions`, `POST /notes/{id}/versions/{version_id}/restore` | Version timeline and reversible restore |
| `POST /notes/{id}/collaborators`, `DELETE /notes/{id}/collaborators/{user_id}` | Sharing |
| `POST /notes/{id}/attachments`, `DELETE /attachments/{id}`, `GET /files/{id}?exp=…&sig=…` | Attachments and signed, expiring media/download access |
| `GET/POST /labels`, `PATCH/DELETE /labels/{id}` | Labels (per workspace, shared by its members) |
| `GET/POST /stages`, `PATCH/DELETE /stages/{id}` | Board columns (per workspace, shared by its members; deleting one returns its notes to Unassigned) |
| `GET /checklist-history` | Checked-off item texts, most used first (typing suggestions) |
| `GET /search?q=…&workspace_id=…` | Semantic search: ranked `{note_id, score}` (503 when disabled) |
| `GET /search/stats`, `POST /search/reindex`, `GET /search/reindex/status` | Embedding diagnostics and background reindexing |
| `POST /notes/{id}/transcribe` | Re-run Whisper on an audio note's clip (retry; 503 when disabled) |
| `GET/PUT /settings` | Per-user settings document (opaque JSON, ≤16 KB) |
| `GET /unfurl?url=…` | SSRF-guarded link preview metadata |
| `POST /llm/test`, `/notify/test` | Test unsaved LLM or notification configuration |
| `GET /chat` | One streaming notes-chat turn over WebSocket; auth is in the first frame |
| `GET /ws` | Change-event WebSocket; auth is in the first frame, then clients debounce and refetch |

For rolling native-app upgrades, the previous `?token=…` WebSocket form is
temporarily accepted by the server. Current clients never put session tokens
in URLs; remove the compatibility path after older mobile releases age out.

## Design notes & trade-offs

- **Co-editing is last-write-wins** at note granularity (no CRDT). The WS nudge keeps everyone fresh; a reorder mid-drag from another device is never committed as your drag.
- **Pin/archive/order are shared** on a shared note (global for simplicity).
- **Workspace membership is flat**: an owner plus members who can all edit. No viewer/admin roles — the permission matrix stays small enough to reason about on every note endpoint.
- Client-generated UUIDs let notes be created offline and synced later; the server returns 409 Conflict if an id is reused.
- Checklist history records on the *check-off* transition and is shared by collaborators on that note, capped at 500 entries per note.
