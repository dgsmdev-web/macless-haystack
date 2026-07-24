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
class ConnectivityAwareTileLayer extends StatefulWidget {
  final Widget Function(BuildContext context, Widget child, TileImage tile)?
      tileBuilder;

  const ConnectivityAwareTileLayer({super.key, this.tileBuilder});

  @override
  State<ConnectivityAwareTileLayer> createState() =>
      _ConnectivityAwareTileLayerState();
}

class _ConnectivityAwareTileLayerState
    extends State<ConnectivityAwareTileLayer> {
  bool _hasConnection = true;
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  @override
  void initState() {
    super.initState();
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
      tileProvider: NetworkTileProvider(httpClient: TimeoutHttpClient()),
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'de.dchristl.headlesshaystack',
      tileBuilder: widget.tileBuilder,
    );
  }
}
