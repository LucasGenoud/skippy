# Skippy

Skippy is a cross-platform notes app with a Flutter client and a Rust/axum
backend. It supports web, iOS, and Android, with SQLite persistence and
optimistic, offline-capable edits.

## Features

- Text, Markdown, checklist, audio, and attachment notes
- Grid, list, and kanban board views with drag-to-reorder
- Workspaces, labels, stages, archive, trash, reminders, search, and exports
- Sharing, public read-only links, live sync, and version history
- Optional self-hosted Whisper transcription and OpenAI-compatible embeddings
- Optional LLM features: automatic labels, note editing, and notes chat
- Dark mode, responsive layouts, keyboard shortcuts, share-sheet intake, and
  home-screen widgets

The app is deliberately out of scope for drawings, OCR, calendar sync, and
CRDT-style collaboration. Collaboration uses last-write-wins at note level.

## Quick start with Docker

```sh
docker compose up -d
```

Open <http://localhost:8787>. The image builds the Flutter web app and Rust
server. The stack also starts Whisper for audio transcription and Garage for
optional S3-compatible attachment storage. SQLite data and attachments persist
in the `app_data` volume.

The current database schema has no in-place migration path. Start with a new
database or restore a system backup created with this schema version.

Disk storage is the default. To use the bundled Garage service instead:

```sh
STICKY_NOTES_STORAGE=s3 docker compose up -d
```

Set `GARAGE_RPC_SECRET`, `STICKY_NOTES_S3_ACCESS_KEY`, and
`STICKY_NOTES_S3_SECRET_KEY` in `.env` before exposing the stack beyond a
trusted LAN. Choose one attachment backend per deployment; switching does not
migrate existing blobs.

To run only the supporting services during local backend development:

```sh
docker compose up -d whisper garage
```

See [Deployment](docs/DEPLOY.md) for production, backups, and the optional GPU
Whisper overlay.

## Configuration

All server settings are optional. The defaults work for a local Docker
deployment.

| Variable | Default | Purpose |
| --- | --- | --- |
| `STICKY_NOTES_ADDR` | `0.0.0.0:8787` | Listen address |
| `STICKY_NOTES_DB` | `sticky_notes.db` | SQLite path (`/data/sticky_notes.db` in Docker) |
| `STICKY_NOTES_UPLOADS` | `uploads` | Disk attachment directory |
| `STICKY_NOTES_PUBLIC_URL` | unset | Browser API URL and allowed CORS origin |
| `STICKY_NOTES_STORAGE` | `disk` | `disk` or `s3` |
| `STICKY_NOTES_WHISPER_URL` | unset | Whisper service URL; Docker sets it to `http://whisper:9000` |
| `STICKY_NOTES_EMBED_URL` | unset | OpenAI-compatible embeddings URL; enables semantic search and chat |
| `STICKY_NOTES_EMBED_MODEL` | `bge-m3` | Embedding model |
| `STICKY_NOTES_EMBED_API_KEY` | unset | Embedding service bearer token |
| `STICKY_NOTES_S3_URL` | unset | Required when storage is `s3` |
| `STICKY_NOTES_S3_ACCESS_KEY` | unset | Required when storage is `s3` |
| `STICKY_NOTES_S3_SECRET_KEY` | unset | Required when storage is `s3` |
| `STICKY_NOTES_S3_REGION` | `garage` | S3 signing region |
| `STICKY_NOTES_S3_BUCKET_PREFIX` | `sticky-notes-` | Prefix for per-user buckets |
| `STICKY_NOTES_ALLOW_PRIVATE_USER_ENDPOINTS` | off | Allow user-configured AI/notification URLs on private networks |
| `STICKY_NOTES_UNFURL_ALLOW_PRIVATE` | off | Allow link previews for private/loopback hosts |
| `STICKY_NOTES_TELEGRAM_API` | `https://api.telegram.org` | Telegram API base URL |

Server-managed LLM fields override and lock the corresponding user setting:

```text
STICKY_NOTES_LLM_BASE_URL
STICKY_NOTES_LLM_API_KEY       # secret; never returned to the app
STICKY_NOTES_LLM_MODEL
STICKY_NOTES_LLM_LABELING
STICKY_NOTES_LLM_CHAT
STICKY_NOTES_LLM_WRITING
```

The compose file includes the same settings where they are useful. Whisper
also accepts `ASR_MODEL` and `ASR_ENGINE`; the GPU overlay adds
`ASR_DEVICE` and `ASR_QUANTIZATION`. Garage uses `GARAGE_RPC_SECRET`,
`GARAGE_DEFAULT_ACCESS_KEY`, `GARAGE_DEFAULT_SECRET_KEY`, and
`GARAGE_DEFAULT_BUCKET`.

The Flutter app uses build-time defines rather than runtime environment
variables:

```sh
--dart-define=API_BASE=http://localhost:8787
--dart-define=SKIPPY_CLIENT_VERSION=<version>
```

## Local development

Prerequisites: Rust 1.88+ and Flutter 3.44+ / Dart 3.12+.

Run the backend:

```sh
cd backend
cargo run
```

Run the Flutter app:

```sh
cd app
flutter run -d chrome
flutter run -d <ios-or-android-id>
```

The default backend is `http://localhost:8787`. On an Android emulator use
`http://10.0.2.2:8787`; on a physical device use the host machine's LAN IP.
The login screen can also save and switch between server URLs.

For a single-binary web deployment:

```sh
cd app && flutter build web --release
cd ../backend && cargo run
```

The backend serves `app/build/web` when it contains `index.html`.

## Backups

User backups are available in Settings. Operators can create a complete
instance backup containing the database and referenced attachment bytes:

```sh
cd backend
cargo run -- system-backup /safe/path/skippy-20260729-030000.skb
```

Docker mounts `./backups` at `/backups` by default. Restore offline:

```sh
docker compose stop server
docker compose run --rm --no-deps server \
  /app/sticky-notes-server system-restore \
  /backups/skippy-20260729-030000.skb --confirm
docker compose up -d server
```

Restore validates the archive, creates a pre-restore safety backup, then
replaces the database and attachment state. Copy backups off the host and set
retention separately.

## Tests

```sh
cd backend && cargo test
cd backend && cargo clippy --all-targets -- -D warnings
cd app && flutter test
cd app && flutter analyze
```

Backend tests use in-memory SQLite and deterministic service fakes. Flutter
tests use `FakeApi` and cover models, stores, offline sync, settings, and key
widget flows.

## Repository layout

```text
backend/  Rust API, SQLite repository, file storage, optional services
app/      Flutter client, state stores, screens, widgets, platform adapters
docs/     Deployment notes and historical design documents
```

The main extension seams are the `Repository` in
[`backend/src/store/mod.rs`](backend/src/store/mod.rs) and the `FileStore` in
[`backend/src/files.rs`](backend/src/files.rs). SQLite and local disk are the
defaults; S3-compatible storage is also supported.

## API overview

Authenticated JSON endpoints live under `/api`. The main groups are:

- `/auth`, `/workspaces`, `/notes`, `/labels`, and `/stages`
- `/notes/{id}/versions`, `/notes/{id}/attachments`, and sharing endpoints
- `/search`, `/chat`, `/settings`, `/unfurl`, and `/ws`
- `/health` and `/capabilities` for service status

Attachments are served through signed, expiring URLs. Optional search,
transcription, and LLM routes report unavailable services instead of requiring
them at startup.
