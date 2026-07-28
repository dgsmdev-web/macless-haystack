import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logger/logger.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/findMy/find_my_controller.dart';
import 'package:macless_haystack/findMy/models.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';

const accessoryStorageKey = 'ACCESSORIES';
const historyStorageKey = 'HISTORY';

class AccessoryRegistry extends ChangeNotifier {
  var _storage = const FlutterSecureStorage();
  List<Accessory> _accessories = [];
  bool loading = false;
  bool initialLoadFinished = false;

  /// While true, the "refresh on returning to the app" listener
  /// (see Dashboard.didChangeAppLifecycleState) skips its refresh
  /// entirely instead of firing as normal.
  ///
  /// Needed specifically for "Restore Full History": opening the
  /// system file picker technically backgrounds and then resumes the
  /// app, which would otherwise trigger that exact listener — pulling
  /// in real, newer location data from the server (which knows
  /// nothing about a purely local delete) right as the user is trying
  /// to restore an older backup, and silently overwriting what they
  /// just restored.
  bool suppressResumeRefresh = false;

  var logger = Logger(
    printer: PrettyPrinter(methodCount: 0),
  );

  /// Creates the accessory registry.
  ///
  /// This is used to manage the accessories of the user.
  AccessoryRegistry() : super();

  /// A list of the user's accessories.
  UnmodifiableListView<Accessory> get accessories =>
      UnmodifiableListView(_accessories);

  /// Loads the user's accessories from persistent storage.
  Future<void> loadAccessories() async {
    loading = true;

    String? serialized;

    try {
      serialized = await _storage.read(key: accessoryStorageKey);
    } catch (e) {
      serialized = null;
    }
    
    if (serialized != null) {
      List accessoryJson = json.decode(serialized);
      List<Accessory> loadedAccessories =
          accessoryJson.map((val) => Accessory.fromJson(val)).toList();
      _accessories = loadedAccessories;
      clearInvalidAccessories(_accessories);
      if (_accessories.length != loadedAccessories.length) {
        _storeAccessories();
      }
    } else {
      _accessories = [];
    }
    await loadHistory();

    loading = false;

    notifyListeners();
  }

  set setStorage(FlutterSecureStorage s) {
    _storage = s;
  }

  Future<void> loadHistory() async {
    String? history = await _storage.read(key: historyStorageKey);
    if (history != null) {
      // jsonDecode() is a synchronous, CPU-bound operation — for a
      // small history blob this is instant, but this app's history is
      // now kept indefinitely (no more 7-day cap), so after enough
      // testing/real use the blob can grow large enough that decoding
      // it synchronously on the UI isolate causes a real, visible
      // freeze. compute() runs it on a background isolate instead, so
      // the UI thread stays responsive no matter how big the history
      // has grown.
      Map<String, dynamic> jsonDecoded = await compute(
          (String source) => jsonDecode(source) as Map<String, dynamic>,
          history);
      for (var item in _accessories) {
        var currElement = jsonDecoded[item.id];
        if (currElement != null) {
          item.addLocationHistory(currElement);
        }
      }
    }
  }

