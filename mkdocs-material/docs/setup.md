# Set up Skippy

Clone the repository. Its base <code>docker-compose.yml</code> is below, so
you can also copy it directly into a new installation:

~~~yaml title="docker-compose.yml"
services:
  server:
    image: ghcr.io/lucasgenoud/skippy:latest
    ports:
      - "8787:8787"
    environment:
      PUBLIC_URL: ${PUBLIC_URL:-}
      EMBED_URL: ${EMBED_URL:-}
      EMBED_MODEL: ${EMBED_MODEL:-bge-m3}
      EMBED_API_KEY: ${EMBED_API_KEY:-}
      STORAGE: disk
      ALLOW_PRIVATE_USER_ENDPOINTS: ${ALLOW_PRIVATE_USER_ENDPOINTS:-}
      LLM_BASE_URL: ${LLM_BASE_URL:-}
      LLM_API_KEY: ${LLM_API_KEY:-}
      LLM_MODEL: ${LLM_MODEL:-}
      LLM_LABELING: ${LLM_LABELING:-}
      LLM_CHAT: ${LLM_CHAT:-}
      LLM_WRITING: ${LLM_WRITING:-}
      SMTP_HOST: ${SMTP_HOST:-}
      SMTP_PORT: ${SMTP_PORT:-}
      SMTP_SECURITY: ${SMTP_SECURITY:-}
      SMTP_USERNAME: ${SMTP_USERNAME:-}
      SMTP_PASSWORD: ${SMTP_PASSWORD:-}
      SMTP_FROM: ${SMTP_FROM:-}
    volumes:
      - app_data:/data
    restart: unless-stopped
  docs:
    image: ghcr.io/lucasgenoud/skippy-docs:latest
    ports:
      - "${DOCS_PORT:-8123}:8123"
    restart: unless-stopped
volumes:
  app_data:
~~~

Create a <code>.env</code> file when you have a public address:

~~~env title=".env"
PUBLIC_URL=https://notes.example.com
~~~

Choose the Compose command that fits your installation.

| Setup | Includes | Command |
| --- | --- | --- |
| Standard | Skippy with SQLite and local attachment storage | <code>docker compose up -d</code> |
| Transcription and image text | Standard setup, Whisper, and Tesseract | <code>docker compose -f docker-compose.yml -f docker-compose.simple.yml up -d</code> |
| Full stack | Transcription, image text, and Garage S3 storage | <code>docker compose -f docker-compose.yml -f docker-compose.simple.yml -f docker-compose.all.yml up -d</code> |

Open Skippy at <code>http://localhost:8787</code>, or the address in
<code>PUBLIC_URL</code>.

## Full-stack credentials

The full stack requires Garage credentials in <code>.env</code> before its
first start:

~~~sh
access_key="GK$(openssl rand -hex 16)"
secret_key="$(openssl rand -hex 32)"
printf 'GARAGE_RPC_SECRET='; openssl rand -hex 32
printf 'S3_ACCESS_KEY=%s\n' "$access_key"
printf 'GARAGE_DEFAULT_ACCESS_KEY=%s\n' "$access_key"
printf 'S3_SECRET_KEY=%s\n' "$secret_key"
printf 'GARAGE_DEFAULT_SECRET_KEY=%s\n' "$secret_key"
~~~

Copy the output into <code>.env</code>.

## Install on a device

These commands install Skippy directly from a development machine. They do not
publish it to an app store.

### Android

Enable USB debugging, connect the device, then run:

~~~sh
cd app
flutter devices
flutter run --release -d <android-device-id>
~~~

### iPhone or iPad

Use macOS with Xcode, enable Developer Mode on the device, and select your
Apple signing team in <code>app/ios/Runner.xcworkspace</code>. Then connect the
device and run:

~~~sh
cd app
flutter devices
flutter run --release -d <ios-device-id>
~~~

An app installed with a free Apple developer account needs refreshing every
seven days.

## Documentation site

The documentation container is included in the base Compose file:

~~~sh
docker compose up -d docs
~~~

Open it at <code>http://localhost:8123</code>. Set <code>DOCS_PORT</code> to
use a different host port.
