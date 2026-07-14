/// Non-web platforms: no online/offline events. The store falls back to its
/// periodic retry, so an empty stream is all that's needed.
Stream<void> onlineEvents() => const Stream<void>.empty();
