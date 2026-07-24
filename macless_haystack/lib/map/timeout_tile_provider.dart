import 'dart:async';

import 'package:http/http.dart' as http;

/// An [http.Client] wrapper that aborts requests which take too long.
///
/// Used for map tile loading. On an unstable connection (e.g. subway,
/// weak mobile signal) the default tile provider can end up waiting
/// indefinitely on stalled requests, which makes the UI feel frozen
/// during zoom/pan since many tile requests fire at once. Wrapping the
/// client with a timeout makes slow requests fail fast instead, so the
/// map simply shows a blank tile there and stays responsive.
class TimeoutHttpClient extends http.BaseClient {
  TimeoutHttpClient({
    http.Client? inner,
    this.timeout = const Duration(seconds: 6),
  }) : _inner = inner ?? http.Client();

  final http.Client _inner;
  final Duration timeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _inner.send(request).timeout(timeout);
  }

  @override
  void close() {
    _inner.close();
  }
}
