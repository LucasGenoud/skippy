# Set up Skippy

Skippy runs in Docker. There are three Compose files to choose from. Each one
works on its own, so you only need the one that matches what you want.

| Setup | File | What runs | `.env` file |
| --- | --- | --- | --- |
| [Basic](#basic) | `docker-compose.yml` | Skippy | Not needed |
| [Voice and image text](#voice-and-image-text) | `docker-compose.simple.yml` | Skippy, Whisper, Tesseract | Not needed |
| [Full](#full) | `docker-compose.all.yml` | Skippy, Whisper, Tesseract, Garage | Required |

- **Whisper** turns voice notes into text.
- **Tesseract** reads the text in images, so you can search for it.
- **Garage** stores attachments in S3-compatible storage instead of in the
  Skippy volume.

Once Skippy is running, open <http://localhost:8787> and create an account.
From another device, use port 8787 on your server's address.

## Basic

Create a folder, download the file into it, and start Skippy:

```sh
mkdir skippy && cd skippy
curl -fsSLO https://raw.githubusercontent.com/LucasGenoud/skippy/main/docker-compose.yml
docker compose -f docker-compose.yml up -d server
```

Notes and attachments are saved in the `app_data` volume. They are kept when
the container restarts or updates.

## Voice and image text

This setup adds Whisper and Tesseract. Both are already connected to Skippy,
so there is nothing to configure.

```sh
mkdir skippy && cd skippy
curl -fsSLO https://raw.githubusercontent.com/LucasGenoud/skippy/main/docker-compose.simple.yml
docker compose -f docker-compose.simple.yml up -d server whisper tesseract
```

On the first start, Skippy waits for Whisper to be ready. This can take a
minute or two.

Tesseract reads English by default. To read other languages, create a `.env`
file next to the Compose file, for example:

```dotenv title=".env"
OCR_LANGUAGES=fra+eng
```

## Full

This setup adds Garage to store attachments. Notes stay in Skippy's database
in `app_data`; only attachments go to Garage.

1. Download the file:

    ```sh
    mkdir skippy && cd skippy
    curl -fsSLO https://raw.githubusercontent.com/LucasGenoud/skippy/main/docker-compose.all.yml
    ```

2. Create the Garage keys. Skippy and Garage must share the same access key
   and secret key, so the script writes each one twice. Run it once:

    ```sh
    access_key="GK$(openssl rand -hex 12)"
    secret_key="$(openssl rand -hex 32)"
    cat >> .env <<EOF
    GARAGE_RPC_SECRET=$(openssl rand -hex 32)
    GARAGE_DEFAULT_ACCESS_KEY=$access_key
    GARAGE_DEFAULT_SECRET_KEY=$secret_key
    S3_ACCESS_KEY=$access_key
    S3_SECRET_KEY=$secret_key
    EOF
    ```

    Keep `.env` private. It holds the keys to your attachments.

3. Start the stack:

    ```sh
    docker compose -f docker-compose.all.yml up -d server whisper tesseract garage
    ```

Garage sets itself up on the first start, including the bucket Skippy stores
attachments in.

## Everyday commands

Replace `<file>` with the Compose file you use.

| Task | Command |
| --- | --- |
| Update | `docker compose -f <file> pull`, then run your start command again |
| Stop | `docker compose -f <file> down` (your data is kept) |
| See the logs | `docker compose -f <file> logs -f server` |
| Apply a change to `.env` | Run your start command again |

## Switch to another setup

Keep every setup in the same folder. All three files use the same `app_data`
volume, so your notes and account come with you.

1. Stop the current setup with `docker compose -f <file> down`.
2. Download the new file and start it as shown in its section.

!!! warning "Attachments do not move to or from Garage"

    Basic and Voice and image text store attachments in `app_data`. Full
    stores them in Garage. Skippy does not copy files from one to the other,
    so after a switch, files uploaded before it no longer open. Pick Full
    before you upload files if you want Garage.

## Optional settings

All three files read these settings from the `.env` file in the same folder.
Leave a setting out to keep its feature off, or to let each user set it up in
the app. After a change, run your start command again.

| Setting | What it does |
| --- | --- |
| `PUBLIC_URL` | The address people use to reach Skippy, such as `https://notes.example.com`. Set it when Skippy runs behind a reverse proxy. Password reset emails link to it. |
| `EMBED_URL` | Address of an OpenAI-compatible embeddings API. Turns on semantic search. None of the setups includes one. |
| `EMBED_MODEL` | Embedding model name. Default: `bge-m3`. |
| `EMBED_API_KEY` | Key for the embeddings API, if it needs one. |
| `LLM_BASE_URL`, `LLM_API_KEY`, `LLM_MODEL` | One AI provider for every user. Users cannot change it and never see the key. |
| `LLM_LABELING`, `LLM_CHAT`, `LLM_WRITING` | `true` or `false`. Turns automatic labeling, notes chat, or AI writing on or off in every workspace. When unset, each workspace owner decides. |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURITY`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM` | One mail server for every user, for email reminders and password resets. Users then only enter their own address. |
| `ALLOW_PRIVATE_USER_ENDPOINTS` | Lets users point their own AI, ntfy, or mail settings at hosts on your private network. Off by default. |
| `OCR_LANGUAGES` | Languages Tesseract reads, such as `eng` or `fra+eng`. Default: `eng`. Voice and image text and Full only. |
| `DOCS_PORT` | Port for the local copy of these docs. Default: `8123`. |

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

## AI in a workspace

Automatic labeling, notes chat, and AI note editing run on the AI provider
of the workspace's owner, for everyone in the workspace. Members do not need
a provider of their own, and never see the owner's key.

1. Open Settings, then AI & search, and set up **AI provider**. Any
   OpenAI-compatible API works, including Ollama.
2. Every workspace you own now has AI. To turn it off, or to turn off one
   feature, open the workspace's settings and use the switches under AI.

Only the owner can change these switches. A server can also pin a feature on
or off for every workspace with `LLM_LABELING`, `LLM_CHAT`, or
`LLM_WRITING`.

## Connect an AI assistant

Skippy includes a Model Context Protocol (MCP) server, so an assistant such
as Claude can search and read your notes and, if you allow it, create notes
and add to them. It cannot delete, move, or share anything.

1. In Skippy, open Settings, then Sharing & access, and choose **New token**
   under Assistant access (MCP).
2. Name the token and choose **Read only** or **Read and add**.
3. Copy the token. It is shown once.

For Claude Code, the dialog shows a ready command:

```sh
claude mcp add --transport http skippy https://notes.example.com/api/mcp --header "Authorization: Bearer skp_..."
```

Any other MCP client connects to `https://<your server>/api/mcp` over
Streamable HTTP with the header `Authorization: Bearer <token>`. Revoke a
token in the same Settings section; resetting your password revokes all of
them.

A token reaches every workspace you belong to, except one whose owner turned
off **Assistant access (MCP)** in its settings.

## Documentation site

Every Compose file can also run a local copy of these docs. Start the `docs`
service with the same file, for example:

```sh
docker compose -f docker-compose.simple.yml up -d docs
```

Then open <http://localhost:8123>. To use another port, set `DOCS_PORT` in
`.env`.

## Advanced settings

These are not read from `.env`. To change one, edit the `environment:` section
of the service in your Compose file.

| Setting | What it does | Default |
| --- | --- | --- |
| `STORAGE` | Where attachments go: `disk` or `s3`. | `disk`; Full uses `s3` |
| `S3_URL` | S3 endpoint. Required with `s3`. | Full uses `http://garage:3900` |
| `S3_REGION` | S3 region. | `garage` |
| `S3_BUCKET_PREFIX` | Attachments go in the bucket `<prefix>attachments`. In Full, change `GARAGE_DEFAULT_BUCKET` on the `garage` service to match. | `sticky-notes-` |
| `WHISPER_URL` | Whisper address. Unset turns transcription off. | Unset; Voice and image text and Full use `http://whisper:9000` |
| `OCR_URL` | Tesseract address. Unset turns image text off. | Unset; Voice and image text and Full use `http://tesseract:8884` |
| `UNFURL_ALLOW_PRIVATE` | Allows link previews of hosts on your private network. | Off |
| `TELEGRAM_API` | Telegram Bot API address. | `https://api.telegram.org` |
| `ADDR` | Address the server listens on inside the container. | `0.0.0.0:8787` |
| `DB` | Database file. | `/data/sticky_notes.db` |
| `UPLOADS` | Attachment folder when `STORAGE` is `disk`. | `/data/uploads` |
| `WEB` | Web app folder. | `/app/web` |

The `whisper` service uses the `base` speech model, set by `ASR_MODEL`. A
larger model such as `small` is more accurate but slower and uses more memory.