  /// Fetches new location reports and matches them to their accessory.
  Future<int> loadLocationReports(
      Iterable<Accessory> currentAccessories) async {
    List<Future<List<FindMyLocationReport>>> runningLocationRequests = [];
    // Snapshot each accessory's history "generation" right now, before
    // the network fetch even starts — if the user clears this
    // accessory's history while this fetch is still in flight (a real
    // possibility, since decrypting reports can take several seconds),
    // the generation will have moved on by the time this fetch's
    // results come back, and they'll be discarded instead of silently
    // undoing the deletion.
    Map<Accessory, int> generationAtFetchStart = {
      for (var a in currentAccessories) a: a.historyGeneration,
    };

    // request location updates for all accessories simultaneously
    String? url = Settings.getValue<String>(endpointUrl);
    for (var i = 0; i < currentAccessories.length; i++) {
      var accessory = currentAccessories.elementAt(i);

      var keyPair =
          await FindMyController.getKeyPair(accessory.hashedPublicKey);

      List<FindMyKeyPair> hashedPublicKeys =
          await Stream.fromIterable(accessory.additionalKeys)
              .asyncMap((hashedPublicKey) =>
                  FindMyController.getKeyPair(hashedPublicKey))
              .toList();

      hashedPublicKeys.add(keyPair);

      var locationRequest =
          FindMyController.computeResults(hashedPublicKeys, url);
      runningLocationRequests.add(locationRequest);
    }

    var reportsForAccessories = await Future.wait(runningLocationRequests);
    int out = 0;
    Map<Accessory, Future<List<Pair<dynamic, dynamic>>>> historyEntries = {};
    for (var i = 0; i < currentAccessories.length; i++) {
      var accessory = currentAccessories.elementAt(i);
      var reports = reportsForAccessories.elementAt(i);
      out += reports.length;
      logger.i(
          '${reports.length} reports fetched for ${accessory.hashedPublicKey} in total');

      if (reports.where((element) => !element.isEncrypted()).isNotEmpty) {
        var lastReport =
            reports.where((element) => !element.isEncrypted()).first;
        var reportDate = lastReport.timestamp ?? DateTime.fromMicrosecondsSinceEpoch(0);
        // Skip this update entirely if the user cleared or restored
        // this accessory's history while this fetch was still in
        // flight — otherwise a stale server report (Apple's network
        // doesn't know about a purely local delete/restore) would
        // silently bring back the very date/location the user just
        // changed, since it's chronologically "newer" than whatever
        // was just set locally.
        var generationUnchanged =
            accessory.historyGeneration == generationAtFetchStart[accessory];
        if (generationUnchanged &&
            accessory.datePublished != null &&
            reportDate.isAfter(accessory.datePublished!)) {
          accessory.datePublished = reportDate;
          accessory.lastLocation =
              LatLng(lastReport.latitude!, lastReport.longitude!);

          // Update last battery status
          accessory.lastBatteryStatus = lastReport.batteryStatus;
          accessory.hasChangedFlag = true;
        }
      }
      historyEntries[accessory] = fillLocationHistory(
          reports, accessory, generationAtFetchStart[accessory]!);
    }
    // Store updated lastLocation and datePublished for accessories
    _storeAccessories();

    _storeHistory(historyEntries);

    initialLoadFinished = true;
    notifyListeners();
    return Future.value(out);
  }

  Future<void> _storeHistory(
      Map<Accessory, Future<List<Pair<dynamic, dynamic>>>>
          historyEntries) async {
    Map<String, List<Pair<dynamic, dynamic>>> historyEntriesAsJson = {};
    for (var entry in historyEntries.entries) {
      Accessory key = entry.key;
      Future<List<Pair<dynamic, dynamic>>> future = entry.value;
      List<Pair<dynamic, dynamic>> result = await future;
      // Previously entries older than 7 days were discarded here on every
      // save. That cap has been removed on purpose — the full history of
      // each accessory is now kept indefinitely in local storage, so it
      // can be exported in full at any time (see "Export Full History"
      // in the accessory export menu).
      historyEntriesAsJson[key.id] = result;
    }
    //find all accessories not in list (inactive or single item refresh)
    accessories
        .where((a) => !historyEntriesAsJson.keys.toList().contains(a.id))
        .forEach((a) {
      historyEntriesAsJson[a.id] = a.locationHistory;
    });

    // Custom objects like Pair can't be sent across an isolate boundary
    // directly, so first convert everything to plain, primitive
    // Maps/Lists on the main thread (cheap — it's just copying fields
    // via each Pair's own toJson()). The actual JSON *string*
    // serialization — the genuinely expensive part once history has
    // grown large, since the 7-day cap was removed — then runs on a
    // background isolate via compute(), so it can't block the UI
    // thread no matter how much history has accumulated.
    var primitiveMap = historyEntriesAsJson.map(
      (key, pairs) => MapEntry(key, pairs.map((p) => p.toJson()).toList()),
    );
    var historyJson = await compute(jsonEncode, primitiveMap);
    _storage.write(key: historyStorageKey, value: historyJson);
  }

