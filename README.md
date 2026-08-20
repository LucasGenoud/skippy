# Skippy

Skippy is a cross-platform notes app with a Flutter client and a Rust/axum
backend. It supports web, iOS, Android, macOS, and Windows, with SQLite
persistence and optimistic, offline-capable edits.

## Features

- Text, Markdown, checklist, audio, and attachment notes
- Grid, list, and kanban board views with drag-to-reorder
- Workspaces, labels, stages, archive, trash, time and location reminders,
  search, and exports
- Reminders on a whole note or on a single checklist item, pushed through ntfy,
  Telegram, or email
- Sharing, public read-only links, live sync, and version history
- Optional self-hosted Whisper transcription, Tesseract image text recognition,
  and OpenAI-compatible embeddings
- Optional LLM features: automatic labels, note editing, and notes chat
- Dark mode, responsive layouts, keyboard shortcuts, share-sheet intake, and
  home-screen widgets

## Screenshots

<table>
  <tr>
    <td><img src="docs/screenshots/skippy-desktop-masonry.png" alt="Skippy desktop masonry notes grid with one colored card" width="100%"></td>
    <td><img src="docs/screenshots/skippy-desktop-board-features.png" alt="Skippy desktop board mode" width="100%"></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/skippy-desktop-search-features.png" alt="Skippy desktop note search" width="100%"></td>
    <td><img src="docs/screenshots/skippy-desktop-markdown-edit.png" alt="Skippy desktop Markdown note editor" width="100%"></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/skippy-android-home-mockup.png" alt="Skippy Android Pixel emulator notes grid" width="100%"></td>
    <td><img src="docs/screenshots/skippy-iphone-editor-mockup.png" alt="Skippy iPhone card editor" width="100%"></td>
  </tr>
</table>

On Android and iOS, a card is archived by swiping it sideways in the grid,
either way. The panel revealed behind it warms to the accent as the card passes
the point where letting go acts, and the notification that follows carries an
Undo. The same swipe in the archive puts a note back. Board cards keep the
gesture for paging between columns.

On Android and iOS, adding an image offers the camera alongside the photo
library, so a receipt or a whiteboard goes straight from the lens onto a note.
Uploaded images are read for text when an OCR service is configured, so that
photo is found again by the words in it. Recognition runs in the background,
feeds both keyword and semantic search, and never blocks the upload.

On Android and iOS, Settings can hold personal saved places such as Home or
Work, each pinned on a map with the radius that counts as being there. A note
can then raise a notification when the device arrives at or leaves one of those
places, even while Skippy is closed, either once or on every visit. Location
reminders require notification and background-location permission; saved
coordinates are user settings and are never exposed to note collaborators. Map
tiles come from OpenStreetMap and are only fetched while the place editor is
open.

A checklist row can carry a reminder of its own, set from the bell beside it,
with the same one-shot or repeating options a note reminder has. Ticking the row
off cancels its reminder, and so does deleting the row: an alarm outlives
neither. Item reminders are shared with everyone who can see the note, are
written one row at a time so two devices editing the same list never overwrite
each other, and reach both the server's push channels and the device's own
alarms. Setting one is not an edit: it does not change the note's "Edited"
stamp, capture a version, or re-run automatic labeling.

The app is deliberately out of scope for drawings, calendar sync, and
CRDT-style collaboration. Collaboration uses last-write-wins at note level.

## Quick start with Docker

Choose a Compose file:

```sh
docker compose -f docker-compose.minimal.yml up -d
docker compose -f docker-compose.simple.yml up -d
docker compose -f docker-compose.all.yml up -d
```

`docker-compose.minimal.yml` runs Skippy with disk storage.
`docker-compose.simple.yml` adds Whisper and Tesseract while keeping disk
storage. `docker-compose.all.yml` is the full stack and uses Garage for S3
storage.

For the full stack, generate credentials before the first start. Copy each
output line into `.env`:

```sh
access_key="GK$(openssl rand -hex 16)"
secret_key="$(openssl rand -hex 32)"
printf 'GARAGE_RPC_SECRET='; openssl rand -hex 32
printf 'S3_ACCESS_KEY=%s\n' "$access_key"
printf 'GARAGE_DEFAULT_ACCESS_KEY=%s\n' "$access_key"
printf 'S3_SECRET_KEY=%s\n' "$secret_key"
printf 'GARAGE_DEFAULT_SECRET_KEY=%s\n' "$secret_key"
```

Keep `.env` private. Keep matching `S3_*` and `GARAGE_DEFAULT_*`
values unchanged after Garage setup.

Open <http://localhost:8787>. The image builds the Flutter web app and Rust
server. SQLite data persists in the `app_data` volume. Disk-storage deployments
also keep attachments there; the full stack stores attachments in Garage.

The current database schema has no in-place migration path. Start with a new
database when installing a schema revision.

The full stack requires `GARAGE_RPC_SECRET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`,
`GARAGE_DEFAULT_ACCESS_KEY`, and
`GARAGE_DEFAULT_SECRET_KEY` in `.env`; no default credentials are provided.
The S3 access and secret values must match their corresponding Garage values.
Choose one attachment backend per deployment; switching does not migrate
existing blobs.

