import 'dart:collection';
import 'dart:convert';
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
const historyBackupStorageKey = 'HISTORY_BACKUP';
const historyBackupTimestampKey = 'HISTORY_BACKUP_TS';
const deletedAccessoriesIndexKey = 'DELETED_ACCESSORIES_INDEX';

class AccessoryRegistry extends ChangeNotifier {
  var _storage = const FlutterSecureStorage();
  List<Accessory> _accessories = [];
  bool loading = false;
  bool initialLoadFinished = false;

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
      Map<String, dynamic> jsonDecoded = jsonDecode(history);
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
        if (accessory.datePublished != null &&
            reportDate.isAfter(accessory.datePublished!)) {
          accessory.datePublished = reportDate;
          accessory.lastLocation =
              LatLng(lastReport.latitude!, lastReport.longitude!);

          // Update last battery status
          accessory.lastBatteryStatus = lastReport.batteryStatus;
          accessory.hasChangedFlag = true;
        }
      }
      historyEntries[accessory] = fillLocationHistory(reports, accessory);
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

    await _snapshotHistoryBackupIfDue();

    var historyJson = jsonEncode(historyEntriesAsJson);
    _storage.write(key: historyStorageKey, value: historyJson);
  }

  /// Copies whatever is CURRENTLY on disk under [historyStorageKey] into
  /// a separate backup slot, but only if the last backup is more than an
  /// hour old (or there isn't one yet). This gives a rolling "how things
  /// looked at least ~1 hour ago" safety net — cheap (one extra slot,
  /// refreshed at most hourly) but enough to recover from an accidental
  /// overwrite (e.g. a bug that briefly makes an accessory's in-memory
  /// history empty right before a save) without keeping unlimited
  /// history versions.
  Future<void> _snapshotHistoryBackupIfDue() async {
    try {
      String? lastBackupTsStr =
          await _storage.read(key: historyBackupTimestampKey);
      DateTime? lastBackupTs =
          lastBackupTsStr != null ? DateTime.tryParse(lastBackupTsStr) : null;
      var dueForBackup = lastBackupTs == null ||
          DateTime.now().difference(lastBackupTs) > const Duration(hours: 1);
      if (!dueForBackup) {
        return;
      }

      String? currentHistory = await _storage.read(key: historyStorageKey);
      if (currentHistory == null) {
        return; // nothing saved yet, nothing to back up
      }
      await _storage.write(
          key: historyBackupStorageKey, value: currentHistory);
      await _storage.write(
          key: historyBackupTimestampKey,
          value: DateTime.now().toIso8601String());
    } catch (e) {
      logger.w('Could not create history backup snapshot: $e');
    }
  }

  /// Merges the history stored in the rolling backup slot back into the
  /// current accessories, WITHOUT discarding any current data — entries
  /// already present (matched by identical start+end timestamps) are
  /// skipped, everything else from the backup is added back in. Returns
  /// how many location points were actually recovered (0 if the backup
  /// is empty, missing, or already fully covered by current data).
  Future<int> restoreHistoryFromBackup() async {
    String? backup = await _storage.read(key: historyBackupStorageKey);
    if (backup == null) {
      return 0;
    }

    Map<String, dynamic> backupDecoded = jsonDecode(backup);
    int recoveredCount = 0;

    for (var accessory in _accessories) {
      var backupEntriesRaw = backupDecoded[accessory.id];
      if (backupEntriesRaw == null) {
        continue;
      }
      List<Pair<dynamic, dynamic>> backupEntries =
          (backupEntriesRaw as List).map((item) => Pair.fromJson(item)).toList();

      var existingKeys = accessory.locationHistory
          .map((p) => '${p.start.toIso8601String()}_${p.end.toIso8601String()}')
          .toSet();

      for (var backupEntry in backupEntries) {
        var key =
            '${backupEntry.start.toIso8601String()}_${backupEntry.end.toIso8601String()}';
        if (!existingKeys.contains(key)) {
          accessory.locationHistory.add(backupEntry);
          existingKeys.add(key);
          recoveredCount++;
        }
      }

      accessory.locationHistory.sort((a, b) => a.end.compareTo(b.end));
    }

    if (recoveredCount > 0) {
      // Persist the merged result. Bypasses the normal fetch-based
      // _storeHistory path since we already have the final in-memory
      // state for every accessory here.
      Map<String, List<Pair<dynamic, dynamic>>> merged = {
        for (var a in _accessories) a.id: a.locationHistory
      };
      await _storage.write(key: historyStorageKey, value: jsonEncode(merged));
      notifyListeners();
    }

    return recoveredCount;
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
  ///
  /// If this accessory (by id) was previously deleted and its old
  /// location history is still sitting in storage, it's automatically
  /// merged back in here — this is the "restore on re-add" behaviour.
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

    await _restoreHistoryIfPreviouslyDeleted(accessory);

    _accessories.add(accessory);
    _storeAccessories();
    notifyListeners();
  }

  /// If [accessory]'s history is still present in storage from before it
  /// was deleted (deleting an accessory does NOT wipe its history — see
  /// [removeAccessory]), loads it straight into [accessory] and clears
  /// the matching "deleted" index entry. Silently does nothing if there
  /// is nothing to restore.
  Future<void> _restoreHistoryIfPreviouslyDeleted(Accessory accessory) async {
    try {
      String? history = await _storage.read(key: historyStorageKey);
      if (history == null) return;
      Map<String, dynamic> jsonDecoded = jsonDecode(history);
      var existing = jsonDecoded[accessory.id];
      if (existing != null) {
        accessory.addLocationHistory(existing);
      }
      await _removeFromDeletedIndex(accessory.id);
    } catch (e) {
      logger.w('Could not check for previously deleted history: $e');
    }
  }

  /// Removes [accessory] from this registry. The accessory's location
  /// history is intentionally NOT deleted from storage — it's kept as a
  /// backup and automatically restored if this same accessory (by id)
  /// is ever added again (see [addAccessory]). A small entry is added
  /// to the "deleted accessories" index so it can be reviewed/purged
  /// permanently later (see [getDeletedAccessoriesIndex] and
  /// [purgeDeletedAccessoryHistory]).
  void removeAccessory(Accessory accessory) {
    _accessories.remove(accessory);
    accessory.getHashedPublicKey().then((publicKey) {
      _storage.delete(key: publicKey);
    });

    _addToDeletedIndex(accessory);

    _storeAccessories();
    notifyListeners();
  }

  Future<void> _addToDeletedIndex(Accessory accessory) async {
    try {
      String? raw = await _storage.read(key: deletedAccessoriesIndexKey);
      List<dynamic> index = raw != null ? jsonDecode(raw) : [];
      index.removeWhere((e) => e['id'] == accessory.id);
      index.add({
        'id': accessory.id,
        'name': accessory.name,
        'deletedAt': DateTime.now().toIso8601String(),
      });
      await _storage.write(
          key: deletedAccessoriesIndexKey, value: jsonEncode(index));
    } catch (e) {
      logger.w('Could not update deleted-accessories index: $e');
    }
  }

  Future<void> _removeFromDeletedIndex(String id) async {
    try {
      String? raw = await _storage.read(key: deletedAccessoriesIndexKey);
      if (raw == null) return;
      List<dynamic> index = jsonDecode(raw);
      index.removeWhere((e) => e['id'] == id);
      await _storage.write(
          key: deletedAccessoriesIndexKey, value: jsonEncode(index));
    } catch (e) {
      logger.w('Could not update deleted-accessories index: $e');
    }
  }

  /// Returns the list of deleted accessories that still have recoverable
  /// history sitting in storage — each entry has 'id', 'name' (as it was
  /// when deleted) and 'deletedAt'. For display in a management screen.
  Future<List<Map<String, dynamic>>> getDeletedAccessoriesIndex() async {
    try {
      String? raw = await _storage.read(key: deletedAccessoriesIndexKey);
      if (raw == null) return [];
      List<dynamic> index = jsonDecode(raw);
      return index.cast<Map<String, dynamic>>();
    } catch (e) {
      logger.w('Could not read deleted-accessories index: $e');
      return [];
    }
  }

  /// Permanently erases the stored location history for a deleted
  /// accessory (by [id]) and removes it from the deleted-accessories
  /// index. This is a one-way action — after this, re-adding that
  /// accessory will no longer auto-restore its old history.
  Future<void> purgeDeletedAccessoryHistory(String id) async {
    try {
      String? history = await _storage.read(key: historyStorageKey);
      if (history != null) {
        Map<String, dynamic> jsonDecoded = jsonDecode(history);
        jsonDecoded.remove(id);
        await _storage.write(
            key: historyStorageKey, value: jsonEncode(jsonDecoded));
      }
    } catch (e) {
      logger.w('Could not purge history for $id: $e');
    }
    await _removeFromDeletedIndex(id);
  }

  Future<List<Pair<dynamic, dynamic>>> fillLocationHistory(
      List<FindMyLocationReport> reports, Accessory accessory) async {
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

      if (oldTs == null || oldTs.isBefore(latestReportTS)) {
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

//add to history in correct order
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

  /// Clears only the recorded location history of [accessory] — unlike
  /// [deleteData], this leaves the accessory's current known location,
  /// battery status and publish date untouched, so it still shows up
  /// correctly on the main map. Only the history trail (and its
  /// persisted storage entry) is wiped.
  Future<void> clearHistory(Accessory accessory) async {
    accessory.locationHistory.clear();
    await _removeHistoryEntry(accessory);
    notifyListeners();
  }

  void deleteData(Accessory accessory) {
    accessory.lastBatteryStatus = null;
    accessory.lastLocation = null;
    accessory.hashesWithTS.clear();
    accessory.datePublished = DateTime(1970);
    accessory.place = Future.value(null);
    accessory.locationHistory.clear();
    _removeHistoryEntry(accessory);
    _storeAccessories();
    notifyListeners();
  }

  Future<void> _removeHistoryEntry(Accessory accessoryToRemove) async {
    String? history = await _storage.read(key: historyStorageKey);
    if (history == null || history.isEmpty) {
      return;
    }
    Map<String, dynamic> historyMap = jsonDecode(history);

    historyMap.remove(accessoryToRemove.id);

    await _storage.write(key: historyStorageKey, value: jsonEncode(historyMap));
  }

  void saveOrderUpdates(List<Accessory> newOrder) {
    final Map<Accessory, int> positionMap = {
      for (int i = 0; i < newOrder.length; i++) newOrder[i]: i,
    };
    _accessories.sort((a, b) => positionMap[a]!.compareTo(positionMap[b]!));
    _storeAccessories();
  }
}