  /// Persists the current in-memory location history of every accessory
  /// to storage as-is, without fetching anything new. Used after
  /// [Accessory.addLocationHistory] has been called directly (e.g. to
  /// restore a history backup) — the in-memory change alone wouldn't
  /// survive an app restart without this.
  Future<void> persistAllHistory() async {
    Map<String, List<dynamic>> historyEntriesAsJson = {
      for (var a in _accessories)
        a.id: a.locationHistory.map((p) => p.toJson()).toList(),
    };
    var historyJson = await compute(jsonEncode, historyEntriesAsJson);
    await _storage.write(key: historyStorageKey, value: historyJson);
    // A restore can also update an accessory's datePublished (to show
    // "last updated" again after a restore) — persist that too, not
    // just the history entries themselves.
    await _storeAccessories();
    notifyListeners();
  }

  /// Stores the user's accessories in persistent storage.
  Future<void> _storeAccessories() async {
    List jsonList = _accessories.map(jsonEncode).toList();
    await _storage.write(key: accessoryStorageKey, value: jsonList.toString());
  }

  /// Returns the existing accessory with the same [hashedPublicKey], if
  /// any — used to warn the user (with the existing accessory's name)
  /// before importing the same accessory a second time under a
  /// different name. Re-importing used to silently swap the old
  /// accessory object for a new one, which could leave stale UI state
  /// pointing at the now-removed object, and reset its in-memory
  /// history to empty until the next full app restart.
  Accessory? findDuplicateAccessory(String hashedPublicKey) {
    for (var a in _accessories) {
      if (a.hashedPublicKey == hashedPublicKey) {
        return a;
      }
    }
    return null;
  }

  /// Adds [accessory] to the registry. Callers are expected to have
  /// already checked [findDuplicateAccessory] themselves so a currently
  /// ACTIVE duplicate is never silently replaced — this method's own
  /// "replace if hashedPublicKey matches" fallback below only matters
  /// for edge cases like [editAccessory].
  Future<void> addAccessory(Accessory accessory) async {
    Accessory? foundOne;
    for (var acc in _accessories) {
      if (accessory.hashedPublicKey == acc.hashedPublicKey) {
        foundOne = acc;
        break; // There is already one with this id
      }
    }
    if (foundOne != null) {
      _accessories.remove(foundOne);
    }

    _accessories.add(accessory);
    _storeAccessories();
    notifyListeners();
  }

  /// Removes [accessory] from this registry — permanently, including its
  /// location history. There is no backup/undo: the UI is expected to
  /// have already asked the user to confirm this (see
  /// AccessoryDetail's "Delete Accessory" button), warning that the
  /// accessory AND its history will be erased for good.
  void removeAccessory(Accessory accessory) {
    _accessories.remove(accessory);
    accessory.getHashedPublicKey().then((publicKey) {
      _storage.delete(key: publicKey);
    });

    _removeHistoryEntry(accessory);

    _storeAccessories();
    notifyListeners();
  }

  Future<List<Pair<dynamic, dynamic>>> fillLocationHistory(
      List<FindMyLocationReport> reports, Accessory accessory,
      int generationAtFetchStart) async {
    List<FindMyLocationReport> decryptedReports = [];
    //Decrypt only reports that are not already decrypted
    Set<String> hashes = {};
    int count = 0;
    //This will be achieved by saving the hash(payload) of all already decrypted reports
    for (var i = 0; i < reports.length; i++) {
      var currHash = reports[i].hash;
      if (!accessory.containsHash(currHash)) {
        accessory.addDecryptedHash(currHash);
        logger.d('Decrypting report $i of ${reports.length} with id $currHash');
        await reports[i].decrypt();
        decryptedReports.add(reports[i]);
      } else {
        count++;
      }

      hashes.add(currHash!);
    }
    logger.d(
        '${reports.length - count} reports decrypted. Decryption of $count reports skipped, because they are already fetched and decrypted.');
    //All hashes, that are not in the reports anymore can be deleted, because they are out of time
    accessory.removeOldHashes();
    //Sort by date
    decryptedReports.sort((a, b) {
      var aDate = a.timestamp ?? DateTime(1970);
      var bDate = b.timestamp ?? DateTime(1970);
      return aDate.compareTo(bDate);
    });

    //Update the latest timestamp
    if (decryptedReports.isNotEmpty) {
      var lastReport = decryptedReports[decryptedReports.length - 1];
      var oldTs = accessory.datePublished;
      var latestReportTS =
          lastReport.timestamp ??  DateTime(1971);

      // Same protection as the history-merge guard below: don't let a
      // fetch that started before a Delete or Restore silently bring
      // back the pre-change date/location once it finishes.
      var generationUnchanged =
          accessory.historyGeneration == generationAtFetchStart;
      if (generationUnchanged &&
          (oldTs == null || oldTs.isBefore(latestReportTS))) {
        //only an actualization if oldTS is not set or is older than the latest of the new ones
        accessory.lastLocation =
            LatLng(lastReport.latitude!, lastReport.longitude!);
        accessory.datePublished = latestReportTS;

        //Update alway battery status
        accessory.lastBatteryStatus = lastReport.batteryStatus;

        accessory.hasChangedFlag = true;

        notifyListeners(); //redraw the UI, if the timestamp has changed
      }
    }

//add to history in correct order — but only if the user hasn't cleared
    // this accessory's history while we were fetching/decrypting; if
    // they have, these results are stale and merging them would
    // silently undo the deletion.
    if (accessory.historyGeneration != generationAtFetchStart) {
      logger.d(
          'Skipping history merge for ${accessory.name} — history was cleared while this fetch was in flight.');
      return accessory.locationHistory;
    }
    for (var i = 0; i < decryptedReports.length; i++) {
      FindMyLocationReport report = decryptedReports[i];
      if (report.longitude!.abs() <= 180 && report.latitude!.abs() <= 90) {
        accessory.addLocationHistoryEntry(report);
      } else {
        logger.d(
            'Report skipped, because of anomaly data (lat: ${report.latitude}, lon: ${report.longitude}, acc: ${report.accuracy})');
      }
    }
    _storeAccessories();
    return accessory.locationHistory;
  }

