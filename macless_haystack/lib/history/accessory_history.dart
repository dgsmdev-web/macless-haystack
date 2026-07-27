import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/history/day_selection_checkboxes.dart';
import 'package:macless_haystack/history/location_popup.dart';
import 'package:macless_haystack/item_management/kml_export.dart';

import 'dart:math';

class AccessoryHistory extends StatefulWidget {
  final Accessory accessory;

  /// Shows previous locations of a specific [accessory] on a map.
  /// The locations are connected by a chronological line.
  /// The number of days to go back can be adjusted with a slider.
  const AccessoryHistory({
    super.key,
    required this.accessory,
  });

  @override
  State<StatefulWidget> createState() {
    return _AccessoryHistoryState();
  }
}

class _AccessoryHistoryState extends State<AccessoryHistory> {
  late MapController _mapController;

  bool showPopup = false;
  Pair<dynamic, dynamic>? popupEntry;

  /// Always exactly 7 days are offered as checkboxes — today plus the
  /// six previous days — regardless of how much history data actually
  /// exists yet for each of them. This is a fixed constant on purpose:
  /// it used to be computed from the earliest stored entry, but that
  /// meant the set of buttons shown would shrink/shift depending on
  /// data timing, which was confusing and also touched the same
  /// date-arithmetic that turned out to have a timezone bug (see
  /// filterHistoryEntries below).
  static const int maxDayOffset = 6;

  Set<int> selectedDayOffsets = {};
  bool isLineLayerVisible = true;
  bool isPointLayerVisible = true;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();

