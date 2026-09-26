# Skippy

Skippy is a self-hosted notes app for the web, iOS, Android, macOS, and
Windows. It supports offline work, collaboration, and optional AI services.

The full documentation is an [MkDocs Material site](mkdocs-material/docs/index.md). Start
it with:

```sh
docker compose up -d docs
```

Open <http://localhost:8123>. The app itself remains available at
<http://localhost:8787>.

## Screenshots

<table>
  <tr>
    <td><a href="mkdocs-material/docs/assets/screenshots/skippy-desktop-masonry.png"><img src="mkdocs-material/docs/assets/screenshots/skippy-desktop-masonry.png" alt="Masonry notes" width="420"></a></td>
    <td><a href="mkdocs-material/docs/assets/screenshots/skippy-desktop-board-features.png"><img src="mkdocs-material/docs/assets/screenshots/skippy-desktop-board-features.png" alt="Kanban board" width="420"></a></td>
  </tr>
  <tr>
    <td><a href="mkdocs-material/docs/assets/screenshots/skippy-desktop-editor.png"><img src="mkdocs-material/docs/assets/screenshots/skippy-desktop-editor.png" alt="Desktop note editor" width="420"></a></td>
    <td><a href="mkdocs-material/docs/assets/screenshots/skippy-mobile-overview.png"><img src="mkdocs-material/docs/assets/screenshots/skippy-mobile-overview.png" alt="Mobile board view" width="420"></a></td>
  </tr>
  <tr>
    <td><a href="mkdocs-material/docs/assets/screenshots/skippy-mobile-editor.png"><img src="mkdocs-material/docs/assets/screenshots/skippy-mobile-editor.png" alt="Mobile note editor" width="420"></a></td>
  </tr>
</table>

## Features

- Text, Markdown, checklist, audio, image, and attachment notes
- Nested checklists with up to three levels, reminders, labels, and links
- Workspaces, collections, masonry, list, and Kanban board layouts
- Shared smart views, live sync, collaboration, version history, archive, and trash
- Offline edits with automatic synchronization when the connection returns
- Semantic search, optional transcription, OCR, and OpenAI-compatible AI tools
- Share-sheet intake, keyboard shortcuts, dark mode, exports, and home-screen widgets

## Docker deployment

Skippy is published as `ghcr.io/lucasgenoud/skippy:latest`. The smallest
deployment is one service and one volume:

```yaml
services:
  server:
    image: ghcr.io/lucasgenoud/skippy:latest
    ports:
      - "8787:8787"
    volumes:
      - app_data:/data
    restart: unless-stopped

volumes:
  app_data:
```

The repository includes three Compose files. Each is a complete stack on its
own; pick one:

```sh
docker compose up -d
docker compose -f docker-compose.simple.yml up -d
docker compose -f docker-compose.all.yml up -d
```

`docker-compose.yml` is Skippy with disk storage. `docker-compose.simple.yml`
adds Whisper and Tesseract. `docker-compose.all.yml` adds those plus Garage for
S3-compatible attachment storage, and needs the Garage secrets in `.env`. Each
file also defines the documentation site on port `8123`:

```sh
docker compose up -d docs
```

Open the app at <http://localhost:8787> and the documentation at
<http://localhost:8123>. SQLite data and disk attachments persist in the
`app_data` volume.

## Configuration

The defaults work for a local deployment. Set these variables in `.env` when
you need optional services or a public URL:

| Variable | Purpose |
| --- | --- |
| `ADDR` | Listen address; defaults to `0.0.0.0:8787` |
| `DB` | SQLite database path |
| `UPLOADS` | Disk attachment directory |
| `PUBLIC_URL` | Public browser URL and password-reset link base |
| `STORAGE` | `disk` or `s3` attachment storage |
| `WHISPER_URL` | Optional transcription service |
| `OCR_URL` | Optional image text recognition service |
| `EMBED_URL` | Optional OpenAI-compatible embeddings endpoint |
| `EMBED_MODEL` | Embedding model name |
| `EMBED_API_KEY` | Embedding service token |
| `S3_URL` | S3-compatible endpoint when `STORAGE=s3` |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | S3 credentials |
| `LLM_BASE_URL` / `LLM_API_KEY` / `LLM_MODEL` | Optional server-managed AI provider |
| `SMTP_HOST` / `SMTP_USERNAME` / `SMTP_PASSWORD` | Optional email reminders and password reset |

Unset optional variables to keep those features disabled. Secret values stay in
the server environment and are never returned to the client. See
[Set up Skippy](mkdocs-material/docs/setup.md) for the complete Compose and
environment-variable reference.

## Mobile installation

Android needs more testers before a public release. The iOS app is not in the
App Store yet. Both apps can be installed directly; direct iOS installs must
be refreshed every seven days.

For local device builds, use the server address reachable from the device:

```sh
cd app
flutter pub get
flutter run -d <android-or-ios-device> \
  --dart-define=API_BASE=http://192.168.1.10:8787
```

Use `http://10.0.2.2:8787` for an Android emulator. A physical device needs
the host computer's LAN address, and the server must accept connections on
that network.

## Local development

Prerequisites are Rust 1.88+ and Flutter 3.44+ / Dart 3.12+.

```sh
cd backend
cargo run

cd ../app
flutter run -d chrome --dart-define=API_BASE=http://localhost:8787
```

For a single-binary web deployment, build the Flutter web client first. The
backend serves `app/build/web` when it contains `index.html`:

```sh
cd app && flutter build web --release
cd ../backend && cargo run
```

## Tests

```sh
cd backend && cargo test
cd backend && cargo clippy --all-targets -- -D warnings
cd app && flutter test
cd app && flutter analyze
```

## API overview

Authenticated JSON endpoints live under `/api`. The main groups are:

- `/auth`, `/workspaces`, `/notes`, `/labels`, `/stages`, and collections
- `/search`, `/chat`, `/settings`, `/unfurl`, and `/ws`
- `/notes/{id}/versions`, `/notes/{id}/attachments`, and item reminders
- `/health` and `/capabilities` for service status

Attachments use signed, expiring URLs. Optional search, transcription, OCR,
and AI routes report unavailable services instead of preventing startup.
