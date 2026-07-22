# Sticky Notes

A Google Keep–style notes app: **Flutter** frontend (web + iOS + Android) with a **Rust** backend (axum + SQLite). Built for smoothness — every interaction is optimistic-first, every layout change animates, and collaboration syncs live over WebSockets.

<p align="center"><em>Masonry grid · drag-to-reorder · text, markdown, checklist, and audio notes · sharing and live co-editing · reminders · labels · attachments · dark mode</em></p>

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
- Keep's classic 8-color palette (white, red, orange, yellow, green, teal, blue, gray) with dark-mode variants
- Flat labels (create/rename/delete; filter from the drawer)
- Pinning, archive, trash (auto-purged after 7 days)
- **Drag-to-reorder** with animated reflow, edge auto-scroll, haptics
- Grid / single-column list toggle; responsive density and width presets support up to 8 columns
- **Sort by** custom order / recently edited / recently added / oldest
- Library-wide instant search + **find-in-note** with match highlighting
- **Semantic search** (meaning-ranking toggle in the search bar): notes are embedded locally with the full-precision **BAAI/bge-m3** ONNX model (1024 dimensions, no external AI service) and ranked by meaning — "internet access code" finds your "Wifi password" note. Vectors live in SQLite itself via the **sqlite-vec** extension, with one visibility-scoped row per note participant and no separate vector database.
- **Audio notes** (mic button, when transcription is enabled): record a voice clip in a focused overlay with a live level meter, then it's transcribed locally by a self-hosted **Whisper** service — no external AI. The clip stays playable in the note and the transcript is editable, searchable, and exportable text.
- **Feature detection**: semantic search and audio notes each have a Settings toggle, and disappear entirely when their backing service isn't running (`GET /api/capabilities`).

**Per-user settings** (synced across devices, gear icon in the drawer)
- Theme (system/light/dark), default grid vs list layout
- Accent color plus grid density and maximum-width presets
- Date format (5 styles) and 12h/24h time — applied to reminder chips and "Edited" stamps everywhere
- **Personalized note palette**: rename, recolor (light + dark shade each), delete, or add custom colors; notes with removed colors fall back gracefully
- Create and restore portable zip backups containing all non-trashed notes, labels, reminders, timestamps, and attachment bytes; readable JSON, Markdown, and plain-text exports remain available

**Optional AI integration**
- Each user can configure an OpenAI-compatible endpoint, API key, and model; Ollama, LM Studio, vLLM, and hosted providers can use the same path
- **Automatic labeling** asks the configured model which existing personal labels apply after content edits; it never invents or removes labels
- **Notes chat** retrieves semantically relevant notes, streams answers over WebSocket, cites source notes, and can create or append notes after a model-planned write
- Self-hosters can pin and lock any LLM field or feature toggle with server environment variables; managed secrets are never sent to the app

