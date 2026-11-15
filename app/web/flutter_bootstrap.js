{{flutter_js}}
{{flutter_build_config}}

// Flutter only hands the wasm build to Chromium by default, so Safari and
// every iOS browser ran the dart2js + CanvasKit build: single-threaded,
// rasterizing on the main thread, measured 2-5x slower per frame. Firefox
// stays on the JS build: skwasm there mis-measures glyph advances, so text
// wraps mid-word and chips stretch to the full width. A browser without
// WasmGC still falls back to the JS build.
_flutter.loader.load({
  config: {
    wasmAllowList: { blink: true, webkit: true, gecko: false },
  },
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
});
