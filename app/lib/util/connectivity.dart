// A stream that emits whenever the device regains connectivity. On the web
// this is the browser's `online` event; elsewhere it never fires (the store's
// 5s retry loop covers reconnection on those platforms).
export 'connectivity_stub.dart'
    if (dart.library.js_interop) 'connectivity_web.dart';