**Reminders**
- Time-based reminders per note, shown as chips (overdue = struck through) and collected in a drawer "Reminders" view. No calendar integration.
- **Push notifications via [ntfy](https://ntfy.sh) and/or Telegram** (Settings → Notifications): each user brings their own ntfy topic URL and/or Telegram bot token + chat id — no server-side setup. A background sweep (every 30 s) delivers due reminders to every participant of the note with a configured channel, exactly once per scheduled time (rescheduling re-arms it); checklist reminders list only the still-pending items. A "Send test" button delivers a real probe notification before you save. Channels are pluggable — a new one is a single `Connector` impl on the backend plus a spec entry in the app.

**Collaboration**
- User accounts with a display name and email + password sign-in (argon2-hashed, token sessions); name, email, and password are editable in Settings
- Share notes with other users by email; everyone can edit, only the owner can trash/delete/share
- **Live sync over WebSockets**: collaborator edits (and your other devices) update in place, last-write-wins
- Labels stay personal — each participant tags a shared note with their own labels

**Platform integration**
- Web drag-and-drop and file picking; native file/image pickers on mobile
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
| `Esc` | Notes screen | Clear search |
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
│   │   ├── search.rs     BGE-M3 embeddings + sqlite-vec index
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

**Custom animated masonry.** Keep's grid is a masonry with drag-to-reorder; no Flutter package does both, so [app/lib/widgets/masonry.dart](app/lib/widgets/masonry.dart) implements it: tiles are measured after layout and absolutely positioned, so any reflow — reorder, edit, column change — glides tiles to their new spots. Long-press lifts a card; siblings flow around the pointer in real time.

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

### Local development

Prereqs: Rust 1.85+ (edition 2024) and Flutter 3.44+ / Dart 3.12+.

**Backend** (port 8787):

```sh
cd backend
cargo run
# or with Whisper for audio-note transcription:
docker compose up -d whisper
STICKY_NOTES_WHISPER_URL=http://localhost:9000 cargo run
```

Env vars: `STICKY_NOTES_DB` (SQLite path, default `sticky_notes.db`), `STICKY_NOTES_ADDR` (default `0.0.0.0:8787`), `STICKY_NOTES_UPLOADS` (attachment directory, default `uploads`), `STICKY_NOTES_WEB` (optional Flutter web bundle to serve), `STICKY_NOTES_SEMANTIC=off` (disable embeddings entirely), `STICKY_NOTES_PUBLIC_URL` (the backend URL the bundled web app should target by default — see below), `STICKY_NOTES_WHISPER_URL` (optional Whisper ASR service), `STICKY_NOTES_TELEGRAM_API` (Telegram Bot API base, default `https://api.telegram.org`), and `STICKY_NOTES_UNFURL_ALLOW_PRIVATE=1` (allow link previews for private/loopback hosts; off by default for SSRF safety). BGE-M3 downloads to the fastembed/Hugging Face cache on first start.

Default backend URL for the bundled web app: when the binary also serves the Flutter web build, it normally targets its own origin. Behind a reverse proxy (e.g. `https://notes.example.com` on :443) that heuristic can miss, so set **`STICKY_NOTES_PUBLIC_URL`** to the URL browsers should call — the server stamps it into `index.html` at startup and the app uses it as the default, no rebuild needed. Users can still switch servers from the login screen's server picker.

Attachment storage: `STICKY_NOTES_STORAGE` (`disk` default, or `s3`). With `s3`, set `STICKY_NOTES_S3_URL` (endpoint, e.g. `http://localhost:3900`), `STICKY_NOTES_S3_ACCESS_KEY`, `STICKY_NOTES_S3_SECRET_KEY`, and optionally `STICKY_NOTES_S3_REGION` (default `garage`) and `STICKY_NOTES_S3_BUCKET_PREFIX` (default `sticky-notes-`, bucket names are `{prefix}{user-id}`). The access key needs permission to create buckets (Garage's auto-provisioned default key has it). Works against any S3-compatible store; for dev: `docker compose up -d garage`, then run with the compose file's key pair.

Server-managed LLM config (optional): the LLM integration is normally per-user (each account sets its own endpoint/key/model in Settings). A self-hoster can instead **pin** any of these from the environment — `STICKY_NOTES_LLM_BASE_URL`, `STICKY_NOTES_LLM_API_KEY`, `STICKY_NOTES_LLM_MODEL`, `STICKY_NOTES_LLM_LABELING` (`true`/`false`), `STICKY_NOTES_LLM_CHAT` (`true`/`false`). A set value overrides the user's copy and **locks** that field in Settings (shown as "Managed by the server"), so you can point everyone at one provider without exposing the key. Overrides are per-field — pin the endpoint + model and still let users bring their own key, or the reverse. The API key is a **secret**: it drives the server but its value is never sent to the app.

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
| `POST /auth/register` · `/auth/login` · `/auth/logout`, `GET/PATCH /auth/me` | Accounts, profile changes & sessions |
| `GET/POST /notes`, `GET/PATCH/DELETE /notes/{id}` | Notes (PATCH is partial; `reminder_at: null` clears) |
| `POST /notes/reorder` | Persist drag order (renumbers the given ids) |
| `GET /notes/{id}/versions`, `POST /notes/{id}/versions/{version_id}/restore` | Version timeline and reversible restore |
| `POST /notes/{id}/collaborators`, `DELETE /notes/{id}/collaborators/{user_id}` | Sharing |
| `POST /notes/{id}/attachments`, `DELETE /attachments/{id}`, `GET /files/{id}?exp=…&sig=…` | Attachments and signed, expiring media/download access |
| `GET/POST /labels`, `PATCH/DELETE /labels/{id}` | Labels (per-user) |
| `GET /checklist-history` | Checked-off item texts, most used first (typing suggestions) |
| `GET /search?q=…` | Semantic search: ranked `{note_id, score}` (503 when disabled) |
| `GET /search/stats`, `POST /search/reindex`, `GET /search/reindex/status` | Embedding diagnostics and background reindexing |
| `POST /notes/{id}/transcribe` | Re-run Whisper on an audio note's clip (retry; 503 when disabled) |
| `GET/PUT /settings` | Per-user settings document (opaque JSON, ≤16 KB) |
| `GET /unfurl?url=…` | SSRF-guarded link preview metadata |
| `POST /llm/test`, `/notify/test` | Test unsaved LLM or notification configuration |
| `GET /chat?token=…` | One streaming notes-chat turn over WebSocket |
| `GET /ws?token=…` | Change-event WebSocket; clients debounce and refetch notes/settings |

## Design notes & trade-offs

- **Co-editing is last-write-wins** at note granularity (no CRDT). The WS nudge keeps everyone fresh; a reorder mid-drag from another device is never committed as your drag.
- **Pin/archive/order are shared** on a shared note (Keep makes them per-user; kept global for simplicity).
- Client-generated UUIDs let notes be created offline and synced later; the server returns 409 Conflict if an id is reused.
- Checklist history records on the *check-off* transition and is shared by collaborators on that note, capped at 500 entries per note.
