import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skippy/api/api_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Stands in for a real socket. Only the members [ApiClient] touches are
/// implemented; anything else reaching [noSuchMethod] is a test bug.
class _StubWebSocketChannel implements WebSocketChannel {
  final _frames = StreamController<dynamic>();
  final _ready = Completer<void>();

  /// Frames the client wrote, in order.
  final sent = <dynamic>[];

  var sinkClosed = false;

  @override
  late final WebSocketSink sink = _StubWebSocketSink(this);

  @override
  Stream<dynamic> get stream => _frames.stream;

  @override
  Future<void> get ready => _ready.future;

  /// The handshake lands and the socket starts carrying frames.
  void completeHandshake() => _ready.complete();

  /// What an unreachable host does: `ready` rejects, the stream reports the
  /// same failure, and then it closes. Each of those used to count as its own
  /// reason to reconnect.
  void failToConnect() {
    final failure = WebSocketChannelException('Failed host lookup');
    _ready.completeError(failure);
    _frames.addError(failure);
    _frames.close();
  }

  /// A connection that was up and then dropped, with no error frame.
  void dropAfterConnect() => _frames.close();

  /// Deliver a change notification from the server.
  void emitFrame() => _frames.add('{}');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubWebSocketSink implements WebSocketSink {
  _StubWebSocketSink(this._channel);

  final _StubWebSocketChannel _channel;

  @override
  void add(dynamic data) {
    if (_channel._ready.isCompleted) {
      _channel.sent.add(data);
      return;
    }
    // A real socket reports a write issued before the handshake
    // asynchronously, where the caller's try/catch cannot see it. Unhandled,
    // it fails this test — which is the point: that is what filled the log.
    Future<void>.error(WebSocketChannelException('not connected'));
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    _channel.sinkClosed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A client whose sockets the test drives, plus the list of sockets it has been
/// asked to open, newest last.
(ApiClient, List<_StubWebSocketChannel>) _clientWithStubSockets() {
  final sockets = <_StubWebSocketChannel>[];
  final api = ApiClient(
    baseUrl: 'http://server.test',
    webSocketFactory: (_) {
      final socket = _StubWebSocketChannel();
      sockets.add(socket);
      return socket;
    },
  )..token = 'session';
  return (api, sockets);
}

void main() {
  test('a failed connection schedules exactly one reconnect', () {
    fakeAsync((async) {
      final (api, sockets) = _clientWithStubSockets();
      final events = api.changeEvents().listen((_) {});
      async.flushMicrotasks();
      expect(sockets, hasLength(1), reason: 'listening opens one connection');

      sockets.single.failToConnect();
      async.flushMicrotasks();

      // Nothing before the backoff elapses.
      async.elapse(ApiClient.liveSyncRetryDelay - const Duration(seconds: 1));
      expect(sockets, hasLength(1));

      // ...and one attempt after it. Treating the error and the close as
      // separate failures used to schedule two timers here, then four.
      async.elapse(const Duration(seconds: 1));
      expect(
        sockets,
        hasLength(2),
        reason: 'one failed connection means one reconnect',
      );

      // Hold the failure for several rounds: a regression compounds, so by the
      // fourth round the difference is 6 sockets against 32.
      for (var round = 0; round < 4; round++) {
        sockets.last.failToConnect();
        async.flushMicrotasks();
        async.elapse(ApiClient.maxLiveSyncRetryDelay);
      }
      expect(
        sockets,
        hasLength(6),
        reason: 'attempts stay serial, never doubled',
      );

      events.cancel();
      async.flushMicrotasks();
    });
  });

  test('a connection that drops cleanly reconnects once', () {
    fakeAsync((async) {
      final (api, sockets) = _clientWithStubSockets();
      final events = api.changeEvents().listen((_) {});
      async.flushMicrotasks();

      sockets.single.completeHandshake();
      async.flushMicrotasks();
      sockets.single.dropAfterConnect();
      async.flushMicrotasks();

      async.elapse(ApiClient.liveSyncRetryDelay);
      expect(sockets, hasLength(2));

      events.cancel();
      async.flushMicrotasks();
    });
  });

  test('the token frame waits for the handshake', () {
    fakeAsync((async) {
      final (api, sockets) = _clientWithStubSockets();
      final events = api.changeEvents().listen((_) {});
      async.flushMicrotasks();

      final socket = sockets.single;
      expect(
        socket.sent,
        isEmpty,
        reason: 'writing before ready throws into the zone',
      );

      socket.completeHandshake();
      async.flushMicrotasks();
      expect(socket.sent, ['{"token":"session"}']);

      events.cancel();
      async.flushMicrotasks();
    });
  });

  test('server frames reach the listener', () {
    fakeAsync((async) {
      final (api, sockets) = _clientWithStubSockets();
      var changes = 0;
      final events = api.changeEvents().listen((_) => changes++);
      async.flushMicrotasks();

      sockets.single.completeHandshake();
      async.flushMicrotasks();
      sockets.single.emitFrame();
      async.flushMicrotasks();
      expect(changes, 1);

      events.cancel();
      async.flushMicrotasks();
    });
  });

  test('a connection that comes up resets the backoff', () {
    fakeAsync((async) {
      final (api, sockets) = _clientWithStubSockets();
      final events = api.changeEvents().listen((_) {});
      async.flushMicrotasks();

      // Two failures in a row: the second retry waits 10s, not 5s.
      sockets.single.failToConnect();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));
      expect(sockets, hasLength(2));

      sockets.last.failToConnect();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));
      expect(sockets, hasLength(2), reason: 'the second retry backs off');
      async.elapse(const Duration(seconds: 5));
      expect(sockets, hasLength(3));

      // A connection that lands puts the next retry back on the first rung.
      sockets.last.completeHandshake();
      async.flushMicrotasks();
      sockets.last.dropAfterConnect();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));
      expect(sockets, hasLength(4), reason: 'backoff restarts at 5s');

      events.cancel();
      async.flushMicrotasks();
    });
  });

  test('cancelling stops the reconnect loop', () {
    fakeAsync((async) {
      final (api, sockets) = _clientWithStubSockets();
      final events = api.changeEvents().listen((_) {});
      async.flushMicrotasks();

      sockets.single.failToConnect();
      async.flushMicrotasks();
      events.cancel();
      async.flushMicrotasks();

      async.elapse(const Duration(minutes: 5));
      expect(sockets, hasLength(1));
      expect(async.pendingTimers, isEmpty, reason: 'no timer outlives cancel');
    });
  });

  test('backoff doubles up to a ceiling', () {
    expect(ApiClient.liveSyncBackoff(0), const Duration(seconds: 5));
    expect(ApiClient.liveSyncBackoff(1), const Duration(seconds: 10));
    expect(ApiClient.liveSyncBackoff(2), const Duration(seconds: 20));
    expect(ApiClient.liveSyncBackoff(3), const Duration(seconds: 40));
    expect(ApiClient.liveSyncBackoff(4), ApiClient.maxLiveSyncRetryDelay);
    // Far out on the ladder the shift must not overflow into a short delay.
    expect(ApiClient.liveSyncBackoff(64), ApiClient.maxLiveSyncRetryDelay);
  });
}
