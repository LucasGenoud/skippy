# Sticky Notes

A Google Keep–style notes app: **Flutter** frontend (web + iOS + Android) with a **Rust** backend (axum + SQLite). Built for smoothness — every interaction is optimistic-first, every layout change animates, and collaboration syncs live over WebSockets.

<p align="center"><em>Masonry grid · drag-to-reorder · checklists with typing suggestions · sharing & live co-editing · reminders · labels · images · dark mode</em></p>

## Features

**Note types**
- Text notes and **checklists** (convert between them any time)
- **Image attachments** (rendered inline) and **any other file type** (stored and served as safe downloads with original filename — PDFs, archives, audio, spreadsheets…)
- Checklists **remember what you've checked off** and **suggest items while you type**, in a popup anchored under the row with the matched prefix bolded — type "mi" and get "Milk" from your history; your most frequent items surface when the field is empty. Perfect for grocery lists.
- Checking an item **animates it down into a collapsible "checked" section** where it stays visible; unchecking glides it back
- **Drag handles** (⠿) reorder checklist items with live animated reflow
- **Undo/redo** in the editor (bottom-bar arrows, Cmd/Ctrl+Z / Shift+Z): typing groups into bursts; checks, adds, removes, reorders, and conversions are each one step

**Organization**
- Keep's classic 8-color palette (white, red, orange, yellow, green, teal, blue, gray) with dark-mode variants
- Flat labels (create/rename/delete; filter from the drawer)
- Pinning, archive, trash (auto-purged after 7 days)
- **Drag-to-reorder** with animated reflow, edge auto-scroll, haptics
- Grid / single-column list toggle; responsive 1–5 columns from phone to desktop
- **Sort by** custom order / recently edited / recently added / oldest
- Library-wide instant search + **find-in-note** with match highlighting
- **Semantic search** (✨ toggle in the search bar): notes are embedded locally with an ONNX model (all-MiniLM-L6-v2, no external AI services) and ranked by meaning — "internet access code" finds your "Wifi password" note. Vectors live in SQLite itself via the **sqlite-vec** extension — no separate vector database to run.
- **Audio notes** (mic button, when transcription is enabled): record a voice clip in a focused overlay with a live level meter, then it's transcribed locally by a self-hosted **Whisper** service — no external AI. The clip stays playable in the note and the transcript is editable, searchable, and exportable text.
- **Feature detection**: semantic search and audio notes each have a Settings toggle, and disappear entirely when their backing service isn't running (`GET /api/capabilities`).

**Per-user settings** (synced across devices, gear icon in the drawer)
- Theme (system/light/dark), default grid vs list layout
- Date format (5 styles) and 12h/24h time — applied to reminder chips and "Edited" stamps everywhere
- **Personalized note palette**: rename, recolor (light + dark shade each), delete, or add custom colors; notes with removed colors fall back gracefully

