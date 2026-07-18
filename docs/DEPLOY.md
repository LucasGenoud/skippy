# Deployment

Pushing to `main` builds the full-stack image in a Forgejo Actions job and
pushes it to the Forgejo container registry. A Watchtower container on the
homeserver polls that registry and restarts `server` when a new image lands —
so a deploy is just `git push`.

```
git push  ->  .forgejo/workflows/build.yml  ->  registry :latest  ->  Watchtower pulls & restarts server
```

Your data (SQLite DB + uploads in the `app_data` volume, or Garage) survives the
restart untouched, and DB migrations run on startup.

## One-time setup

### 1. Repo secrets (Forgejo → repo → Settings → Actions → Secrets)

- `REGISTRY_USER` — your Forgejo username (`lucasgenoud`).
- `REGISTRY_TOKEN` — a Forgejo access token with the **`write:package`** scope
  (User Settings → Applications → Generate New Token).

### 2. Runner

- The workflow's `runs-on: docker` must match a label your Forgejo runner
  registered with — adjust if yours differs.
- The runner must expose the host Docker daemon to jobs (forgejo-runner does
  this by default). The job shells out to `docker build`/`docker push`.

### 3. Homeserver

Log the host's Docker into the registry once so Watchtower can pull the private
image (it reads `~/.docker/config.json`):

```
docker login forgejo.genoud.dev
```

Then bring the stack up. Watchtower is part of the compose file and takes over
from there:

```
docker compose up -d
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

## Notes

- The Dockerfile compiles the Rust backend from scratch when `backend/` changes
  (no dependency-cache layer). Docker layer cache on the runner keeps Flutter +
  unchanged layers fast, but a backend edit recompiles all crates. If that gets
  painful, add a `cargo-chef` stage or BuildKit cache mounts.
- Per-sha tags accumulate in the registry; Forgejo's package cleanup rules
  (owner → Settings → Packages) can cap them.