See [Deployment](docs/DEPLOY.md) for production and optional GPU Whisper
settings.

## Configuration

All server settings are optional. The defaults work for a local Docker
deployment.

| Variable | Default | Purpose |
| --- | --- | --- |
| `ADDR` | `0.0.0.0:8787` | Listen address |
| `DB` | `sticky_notes.db` | SQLite path (`/data/sticky_notes.db` in Docker) |
| `UPLOADS` | `uploads` | Disk attachment directory |
| `PUBLIC_URL` | unset | Browser API URL and allowed CORS origin |
| `STORAGE` | `disk` | `disk` or `s3` |
| `WHISPER_URL` | unset | Whisper service URL; Docker sets it to `http://whisper:9000` |
| `OCR_URL` | unset | Tesseract service URL; enables text search inside images. Docker sets it to `http://tesseract:8884` |
| `OCR_LANGUAGES` | `eng` | Tesseract language packs, e.g. `fra+eng`; the pack must exist in the OCR image |
| `EMBED_URL` | unset | OpenAI-compatible embeddings URL; enables semantic search and chat |
| `EMBED_MODEL` | `bge-m3` | Embedding model |
| `EMBED_API_KEY` | unset | Embedding service bearer token |
| `S3_URL` | unset | Required when storage is `s3` |
| `S3_ACCESS_KEY` | unset | Required when storage is `s3` |
| `S3_SECRET_KEY` | unset | Required when storage is `s3` |
| `S3_REGION` | `garage` | S3 signing region |
| `S3_BUCKET_PREFIX` | `sticky-notes-` | Prefix for per-user buckets |
| `ALLOW_PRIVATE_USER_ENDPOINTS` | off | Allow user-configured AI/notification endpoints (including a LAN mail server) on private networks |
| `UNFURL_ALLOW_PRIVATE` | off | Allow link previews for private/loopback hosts |
| `TELEGRAM_API` | `https://api.telegram.org` | Telegram API base URL |

LLM providers are configured per user in Settings. Setting any of these
env vars overrides that user setting and locks the field in the app:

```text
LLM_BASE_URL
LLM_API_KEY       # secret; never returned to the app
LLM_MODEL
LLM_LABELING      # true/false
LLM_CHAT          # true/false
LLM_WRITING       # true/false
```

Email reminders work the same way. A deployment with its own mail server pins
it once, and each user then only fills in the address to send to:

```text
SMTP_HOST
SMTP_PORT         # optional; defaults to 465, 587, or 25 to match SMTP_SECURITY
SMTP_SECURITY     # tls (default), starttls, or none
SMTP_USERNAME
SMTP_PASSWORD     # secret; never returned to the app
SMTP_FROM         # defaults to SMTP_USERNAME
```

Leave a variable unset to keep that field the user's own. The override is
applied server-side on every read, so it holds regardless of what a client
stores.

### Docker Compose environment variables

This table lists every variable passed by the Compose variants. `host/.env`
values come from the shell or `.env`.

