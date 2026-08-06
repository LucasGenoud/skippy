# Full-stack image: builds the Flutter web app and the Rust backend, ships a
# single slim runtime that serves both on :8787.

# --- 1. Flutter web bundle ---------------------------------------------------
FROM ghcr.io/cirruslabs/flutter:stable AS web
WORKDIR /src
ARG VERSION_SUFFIX=-dev+local
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get
COPY app/ ./
# --wasm ships a WebAssembly (skwasm) build alongside a plain JS fallback;
# the loader picks at runtime, so browsers without WasmGC still work. The
# wasm renderer noticeably smooths animation-heavy screens like the grid.
RUN flutter build web --wasm --release \
    --dart-define=SKIPPY_CLIENT_VERSION=1.0.0${VERSION_SUFFIX}

# --- 2. Rust server ----------------------------------------------------------
FROM rust:trixie AS server
WORKDIR /src
ARG VERSION_SUFFIX=-dev+local
ENV STICKY_NOTES_SERVER_VERSION=0.2.0${VERSION_SUFFIX}
COPY backend/ ./
RUN cargo build --release

# --- 3. Runtime ----------------------------------------------------------------
FROM debian:trixie-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates gosu passwd \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system sticky-notes \
    && useradd --system --gid sticky-notes --home-dir /nonexistent \
        --shell /usr/sbin/nologin sticky-notes \
    && install -d -o sticky-notes -g sticky-notes /data
WORKDIR /app
COPY --from=server /src/target/release/sticky-notes-server /app/
COPY --from=web /src/build/web /app/web
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ENV STICKY_NOTES_WEB=/app/web \
    STICKY_NOTES_DB=/data/sticky_notes.db \
    STICKY_NOTES_UPLOADS=/data/uploads

VOLUME ["/data"]
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/app/sticky-notes-server"]
