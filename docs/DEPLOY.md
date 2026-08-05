# Deployment

Pushing to `main` builds the full-stack image in a Forgejo Actions job and
pushes it to the Forgejo container registry. A Watchtower container on the
homeserver polls that registry and restarts `server` when a new image lands,
so a deploy is just `git push`.

```
git push  ->  .forgejo/workflows/build.yml  ->  registry :latest  ->  Watchtower pulls & restarts server
```

Your data (SQLite DB + uploads in the `app_data` volume, or Garage) survives the
restart untouched. A missing database file is initialized with the current
schema.

## One-time setup

### 1. Repo secrets (Forgejo → repo → Settings → Actions → Secrets)

- `REGISTRY_USER`, your Forgejo username (`lucasgenoud`).
- `REGISTRY_TOKEN`, a Forgejo access token with the **`write:package`** scope
  (User Settings → Applications → Generate New Token).

### 2. Runner

- The workflow's `runs-on: homeserver-runner` must match a label your Forgejo runner
  registered with, adjust if yours differs.
- The runner must expose the host Docker daemon to jobs (forgejo-runner does
  this by default). The job shells out to `docker build`/`docker push`.

### 3. Homeserver

Log the host's Docker into the registry once so Watchtower can pull the private
image (it reads `~/.docker/config.json`):

```
docker login forgejo.genoud.dev
```

Then bring the stack up:

```
docker compose up -d
```

Watchtower is not defined in this repository's `docker-compose.yml`. Configure
it separately on the homeserver if you want automatic pulls and restarts.

### 4. GPU transcription (optional)

`docker-compose.gpu.yml` moves Whisper onto an NVIDIA GPU and up to the
`large-v3` model. It is never loaded automatically, because its device
reservation fails hard on any host without a CUDA GPU. Requires the NVIDIA
Container Toolkit and a driver new enough for the image's CUDA 12 runtime
(≥ 525); check `nvidia-smi` on the host first.

Opt in on the homeserver through the `.env` file next to the compose files:

```
COMPOSE_FILE=docker-compose.yml:docker-compose.gpu.yml
```

Set it there rather than passing `-f` flags, so the bare `docker compose`
commands elsewhere in this document (backup cron, restore, rollback) pick the
overlay up too. A forgotten pair of flags silently recreates `whisper` from the
CPU image.

The first start downloads ~3 GB into the `whisper_cache` volume, which is why
the overlay widens the health-check start period; `server` gates on
`condition: service_healthy`, so a timeout there fails the whole stack. Pull it
once before the switch to keep the window short:

```
docker compose pull whisper && docker compose up -d whisper
```

## Rollback

Every build also pushes a `:<commit-sha>` tag. To pin an old build, bypass
Watchtower and run that tag directly:

```
docker compose run ... # or:
docker pull forgejo.genoud.dev/lucasgenoud/skippy:<sha>
docker tag  forgejo.genoud.dev/lucasgenoud/skippy:<sha> forgejo.genoud.dev/lucasgenoud/skippy:latest
docker compose up -d server
```

Watchtower will leave it alone until a newer `:latest` is pushed.

## Scheduled system backups

`docker-compose.yml` bind-mounts `${STICKY_NOTES_BACKUPS_DIR:-./backups}` at
`/backups`. Set `STICKY_NOTES_BACKUPS_DIR` to storage outside the application
host when possible, or sync that directory off-host after each run.

The backup command is online-safe and works in disk and S3 modes:

```sh
docker compose exec -T --user sticky-notes server /app/sticky-notes-server \
  system-backup /backups/skippy-$(date -u +%Y%m%d-%H%M%S).skb
```

Example host crontab (cron treats `%` specially, hence the escaping):

```cron
15 3 * * * cd /srv/skippy && docker compose exec -T --user sticky-notes server /app/sticky-notes-server system-backup /backups/skippy-$(date -u +\%Y\%m\%d-\%H\%M\%S).skb
```

The archive includes the complete SQLite database and all attachment objects
referenced by its consistent snapshot. It contains password hashes, active
session verifiers, user settings, and private note/file data; protect it like the live
database. Environment configuration and external service state are not part of
the archive.

Restores require downtime and create a pre-restore safety archive:

```sh
docker compose stop server
docker compose run --rm --no-deps server \
  /app/sticky-notes-server system-restore \
  /backups/skippy-20260729-030000.skb --confirm
docker compose up -d server
```

Use `--skip-safety-backup` only when the current database is unreadable and no
safety archive can be created.

Before replacing current data, restore validates the archive checksum, SQLite
integrity and foreign keys, required tables,
and the complete attachment inventory.

## Health and logs

`GET /api/health` reports durable cleanup queue counts and the process-local
total of failed background jobs. A non-zero cleanup `failed` count means an
attachment or vector deletion is waiting for retry; it remains in SQLite across
container restarts. Request and background-job logs are newline-delimited JSON.
Every response has an `x-request-id`; a valid caller-supplied value is preserved
for correlation. Public-link credentials and signed-file credentials are logged
as route templates, never as raw paths.

## Notes

- The Dockerfile compiles the Rust backend from scratch when `backend/` changes
  (no dependency-cache layer). Docker layer cache on the runner keeps Flutter +
  unchanged layers fast, but a backend edit recompiles all crates. If that gets
  painful, add a `cargo-chef` stage or BuildKit cache mounts.
- Per-sha tags accumulate in the registry; Forgejo's package cleanup rules
  (owner → Settings → Packages) can cap them.
