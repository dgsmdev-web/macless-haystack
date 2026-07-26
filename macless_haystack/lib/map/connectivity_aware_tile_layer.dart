import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:macless_haystack/map/timeout_tile_provider.dart';

/// A [TileLayer] that first checks device connectivity and, when there is
/// no network connection at all, shows a simple placeholder instead of
/// attempting to load tiles.
///
/// This is a first line of defense before requests are even attempted —
/// [TimeoutHttpClient] (used underneath as the tile provider's HTTP
/// client) still applies as a second line of defense for cases this
/// can't catch, such as being connected to Wi-Fi/mobile data that has no
/// actual working internet behind it (connectivity_plus only reports the
/// network *interface* state, not real internet reachability).
///
/// Dark-theme color inversion, if needed, should be applied by the
/// CALLER wrapping this whole widget in a single [ColorFiltered] — not
/// passed in as a per-tile `tileBuilder`. Filtering every individual
/// tile separately (as this used to do) meant the GPU had to run the
/// color-matrix shader once per visible tile — during a fast pinch-zoom
/// or pan, dozens of tiles can be on screen/in transition at once,
/// which was heavy enough to cause visible jank/freezes on real
/// devices. Filtering the layer once, as a whole, costs the same
/// operation exactly once per frame regardless of how many individual
/// tiles make it up.
class ConnectivityAwareTileLayer extends StatefulWidget {
  const ConnectivityAwareTileLayer({super.key});

  @override
  State<ConnectivityAwareTileLayer> createState() =>
      _ConnectivityAwareTileLayerState();
}

class _ConnectivityAwareTileLayerState
    extends State<ConnectivityAwareTileLayer> {
  bool _hasConnection = true;
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  // Created ONCE for the lifetime of this widget, not on every build().
  // Previously a brand new TimeoutHttpClient (wrapping a brand new
  // dart:io HttpClient) was created inside build() every single time
  // this widget rebuilt — which can happen many times in quick
  // succession during a single zoom/pan gesture. None of those old
  // clients were ever closed, so they piled up as leaked, still-pending
  // connections, each independently waiting out its own timeout before
  // failing. With enough of them stacked up during a zoom, the visible
  // result was exactly the freeze being reported — regardless of how
  // good the actual network connection was, since the real problem was
  // resource pile-up, not connectivity.
  late final TimeoutHttpClient _httpClient;
  late final NetworkTileProvider _tileProvider;

  @override
  void initState() {
    super.initState();
    _httpClient = TimeoutHttpClient();
    _tileProvider = NetworkTileProvider(httpClient: _httpClient);
    _checkInitial();
    _subscription = Connectivity().onConnectivityChanged.listen((results) {
      _updateState(results);
    });
  }

  Future<void> _checkInitial() async {
    final results = await Connectivity().checkConnectivity();
    _updateState(results);
  }

  void _updateState(List<ConnectivityResult> results) {
    final connected = results.any((r) => r != ConnectivityResult.none);
    if (mounted && connected != _hasConnection) {
      setState(() {
        _hasConnection = connected;
      });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _httpClient.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasConnection) {
      return Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Center(
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: Text(
              'No internet connection.\nMap tiles cannot be loaded right now.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return TileLayer(
      tileProvider: _tileProvider,
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'de.dchristl.headlesshaystack',
    );
  }
}