**Reminders**
- Time-based reminders per note, shown as chips (overdue = struck through) and collected in a drawer "Reminders" view. No calendar integration.
- **Push notifications via [ntfy](https://ntfy.sh) and/or Telegram** (Settings → Notifications): each user brings their own ntfy topic URL and/or Telegram bot token + chat id — no server-side setup. A background sweep (every 30 s) delivers due reminders to every participant of the note with a configured channel, exactly once per scheduled time (rescheduling re-arms it); checklist reminders list only the still-pending items. A "Send test" button delivers a real probe notification before you save. Channels are pluggable — a new one is a single `Connector` impl on the backend plus a spec entry in the app.

**Collaboration**
- User accounts (username + password, argon2-hashed, token sessions)
- Share notes with other users by username; everyone can edit, only the owner can trash/delete/share
- **Live sync over WebSockets**: collaborator edits (and your other devices) update in place, last-write-wins
- Labels stay personal — each participant tags a shared note with their own labels

**Out of scope** (would need AI services / heavy platform APIs): drawings, audio recording, voice transcription, OCR. The schema (attachments table, note `kind` field) leaves room for them.

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
│   │   ├── main.rs       wiring (swap the repository here)
│   │   ├── lib.rs        router (build_app) — reused by tests
│   │   ├── store/        Repository trait  ← the DB swap point
│   │   │   └── sqlite.rs SQLite implementation (sqlx)
│   │   ├── handlers.rs   HTTP + WebSocket handlers, permissions
│   │   ├── auth.rs       argon2 hashing + bearer-token extractor
│   │   ├── ws.rs         per-user change-event fan-out hub
│   │   ├── files.rs      attachment blobs: FileStore trait, disk + S3 backends
│   │   └── models.rs     domain + payload types
│   └── tests/api.rs    21 integration tests (in-memory SQLite)
└── app/                Flutter
    ├── lib/
    │   ├── api/          Api interface + HTTP/WS client
    │   ├── state/        NotesStore (optimistic + retry queue), AuthStore
    │   ├── widgets/      AnimatedMasonry (custom), note card, dialogs…
    │   ├── screens/      home, editor, login
    │   └── theme.dart    Keep palette, light/dark themes
    └── test/           33 unit + widget tests (FakeApi)
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

Prereqs: Rust (1.85+), Flutter (3.22+).

**Backend** (port 8787):

```sh
cd backend
cargo run
# or with Whisper for audio-note transcription:
docker compose up -d whisper
STICKY_NOTES_WHISPER_URL=http://localhost:9000 cargo run
```

Env vars: `STICKY_NOTES_DB` (SQLite path, default `sticky_notes.db`), `STICKY_NOTES_ADDR` (default `0.0.0.0:8787`), `STICKY_NOTES_UPLOADS` (attachment dir, default `uploads`), `STICKY_NOTES_SEMANTIC=off` (disable embeddings entirely), `STICKY_NOTES_WHISPER_URL` (optional Whisper ASR service — enables audio-note transcription; feature is hidden when unset/unreachable), `STICKY_NOTES_TELEGRAM_API` (Telegram Bot API base, default `https://api.telegram.org` — for self-hosted bot-api servers or proxies). The embedding model (~80 MB) downloads to a local cache on first start.

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

Select your iPhone as the run destination in the toolbar and press ▶️. Xcode gives better error messages for signing or provisioning issues.

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
cd backend && cargo test    # 30 integration tests over the HTTP API
cd app && flutter test      # store/model/widget tests
```

Backend tests run the real router against in-memory SQLite: auth flows, per-user scoping, sharing permission matrix, personal labels on shared notes, checklist history recording, reminders, attachments (multipart upload → serve → delete), trash purge, capabilities reporting, and the audio-note transcription flow (upload → pending → transcript, with a deterministic fake Whisper). Flutter tests cover the optimistic store (drafts, debounce, offline retry queue, 4xx dropping), audio-note creation, feature-availability logic, suggestion ranking, sort/search/views, and widget behavior (checklist cards, masonry drag-reorder, editor lifecycle, find-in-note).

## API sketch

All under `/api`, JSON, `Authorization: Bearer <token>` (from `/auth/register` or `/auth/login`).

| Endpoint | Purpose |
| --- | --- |
| `POST /auth/register` · `/auth/login` · `/auth/logout`, `GET /auth/me` | Accounts & sessions |
| `GET/POST /notes`, `GET/PATCH/DELETE /notes/{id}` | Notes (PATCH is partial; `reminder_at: null` clears) |
| `POST /notes/reorder` | Persist drag order (renumbers the given ids) |
| `POST /notes/{id}/collaborators`, `DELETE /notes/{id}/collaborators/{user}` | Sharing |
| `POST /notes/{id}/attachments`, `DELETE /attachments/{id}`, `GET /files/{id}` | Images (files are served unauthenticated by unguessable UUID so `<img>` tags work) |
| `GET/POST /labels`, `PATCH/DELETE /labels/{id}` | Labels (per-user) |
| `GET /checklist-history` | Checked-off item texts, most used first (typing suggestions) |
| `GET /search?q=…` | Semantic search: ranked `{note_id, score}` (503 when disabled) |
| `POST /notes/{id}/transcribe` | Re-run Whisper on an audio note's clip (retry; 503 when disabled) |
| `GET /capabilities` | Which optional services are on: `{semantic_search, audio_transcription}` (unauthenticated) |
| `GET/PUT /settings` | Per-user settings document (opaque JSON, ≤16 KB) |
| `POST /notify/test` | Send a test notification through the channels in the body (`ntfy_url`, `telegram_bot_token`, …) — `{ok, error?}` |
| `GET /ws?token=…` | WebSocket: `{"type":"notes_changed"}` pushes (notes *and* settings) |

## Design notes & trade-offs

- **Co-editing is last-write-wins** at note granularity (no CRDT). The WS nudge keeps everyone fresh; a reorder mid-drag from another device is never committed as your drag.
- **Pin/archive/order are shared** on a shared note (Keep makes them per-user; kept global for simplicity).
- Client-generated UUIDs let notes be created offline and synced later; the server accepts them idempotently (409 on reuse).
- Checklist history records on the *check-off* transition, credited to whoever checked it, capped at 500 entries per user.
