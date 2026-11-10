{{flutter_js}}
{{flutter_build_config}}

// Flutter only hands the wasm build to Chromium by default, so Safari,
// every iOS browser and Firefox ran the dart2js + CanvasKit build:
// single-threaded, rasterizing on the main thread, measured 2-5x slower per
// frame. A browser without WasmGC still falls back to the JS build.
_flutter.loader.load({
  config: {
    wasmAllowList: { blink: true, webkit: true, gecko: true },
  },
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
});
