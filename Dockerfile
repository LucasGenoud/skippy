# Full-stack image: builds the Flutter web app and the Rust backend, ships a
# single slim runtime that serves both on :8787.

# --- 1. Flutter web bundle ---------------------------------------------------
FROM ghcr.io/cirruslabs/flutter:stable AS web
WORKDIR /src
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get
COPY app/ ./
RUN flutter build web --release

# --- 2. Rust server ----------------------------------------------------------
# trixie: the prebuilt ONNX runtime (ort) needs libstdc++ from GCC 13+.
FROM rust:trixie AS server
WORKDIR /src
COPY backend/ ./
# ort (ONNX runtime used for embeddings) may ship a dynamic lib next to the
# binary; collect whatever exists so the runtime stage can copy it (find is a
# no-op success when nothing matches).
RUN cargo build --release \
    && mkdir /out \
    && cp target/release/sticky-notes-server /out/ \
    && find target -name "libonnxruntime*.so*" -exec cp {} /out/ \;

# --- 3. Runtime ----------------------------------------------------------------
FROM debian:trixie-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libstdc++6 libssl3t64 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=server /out/ /app/
COPY --from=web /src/build/web /app/web

ENV STICKY_NOTES_WEB=/app/web \
    STICKY_NOTES_DB=/data/sticky_notes.db \
    STICKY_NOTES_UPLOADS=/data/uploads \
    LD_LIBRARY_PATH=/app \
    HF_HOME=/models

VOLUME ["/data", "/models"]
EXPOSE 8787
CMD ["/app/sticky-notes-server"]
