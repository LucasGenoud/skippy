import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Emits once each time the browser reports that connectivity returned. The
/// listener is a plain (synchronous) closure, so `.toJS` is safe here.
Stream<void> onlineEvents() {
  late final StreamController<void> controller;
  final listener = ((web.Event _) => controller.add(null)).toJS;
  controller = StreamController<void>.broadcast(
    onListen: () => web.window.addEventListener('online', listener),
    onCancel: () => web.window.removeEventListener('online', listener),
  );
  return controller.stream;
}
