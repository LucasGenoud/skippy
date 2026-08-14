import 'dart:async';

/// Plain-language explanation of a request that never reached the server's
/// application layer: DNS, TLS, routing and timeout failures.
///
/// On a self-hosted app this banner is usually the only diagnostic the person
/// signing in ever sees, so it names the host and says which link in the chain
/// broke instead of the one-size "can't reach the server".
///
/// The classification reads the exception's text rather than its type: the
/// interesting ones (`SocketException`, `HandshakeException`) live in
/// `dart:io`, which the web build cannot import, and the `http` package wraps
/// them in a `ClientException` whose message is the only thing left of the
/// original.
String describeConnectionFailure(Object error, String baseUrl) {
  final host = _hostOf(baseUrl);
  final text = error.toString();

  bool mentions(String needle) => text.toLowerCase().contains(needle);

  if (error is TimeoutException || mentions('timeout')) {
    return '$host did not respond in time. It may be starting up, or '
        'unreachable from this network.';
  }
  if (mentions('failed host lookup') ||
      mentions('nodename nor servname') ||
      mentions('name or service not known') ||
      mentions('no address associated')) {
    return "Can't find $host. Check the address for typos, and that this "
        'device can resolve it.';
  }
  if (mentions('connection refused')) {
    return 'Nothing is answering at $host. Check the port, and that the '
        'server is running.';
  }
  if (mentions('handshake') ||
      mentions('certificate') ||
      mentions('tls') && mentions('error')) {
    return "Couldn't open a secure connection to $host. Its HTTPS certificate "
        'was rejected — a self-signed one has to be trusted on this device '
        'first.';
  }
  if (mentions('network is unreachable') ||
      mentions('no route to host') ||
      mentions('connection reset') ||
      mentions('connection closed') ||
      mentions('connection failed')) {
    return "Couldn't reach $host. Check this device's connection, and that "
        'the server is reachable from it.';
  }
  // Flutter web never sees the real cause: the browser reports a blocked or
  // failed fetch identically whether the server is down, the certificate is
  // untrusted, or CORS refused the response.
  if (mentions('xmlhttprequest') || mentions('failed to fetch')) {
    return "The browser couldn't reach $host. It may be offline, using an "
        'untrusted certificate, or refusing this origin.';
  }
  if (error is FormatException || mentions('formatexception')) {
    return 'That server address is not valid. It has to start with http:// '
        'or https://.';
  }
  return "Can't reach $host. Check the server address and this device's "
      'connection.';
}

/// The host to name in a message, falling back to whatever was configured when
/// it doesn't parse as a URL (which is itself worth showing).
String _hostOf(String baseUrl) {
  final uri = Uri.tryParse(baseUrl);
  final host = uri?.host ?? '';
  if (host.isEmpty) return baseUrl.isEmpty ? 'the server' : baseUrl;
  return uri!.hasPort ? '$host:${uri.port}' : host;
}
