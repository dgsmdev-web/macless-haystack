import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io_client;

/// An [http.Client] wrapper that aborts map tile requests which take too
/// long, at every stage of the request.
///
/// Two different things can hang when loading tiles on a bad or absent
/// connection:
/// 1. Waiting for a *response* after the connection was made (a slow/flaky
///    signal, e.g. in a subway).
/// 2. The DNS lookup / TCP *connection* attempt itself, which has its own,
///    much longer system default timeout (can be 60+ seconds) when there
///    is no network route at all (e.g. airplane mode / no internet).
///
/// Without an explicit [HttpClient.connectionTimeout], case 2 alone can
/// make the UI feel frozen for a long time while many tile requests queue
/// up during a zoom. This wraps the underlying [HttpClient] with a short
/// connection timeout *and* an overall timeout on the response, so a tile
/// that can't be reached simply stays blank instead of blocking the map.
class TimeoutHttpClient extends http.BaseClient {
  TimeoutHttpClient({
    this.connectTimeout = const Duration(seconds: 3),
    this.overallTimeout = const Duration(seconds: 5),
  }) : _inner = io_client.IOClient(
          HttpClient()..connectionTimeout = connectTimeout,
        );

  final http.Client _inner;
  final Duration connectTimeout;
  final Duration overallTimeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _inner.send(request).timeout(overallTimeout);
  }

  @override
  void close() {
    _inner.close();
  }
}
