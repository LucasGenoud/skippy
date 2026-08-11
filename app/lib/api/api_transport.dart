part of 'api_client.dart';

/// Opens the live-sync and chat sockets. Production passes
/// [WebSocketChannel.connect]; tests substitute a channel they can drive.
typedef WebSocketChannelFactory = WebSocketChannel Function(Uri uri);

/// Fire-and-forget cleanup. Cancelling a subscription or closing a sink that
/// never finished connecting can itself fail, and an unhandled rejection there
/// would be one more line in the very log storm the reconnect logic exists to
/// avoid. Nothing downstream cares whether teardown succeeded.
void _ignoreFailure(Future<void>? work) {
  work?.then<void>((_) {}, onError: (Object _) {});
}

/// Wraps a client so no request can hang forever. A phone that is connected to
/// a network with no route to the server may otherwise wait for the operating
/// system's much longer socket timeout before the app can report offline.
class _TimeoutClient extends http.BaseClient {
  _TimeoutClient(this._inner, this.timeout);

  final http.Client _inner;
  final Duration timeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request).timeout(timeout);

  @override
  void close() => _inner.close();
}

/// Shared HTTP/WebSocket transport concerns. Domain methods remain on
/// [ApiClient], while URL construction, authentication, timeout handling, and
/// response decoding have one focused implementation.
abstract class _ApiTransport {
  _ApiTransport({
    required this.baseUrl,
    required Duration requestTimeout,
    required this.probeTimeout,
    http.Client? httpClient,
    WebSocketChannelFactory? webSocketFactory,
  }) : _uploadClient = httpClient ?? http.Client(),
       _webSocketFactory = webSocketFactory ?? WebSocketChannel.connect {
    _client = _TimeoutClient(_uploadClient, requestTimeout);
  }

  String baseUrl;
  final Duration probeTimeout;
  final http.Client _uploadClient;
  final WebSocketChannelFactory _webSocketFactory;
  late final http.Client _client;

  /// Session token; set by the auth store after sign-in.
  String? token;

  /// Invoked when the current server rejects the active session.
  VoidCallback? onUnauthorized;

  Uri _uri(String path) => Uri.parse('$baseUrl/api$path');

  Map<String, String> _headers({bool json = true}) => {
    if (json) 'content-type': 'application/json',
    if (token != null) 'authorization': 'Bearer $token',
  };

  Uri _webSocketUri(String path) {
    final httpUri = _uri(path);
    final scheme = switch (httpUri.scheme) {
      'https' => 'wss',
      'http' => 'ws',
      _ => throw FormatException('backend URL must use http or https'),
    };
    return httpUri.replace(scheme: scheme);
  }

  /// The returned channel is not connected yet; await its `ready` before
  /// writing to the sink.
  WebSocketChannel _connectWebSocket(String path) =>
      _webSocketFactory(_webSocketUri(path));

  Future<void> checkConnection() async {
    final response = await _client.get(_uri('/health')).timeout(probeTimeout);
    _decode(response, authed: false);
  }

  dynamic _decode(
    http.Response response, {
    bool authed = true,
    String? requestToken,
  }) {
    final authorization = response.request?.headers['authorization'];
    final sentToken =
        requestToken ??
        (authorization != null && authorization.startsWith('Bearer ')
            ? authorization.substring('Bearer '.length)
            : null);
    final requestUrl = response.request?.url.toString();
    final currentApiBase = _uri('/').toString();
    final currentServer =
        requestUrl == null || requestUrl.startsWith(currentApiBase);
    if (response.statusCode == 401 &&
        authed &&
        currentServer &&
        sentToken != null &&
        sentToken == token) {
      onUnauthorized?.call();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, response.body);
    }
    if (response.body.isEmpty) return null;
    return jsonDecode(utf8.decode(response.bodyBytes));
  }
}