  /// Updates [oldAccessory] with the values from [newAccessory].
  void editAccessory(Accessory oldAccessory, Accessory newAccessory) {
    oldAccessory.update(newAccessory);
    _storeAccessories();
    notifyListeners();
  }

  void clearInvalidAccessories(List<Accessory> loadedAccessories) async {
    List<int> indicesToRemove = [];
    for (int i = 0; i < accessories.length; i++) {
      bool containsKey =
          await _storage.containsKey(key: accessories[i].hashedPublicKey);
      if (!containsKey) {
        // Invalid Element should be removed
        indicesToRemove.add(i);
      }
    }
    for (int index in indicesToRemove.reversed) {
      loadedAccessories.removeAt(index);
    }
  }

  /// Clears the recorded location history of [accessory], including
  /// its current known location, battery status and "last seen" date
  /// — a full reset back to "never located", not just the history
  /// trail. (Unlike [deleteData], the accessory itself, its keys, and
  /// its name/icon/color stay — only location-derived data is wiped.)
  Future<void> clearHistory(Accessory accessory) async {
    accessory.locationHistory.clear();
    accessory.historyGeneration++;
    accessory.datePublished = DateTime(1970);
    accessory.lastLocation = null;
    accessory.lastBatteryStatus = null;
    await _removeHistoryEntry(accessory);
    _storeAccessories();
    notifyListeners();
  }

  void deleteData(Accessory accessory) {
    accessory.lastBatteryStatus = null;
    accessory.lastLocation = null;
    accessory.hashesWithTS.clear();
    accessory.datePublished = DateTime(1970);
    accessory.place = Future.value(null);
    accessory.locationHistory.clear();
    accessory.historyGeneration++;
    _removeHistoryEntry(accessory);
    _storeAccessories();
    notifyListeners();
  }

  Future<void> _removeHistoryEntry(Accessory accessoryToRemove) async {
    String? history = await _storage.read(key: historyStorageKey);
    if (history == null || history.isEmpty) {
      return;
    }
    Map<String, dynamic> historyMap = await compute(
        (String source) => jsonDecode(source) as Map<String, dynamic>,
        history);

    historyMap.remove(accessoryToRemove.id);

    var newHistoryJson = await compute(jsonEncode, historyMap);
    await _storage.write(key: historyStorageKey, value: newHistoryJson);
  }

  void saveOrderUpdates(List<Accessory> newOrder) {
    final Map<Accessory, int> positionMap = {
      for (int i = 0; i < newOrder.length; i++) newOrder[i]: i,
    };
    _accessories.sort((a, b) => positionMap[a]!.compareTo(positionMap[b]!));
    _storeAccessories();
  }
}
