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

The Compose files in the repository point at the public GitHub image,
`ghcr.io/lucasgenoud/skippy:latest`. The homeserver stays on the Forgejo
registry: set `server`'s `image:` to
`forgejo.genoud.dev/lucasgenoud/skippy:latest` in its own copy.

Generate credentials before the first start. Copy each output line into the
private `.env` file:

```sh
access_key="GK$(openssl rand -hex 16)"
secret_key="$(openssl rand -hex 32)"
printf 'GARAGE_RPC_SECRET='; openssl rand -hex 32
printf 'S3_ACCESS_KEY=%s\n' "$access_key"
printf 'GARAGE_DEFAULT_ACCESS_KEY=%s\n' "$access_key"
printf 'S3_SECRET_KEY=%s\n' "$secret_key"
printf 'GARAGE_DEFAULT_SECRET_KEY=%s\n' "$secret_key"
```

Keep `.env` private. Keep matching S3/Garage values unchanged after Garage
setup. Compose has no default credentials and reports missing values.

Then bring the stack up:

```
docker compose up -d
```

Watchtower is not defined in this repository's `docker-compose.yml`. Configure
it separately on the homeserver if you want automatic pulls and restarts.

### 4. GPU transcription (optional)

GPU values are commented in `docker-compose.yml`. For NVIDIA, edit the
Whisper service to use the GPU image, `large-v3`, `cuda`, and `float16`, then
uncomment its GPU reservation and use a `900s` health-check start period.
Requires the NVIDIA Container Toolkit and a CUDA 12-compatible driver (≥ 525).
Check `nvidia-smi` first.

```
docker compose up -d whisper
```

### 5. Image text recognition (optional)

The `tesseract` service reads uploaded pictures so their text is searchable.
`OCR_LANGUAGES` selects the language packs, `eng` by default; set it to
something like `fra+eng` only if the OCR image ships those packs, since
Tesseract fails on a language it does not have.

Turning the service on for the first time backfills existing pictures: each
start queues up to 500 images that have never been read, so a large library
catches up over several restarts. Recognition failures are retried the same
way, which is why a temporary outage needs no manual repair.

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
