# Set up Skippy

Skippy serves the web app and API from one container. Open
<http://localhost:8787> after starting any example below. A named volume keeps
notes and attachments across container restarts.

## 1. Basic: one container

Save this as `compose.yaml` in an empty directory:

```yaml
services:
  skippy:
    image: ghcr.io/lucasgenoud/skippy:latest
    ports:
      - "8787:8787"
    volumes:
      - skippy_data:/data
    restart: unless-stopped

volumes:
  skippy_data:
```

Run `docker compose up -d`. **No environment variables or `.env` file are
needed.** SQLite and uploaded files live in `skippy_data`. Transcription, image
text recognition, semantic search, and AI are optional and off by default.

## 2. Add Whisper and Tesseract

The repository has the service definitions and their connection URLs. Clone
it, then start the base and simple overlays together:

```sh
git clone https://github.com/LucasGenoud/skippy.git
cd skippy
docker compose -f docker-compose.yml -f docker-compose.simple.yml up -d server whisper tesseract
```

Whisper transcribes audio; Tesseract reads text in uploaded images. The server
uses `http://whisper:9000` and `http://tesseract:8884` on the Compose network.
No `.env` file is required. To change the OCR language, set `OCR_LANGUAGES`
in `.env` to codes installed in the Tesseract image.

## 3. Full stack: add Garage and configure the optional services

Use the same repository. The third overlay adds Garage for S3-compatible
attachment storage; the app still keeps its SQLite database in `app_data`.
Create `.env` next to the Compose files. The five Garage/S3 secret entries
must have real values; the other entries are optional:

```dotenv title=".env"
# Browser address when serving behind a public reverse proxy; blank for localhost.
PUBLIC_URL=

# External OpenAI-compatible embeddings service (not included in these containers).
EMBED_URL=
EMBED_MODEL=bge-m3
EMBED_API_KEY=

# Optional server-managed AI settings.
ALLOW_PRIVATE_USER_ENDPOINTS=
LLM_BASE_URL=
LLM_API_KEY=
LLM_MODEL=
LLM_LABELING=
LLM_CHAT=
LLM_WRITING=

# Optional server-managed email settings.
SMTP_HOST=
SMTP_PORT=
SMTP_SECURITY=
SMTP_USERNAME=
SMTP_PASSWORD=
SMTP_FROM=

# OCR and optional documentation site.
OCR_LANGUAGES=eng
DOCS_PORT=8123

# Required for Garage. Use the same access key and secret in each matching pair.
GARAGE_RPC_SECRET=replace-with-random-hex
S3_ACCESS_KEY=replace-with-garage-access-key
GARAGE_DEFAULT_ACCESS_KEY=replace-with-the-same-access-key
S3_SECRET_KEY=replace-with-garage-secret-key
GARAGE_DEFAULT_SECRET_KEY=replace-with-the-same-secret-key
```

Generate values to paste into the last five lines:

```sh
access_key="GK$(openssl rand -hex 16)"
secret_key="$(openssl rand -hex 32)"
printf 'GARAGE_RPC_SECRET='; openssl rand -hex 32
printf 'S3_ACCESS_KEY=%s\nGARAGE_DEFAULT_ACCESS_KEY=%s\n' "$access_key" "$access_key"
printf 'S3_SECRET_KEY=%s\nGARAGE_DEFAULT_SECRET_KEY=%s\n' "$secret_key" "$secret_key"
```

Start the four application services:

```sh
docker compose -f docker-compose.yml -f docker-compose.simple.yml -f docker-compose.all.yml up -d server whisper tesseract garage
```

Garage starts with one node and creates its default bucket automatically.
`garage.toml` from the repository must stay beside the Compose files. Leave
the optional settings blank until you have an external embedding or AI service
or an SMTP server; Whisper and Tesseract work without them.

## Install on a device

These commands install Skippy directly from a development machine. They do not
publish it to an app store.

### Android

Enable USB debugging, connect the device, then run:

```sh
cd app
flutter devices
flutter run --release -d <android-device-id>
```

### iPhone or iPad

Use macOS with Xcode, enable Developer Mode on the device, and select your
Apple signing team in `app/ios/Runner.xcworkspace`. Then connect the device:

```sh
cd app
flutter devices
flutter run --release -d <ios-device-id>
```