| Service | Variable | Compose value or host input | Purpose |
| --- | --- | --- | --- |
| server | `PUBLIC_URL` | host/.env; empty by default | Public browser URL and allowed CORS origin. |
| server | `EMBED_URL` | host/.env; empty by default | OpenAI-compatible embeddings endpoint. |
| server | `EMBED_MODEL` | host/.env; `bge-m3` by default | Embedding model name. |
| server | `EMBED_API_KEY` | host/.env; empty by default | Bearer token for the embeddings endpoint. |
| server | `WHISPER_URL` | simple/all: `http://whisper:9000` | Bundled Whisper service URL. |
| server | `OCR_URL` | simple/all: `http://tesseract:8884` | Bundled Tesseract service URL. |
| server | `OCR_LANGUAGES` | simple/all; host/.env; `eng` by default | Tesseract language packs used to read images. |
| server | `STORAGE` | minimal/simple: `disk`; all: `s3` | Attachment backend. |
| server | `S3_URL` | all: `http://garage:3900` | Bundled Garage S3 endpoint. |
| server | `S3_REGION` | all: `garage` | S3 signing region. |
| server | `S3_ACCESS_KEY` | all; required host/.env value | S3 access key; must match Garage’s default access key. |
| server | `S3_SECRET_KEY` | all; required host/.env value | S3 secret; must match Garage’s default secret. |
| server | `ALLOW_PRIVATE_USER_ENDPOINTS` | host/.env; empty by default | Allows user-configured AI/notification URLs on private networks. |
| server (optional) | `LLM_BASE_URL` | host/.env; empty by default | Server-managed LLM base URL; locks the field in the app. |
| server (optional) | `LLM_API_KEY` | host/.env; empty by default | Server-managed LLM API key; never returned to the app. |
| server (optional) | `LLM_MODEL` | host/.env; empty by default | Server-managed LLM model. |
| server (optional) | `LLM_LABELING` | host/.env; empty by default | Forces automatic labeling on or off. |
| server (optional) | `LLM_CHAT` | host/.env; empty by default | Forces notes chat on or off. |
| server (optional) | `LLM_WRITING` | host/.env; empty by default | Forces AI note editing on or off. |
| server (optional) | `SMTP_HOST` | host/.env; empty by default | Server-managed mail server for email reminders; locks the field in the app. |
| server (optional) | `SMTP_PORT` | host/.env; empty by default | Mail server port; blank follows `SMTP_SECURITY`. |
| server (optional) | `SMTP_SECURITY` | host/.env; `tls` by default | `tls`, `starttls`, or `none`. |
| server (optional) | `SMTP_USERNAME` | host/.env; empty by default | Mail account to authenticate as. |
| server (optional) | `SMTP_PASSWORD` | host/.env; empty by default | Mail account password; never returned to the app. |
| server (optional) | `SMTP_FROM` | host/.env; empty by default | Address reminders are sent from. |
| whisper | `ASR_MODEL` | `base` (`large-v3` for GPU) | Whisper model to load. |
| whisper | `ASR_ENGINE` | `faster_whisper` | Whisper inference engine. |
| whisper (GPU) | `ASR_DEVICE` | `cuda` | Runs inference on an NVIDIA GPU. |
| whisper (GPU) | `ASR_QUANTIZATION` | `float16` | GPU model quantization. |
| garage | `GARAGE_RPC_SECRET` | required host/.env value | Garage cluster RPC secret. |
| garage | `GARAGE_DEFAULT_ACCESS_KEY` | required host/.env value | Default Garage access key; must match the server’s S3 access key. |
| garage | `GARAGE_DEFAULT_SECRET_KEY` | required host/.env value | Default Garage secret key; must match the server’s S3 secret key. |
| garage | `GARAGE_DEFAULT_BUCKET` | `sticky-notes-default` | Bucket created for Garage's single-node mode. |

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
flutter run -d chrome --dart-define=API_BASE=http://localhost:8787
flutter run -d macos --dart-define=API_BASE=http://localhost:8787
flutter run -d windows --dart-define=API_BASE=http://localhost:8787
flutter run -d <ios-or-android-id> --dart-define=API_BASE=http://localhost:8787
```

Release builds default to `https://skippy-notes.com`. For local development,
pass the `API_BASE` define shown above. On an Android emulator use
`http://10.0.2.2:8787`; on a physical device use the host machine's LAN IP.
The login screen can also save and switch between server URLs.

For a single-binary web deployment:

```sh
cd app && flutter build web --release
cd ../backend && cargo run
```

The backend serves `app/build/web` when it contains `index.html`.

## Mobile release builds

Update the version in `app/pubspec.yaml`, then run from `app/`:

```sh
flutter pub get
flutter build appbundle --release --dart-define=API_BASE=https://notes.example.com
flutter build ipa --release --dart-define=API_BASE=https://notes.example.com
```

The Android App Bundle is written to
`app/build/app/outputs/bundle/release/app-release.aab`; an APK can be built with
`flutter build apk --release`. The iOS archive and IPA are written under
`app/build/ios/`.

Android release builds use a private upload keystore configured through the
ignored `app/android/key.properties` file. Before building a Play Store
release, create it with the following values (do not commit or share it):

```text
storePassword=<keystore password>
keyPassword=<key password>
keyAlias=skippy-upload
storeFile=signing/skippy-upload.jks
```

Keep the corresponding keystore in the ignored `app/android/signing/`
directory and back it up securely. iOS distribution requires macOS/Xcode
signing with an Apple team and provisioning profile.

## Desktop release builds

```sh
flutter build macos --release --dart-define=API_BASE=https://notes.example.com
flutter build windows --release --dart-define=API_BASE=https://notes.example.com
```

`Skippy.app` is written to `app/build/macos/Build/Products/Release/`, and the
Windows build to `app/build/windows/x64/runner/Release/`. Each has to be built
on its own operating system.

The macOS app runs sandboxed. `macos/Runner/*.entitlements` grant outgoing
network access (the backend, map tiles, the configured LLM), the microphone for
audio notes, and read/write on files the user picks in a dialog. Shipping it
outside your own machines also needs Developer ID signing and notarization.

Two things differ from mobile on the desktop:

- Exports and attachment downloads open a save dialog rather than the share
  sheet, since there is a filesystem to aim at.
- Audio notes record and transcribe everywhere, but playback needs `just_audio`,
  which has no Windows implementation. The Windows build shows a short note in
  place of the player instead of a dead play button.

The features that only exist on a phone stay switched off by platform checks:
home-screen widgets, location reminders, the share-sheet intake, and the camera
option when adding an image.

## User backups

Settings lets each user create and restore a portable backup of their own
workspaces. This remains separate from the server and Docker deployment.

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
- `/notes/{id}/versions`, `/notes/{id}/attachments`,
  `/notes/{id}/item-reminders/{item_id}`, and sharing endpoints
- `/search`, `/chat`, `/settings`, `/unfurl`, and `/ws`
- `/health` and `/capabilities` for service status

Attachments are served through signed, expiring URLs. Optional search,
transcription, image text recognition, and LLM routes report unavailable
services instead of requiring them at startup.
