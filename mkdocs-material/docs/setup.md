# Set up Skippy

The smallest deployment is one container and one persistent volume.

```yaml title="docker-compose.yml"
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

Start it with `docker compose up -d`, then open
`http://localhost:8787`.

## Public documentation

The repository Compose file also starts this documentation site on port 8123:

```sh
docker compose up -d docs
```

## Useful environment variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `PUBLIC_URL` | Public address used by the browser and reset links. | Unset |
| `STORAGE` | Attachment storage: `disk` or `s3`. | `disk` |
| `WHISPER_URL` | Optional audio transcription service. | Unset |
| `OCR_URL` | Optional image text recognition service. | Unset |
| `EMBED_URL` | Optional OpenAI-compatible embedding service. | Unset |
| `LLM_*` | Optional server-managed AI configuration. | Unset |
