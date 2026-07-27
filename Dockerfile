# Full-stack image: builds the Flutter web app and the Rust backend, ships a
# single slim runtime that serves both on :8787.

# --- 1. Flutter web bundle ---------------------------------------------------
FROM ghcr.io/cirruslabs/flutter:stable AS web
WORKDIR /src
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get
COPY app/ ./
# --wasm ships a WebAssembly (skwasm) build alongside a plain JS fallback;
# the loader picks at runtime, so browsers without WasmGC still work. The
# wasm renderer noticeably smooths animation-heavy screens like the grid.
RUN flutter build web --wasm --release

# --- 2. Rust server ----------------------------------------------------------
FROM rust:trixie AS server
WORKDIR /src
COPY backend/ ./
RUN cargo build --release

# --- 3. Runtime ----------------------------------------------------------------
FROM debian:trixie-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=server /src/target/release/sticky-notes-server /app/
COPY --from=web /src/build/web /app/web

ENV STICKY_NOTES_WEB=/app/web \
    STICKY_NOTES_DB=/data/sticky_notes.db \
    STICKY_NOTES_UPLOADS=/data/uploads

VOLUME ["/data"]
EXPOSE 8787
CMD ["/app/sticky-notes-server"]