    // By default show every day at once (same overall view as before),
    // the checkboxes let the user narrow this down afterwards.
    selectedDayOffsets = Set<int>.from(List.generate(maxDayOffset + 1, (i) => i));
  }

  @override
  Widget build(BuildContext context) {
    // Entries are sorted chronologically (oldest first, newest/current last).
    List<Pair<dynamic, dynamic>> filteredEntries = filterHistoryEntries();
    List<Polyline> polylines = [];

    if (isLineLayerVisible) {
      var segmentCount = max(1, filteredEntries.length - 1);
      for (int i = 0; i < filteredEntries.length - 1; i++) {
        var entry = filteredEntries[i];
        var nextEntry = filteredEntries[i + 1];
        List<LatLng> points = [entry.location, nextEntry.location];

        // Bright red at the start of the track, gradually fading
        // (through pink) to white by the most recent point.
        var fraction = i / segmentCount;
        var fade = (255 * fraction).round().clamp(0, 255);

        polylines.add(Polyline(
          points: points,
          strokeWidth: 2,
          color: Color.fromRGBO(255, fade, fade, 1),
        ));
      }
    }
    // Filter for the locations after the specified cutoff date (now - number of days)
    var visibility = [isLineLayerVisible, isPointLayerVisible];
    return Scaffold(
      appBar: AppBar(
        title: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              "${widget.accessory.name} (${filteredEntries.length} history reports)",
            )),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Export history (KML)',
            icon: const Icon(Icons.share),
            onSelected: (String choice) async {
              if (choice == 'selected') {
                if (filteredEntries.isEmpty) return;
                await exportHistoryAsKML(
                  widget.accessory.name,
                  filteredEntries,
                  nameSuffix: _kmlSuffixForSelection(),
                );
              } else if (choice == 'all') {
                var fullHistory = widget.accessory.getSortedLocationHistory();
                if (fullHistory.isEmpty) return;
                await exportHistoryAsKML(
                  widget.accessory.name,
                  fullHistory,
                  nameSuffix: 'all_days',
                );
              }
            },
            itemBuilder: (BuildContext context) => [
              PopupMenuItem<String>(
                value: 'selected',
                enabled: filteredEntries.isNotEmpty,
                child: const Text('Export checked days only'),
              ),
              const PopupMenuItem<String>(
                value: 'all',
                child: Text('Export all available days'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Flexible(
              flex: 3,
              fit: FlexFit.tight,
              child: FlutterMap(
                key: ValueKey(MediaQuery.of(context).orientation),
                mapController: _mapController,
                options: MapOptions(
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  initialCenter: const LatLng(51.1657, 10.4515),
                  maxZoom: 18.0,
                  minZoom: 2.0,
                  initialZoom: 13.0,
                  onMapReady: mapReadyInit,
                  interactionOptions: const InteractionOptions(
                      enableMultiFingerGestureRace: true,
                      flags: InteractiveFlag.pinchZoom |
                          InteractiveFlag.drag |
                          InteractiveFlag.doubleTapZoom |
                          InteractiveFlag.scrollWheelZoom |
                          InteractiveFlag.flingAnimation |
                          InteractiveFlag.pinchMove |
                          InteractiveFlag.pinchZoom),
                  onTap: (_, __) {
                    setState(() {
                      showPopup = false;
                      popupEntry = null;
                    });
                  },
                ),
                children: [
                  Builder(builder: (context) {
                    var isDark =
                        Theme.of(context).brightness == Brightness.dark;
                    var tileLayer = TileLayer(
                      tileProvider: NetworkTileProvider(),
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.aggroupbg.agfind',
                      keepBuffer: 0,
                      tileUpdateTransformer: TileUpdateTransformers.throttle(
                        const Duration(milliseconds: 200),
                      ),
                    );
                    // One color-matrix filter for the whole layer, not
                    // one per individual tile — much cheaper to render
                    // during a fast zoom/pan.
                    return isDark
                        ? ColorFiltered(
                            colorFilter: ColorFilter.matrix([
                              -1,
                              0,
                              0,
                              0,
                              255,
                              0,
                              -1,
                              0,
                              0,
                              255,
                              0,
                              0,
                              -1,
                              0,
                              255,
                              0,
                              0,
                              0,
                              1,
                              0,
                            ]),
                            child: tileLayer,
                          )
                        : tileLayer;
                  }),
                  // The line connecting the locations chronologically
                  PolylineLayer(
                    polylines: polylines,
                  ),
                  // The markers for the historic locations.
                  // First (oldest) report: red. Last (current) report: large
                  // green. Everything in between: small yellow dots.
                  MarkerLayer(
                    markers: filteredEntries.asMap().entries.map((indexed) {
                      var i = indexed.key;
                      var entry = indexed.value;
                      var isFirst = i == 0;
                      var isLast = i == filteredEntries.length - 1;
                      var isSelected = entry == popupEntry;

                      Color color;
                      double size;
                      if (isLast) {
                        color = Colors.green;
                        size = 22;
                      } else if (isFirst) {
                        color = Colors.red;
                        size = 16;
                      } else {
                        color = Colors.yellow;
                        size = 8;
                      }

                      return Marker(
                        point: entry.location,
                        // Give the marker enough room to grow when selected
                        // without shifting its anchor point.
                        width: 34,
                        height: 34,
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              showPopup = true;
                              popupEntry = entry;
                            });
                          },
                          child: Center(
                            child: Icon(
                              Icons.circle,
                              size: isPointLayerVisible
                                  ? (isSelected ? size + 6 : size)
                                  : 0,
                              color: color,
                              shadows: isSelected
                                  ? const [
                                      Shadow(
                                        color: Colors.black,
                                        blurRadius: 4,
                                      ),
                                    ]
                                  : null,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  // Displays the tooltip if active
                  MarkerLayer(
                    markers: [
                      if (showPopup)
                        LocationPopup(
                            location: popupEntry!.location,
                            time: popupEntry!.start,
                            end: popupEntry!.end,
                            ctx: context),
                    ],
                  ),
                  ToggleButtons(
                    isSelected: visibility,
                    onPressed: (int index) {
                      setState(() {
                        visibility[index] = !visibility[index];
                        isLineLayerVisible = visibility[0];
                        isPointLayerVisible = visibility[1];
                        showPopup = false;
                        popupEntry = null;
                      });
                    },
                    children: [
                      Icon(Icons.timeline),
                      Icon(Icons.scatter_plot_rounded),
                    ],
                  )
                ],
              ),
            ),
            Flexible(
              flex: 1,
              fit: FlexFit.tight,
              child: DaySelectionCheckboxes(
                selectedDayOffsets: selectedDayOffsets,
                maxDayOffset: maxDayOffset,
                onChanged: (Set<int> newSelection) {
                  setState(() {
                    showPopup = false;
                    popupEntry = null;
                    selectedDayOffsets = newSelection;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      mapReady();
                    });
                  });
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  mapReady() {
    List<Pair<dynamic, dynamic>> filteredEntries = filterHistoryEntries();
    if (filteredEntries.isNotEmpty) {
      var historicLocations =
          filteredEntries.map((entry) => entry.location).toList();
      var bounds = LatLngBounds.fromPoints(historicLocations);
      _mapController.fitCamera(CameraFit.bounds(bounds: bounds));
    }
  }

  mapReadyInit() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      mapReady();
    });
  }

  List<Pair<dynamic, dynamic>> filterHistoryEntries() {
    var today = DateTime.now();
    var todayDateOnly = DateTime(today.year, today.month, today.day);

    // Precompute the actual calendar dates the selected offsets refer to,
    // so each entry only needs one comparison per selected day.
    var selectedDates = selectedDayOffsets
        .map((offset) => todayDateOnly.subtract(Duration(days: offset)))
        .toSet();

    var filteredEntries = widget.accessory
        .getSortedLocationHistory()
        .where((element) {
          // IMPORTANT: normalize to local time first. If `element.end`
          // happens to be a UTC-based DateTime (depending on how the
          // report was originally decoded/parsed), reading .year/.month
          // /.day directly would give the UTC calendar date instead of
          // the local one — silently shifting entries into the wrong
          // day bucket (or out of every bucket) whenever local time and
          // UTC fall on different calendar days, e.g. shortly after
          // local midnight. That looked like "reports disappearing".
          var localEnd = element.end.toLocal();
          var entryDate =
              DateTime(localEnd.year, localEnd.month, localEnd.day);
          return selectedDates.contains(entryDate);
        })
        .toList();
    return filteredEntries;
  }

  /// Builds a filename suffix describing which days are currently
  /// selected, so an export of a single isolated day is clearly labeled
  /// (e.g. "2026-07-22"), while exporting everything keeps the plain,
  /// unsuffixed filename as before.
  String? _kmlSuffixForSelection() {
    var allDays = Set<int>.from(List.generate(maxDayOffset + 1, (i) => i));
    if (selectedDayOffsets.length == allDays.length &&
        selectedDayOffsets.containsAll(allDays)) {
      return null; // everything selected — no special suffix needed
    }
    var today = DateTime.now();
    var dateFormat = DateFormat('yyyy-MM-dd');
    var sortedOffsets = selectedDayOffsets.toList()..sort();
    var dates = sortedOffsets
        .map((offset) => dateFormat.format(today.subtract(Duration(days: offset))))
        .toList();
    if (dates.length <= 3) {
      return dates.join('_');
    }
    return '${dates.length}_days';
  }

  var logger = Logger(
    printer: PrettyPrinter(methodCount: 0),
  );
}