An app installed with a free Apple developer account needs refreshing every
seven days.

## Documentation site

The repository's base Compose file also defines the documentation container:

```sh
docker compose up -d docs
```

Open <http://localhost:8123>, or change `DOCS_PORT` in `.env`.

## Environment variables

Defaults below describe the published Docker image and repository Compose
files. **Unset** means no value is configured. Empty optional values in `.env`
leave their feature disabled or editable per user. `DB`, `UPLOADS`, `WEB`, and
`ADDR` are image defaults; the supplied Compose files do not forward them from
`.env`. Set them under the server's `environment:` section if you need to
override them.

| Variable | What it does | Default |
| --- | --- | --- |
| `PUBLIC_URL` | Public app URL for browser configuration and reset links. | Unset |
| `ADDR` | Server listen address inside the container. | `0.0.0.0:8787` |
| `DB` | SQLite database path. | `/data/sticky_notes.db` |
| `UPLOADS` | Local attachment directory. | `/data/uploads` |
| `WEB` | Bundled web app directory. | `/app/web` |
| `STORAGE` | Attachment store: `disk` or `s3`. | `disk` |
| `S3_URL` | S3 endpoint when using `s3`. | Unset; full overlay uses `http://garage:3900` |
| `S3_REGION` | S3 region. | `garage` |
| `S3_ACCESS_KEY` | S3 access key; required for `s3`. | Unset |
| `S3_SECRET_KEY` | S3 secret key; required for `s3`. | Unset |
| `S3_BUCKET_PREFIX` | Prefix for attachment buckets. | `sticky-notes-` |
| `GARAGE_RPC_SECRET` | Garage node secret; required in the full overlay. | Unset |
| `GARAGE_DEFAULT_ACCESS_KEY` | Garage key; match `S3_ACCESS_KEY`. | Unset |
| `GARAGE_DEFAULT_SECRET_KEY` | Garage secret; match `S3_SECRET_KEY`. | Unset |
| `GARAGE_DEFAULT_BUCKET` | Garage's initial bucket. | `sticky-notes-default` |
| `WHISPER_URL` | Audio transcription endpoint. | Unset; simple overlay uses `http://whisper:9000` |
| `ASR_MODEL` | Whisper model size in the bundled service. | `base` in the simple overlay |
| `ASR_ENGINE` | Whisper inference engine in the bundled service. | `faster_whisper` in the simple overlay |
| `OCR_URL` | Image text recognition endpoint. | Unset; simple overlay uses `http://tesseract:8884` |
| `OCR_LANGUAGES` | Tesseract language codes, such as `eng` or `fra+eng`. | `eng` |
| `EMBED_URL` | OpenAI-compatible embeddings API base URL; enables search. | Unset |
| `EMBED_MODEL` | Embedding model name. | `bge-m3` |
| `EMBED_API_KEY` | Embeddings API key, if needed. | Unset |
| `ALLOW_PRIVATE_USER_ENDPOINTS` | Allow user-configured AI, ntfy, or mail on private hosts. | Off |
| `LLM_BASE_URL` | Server-managed AI API base URL. | Unset |
| `LLM_API_KEY` | Server-managed AI API key. | Unset |
| `LLM_MODEL` | Server-managed AI model. | Unset |
| `LLM_LABELING` | Pin automatic AI labeling (`true`/`false`). | Unset; per-user setting |
| `LLM_CHAT` | Pin notes chat (`true`/`false`). | Unset; per-user setting |
| `LLM_WRITING` | Pin AI writing (`true`/`false`). | Unset; per-user setting |
| `SMTP_HOST` | Server-managed mail host. | Unset |
| `SMTP_PORT` | Server-managed mail port. | Unset |
| `SMTP_SECURITY` | Server-managed mail security mode. | Unset |
| `SMTP_USERNAME` | Server-managed mail login. | Unset |
| `SMTP_PASSWORD` | Server-managed mail password. | Unset |
| `SMTP_FROM` | Server-managed sender address. | Unset |
| `DOCS_PORT` | Host port for the optional documentation site. | `8123` |
| `UNFURL_ALLOW_PRIVATE` | Allow link previews from private hosts; set in server environment. | Off |
| `TELEGRAM_API` | Telegram Bot API base URL; set in server environment. | `https://api.telegram.org` |
