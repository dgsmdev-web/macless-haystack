import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/findMy/find_my_controller.dart';
import 'package:macless_haystack/findMy/reports_fetcher.dart';
import 'package:macless_haystack/item_management/kml_export.dart'
    show safeFilename;
import 'package:macless_haystack/preferences/user_preferences_model.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:universal_html/html.dart' as html;

/// Builds a diagnostic report for [accessory] and hands it off as a JSON
/// file the same way the KML export and history backup do — the share
/// sheet on mobile, a direct download on web.
///
/// The point of this report is to answer one question that nothing else
/// in the app can answer: **does Apple actually return location reports
/// for every key this tag rotates through, or only for some of them?**
///
/// To find out, it asks the endpoint for each key SEPARATELY and counts
/// the reports, then asks for all keys AT ONCE and counts again. If the
/// combined query returns noticeably fewer reports than the individual
/// queries added up, Apple is truncating multi-key requests — which
/// would silently cost the tag most of its track, since the app always
/// queries all keys together.
///
/// No private keys are written to the file. Only hashed advertisement
/// keys, which are exactly what already gets sent to Apple.
Future<void> exportDiagnosticReport(Accessory accessory) async {
  final startedAt = DateTime.now();

  final url = Settings.getValue<String>(endpointUrl);
  final effectiveUrl =
      (url == null || url.isEmpty) ? 'http://localhost:6176' : url;
  final user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
  final pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;
  final days =
      Settings.getValue<int>(numberOfDaysToFetch, defaultValue: 7)!;

  // Same key order the app itself uses when fetching: the additional
  // keys first, the tag's main key last.
  final hashedAdvertisementKeys = <String>[];
  for (final hashedPublicKey in accessory.additionalKeys) {
    final kp = await FindMyController.getKeyPair(hashedPublicKey);
    hashedAdvertisementKeys.add(kp.getHashedAdvertisementKey());
  }
  final mainKeyPair =
      await FindMyController.getKeyPair(accessory.hashedPublicKey);
  hashedAdvertisementKeys.add(mainKeyPair.getHashedAdvertisementKey());

  // --- one key at a time ---------------------------------------------------
  final perKey = <Map<String, dynamic>>[];
  var sumOfIndividual = 0;
  var keysWithReports = 0;
  var keysFailed = 0;

  for (var i = 0; i < hashedAdvertisementKeys.length; i++) {
    final hash = hashedAdvertisementKeys[i];
    final isMain = i == hashedAdvertisementKeys.length - 1;
    try {
      final reports = await ReportsFetcher.fetchLocationReports(
          [hash], days, effectiveUrl, user, pass);
      sumOfIndividual += reports.length;
      if (reports.isNotEmpty) {
        keysWithReports++;
      }
      perKey.add({
        'index': i + 1,
        'isMainKey': isMain,
        'hashedAdvertisementKey': hash,
        'reportCount': reports.length,
        'error': null,
      });
    } catch (e) {
      keysFailed++;
      perKey.add({
        'index': i + 1,
        'isMainKey': isMain,
        'hashedAdvertisementKey': hash,
        'reportCount': null,
        'error': e.toString(),
      });
    }
  }

  // --- all keys in a single request (what the app normally does) -----------
  int? combinedCount;
  String? combinedError;
  try {
    final reports = await ReportsFetcher.fetchLocationReports(
        hashedAdvertisementKeys, days, effectiveUrl, user, pass);
    combinedCount = reports.length;
  } catch (e) {
    combinedError = e.toString();
  }

  // --- what the stored history looks like ----------------------------------
  final history = accessory.getSortedLocationHistory();
  final gapsMinutes = <double>[];
  var singlePointEntries = 0;
  for (var i = 0; i < history.length; i++) {
    final entry = history[i];
    if (entry.start.isAtSameMomentAs(entry.end)) {
      singlePointEntries++;
    }
    if (i > 0) {
      final gap =
          entry.start.difference(history[i - 1].end).inSeconds / 60.0;
      gapsMinutes.add(gap);
    }
  }
  gapsMinutes.sort();

  double? median;
  if (gapsMinutes.isNotEmpty) {
    final mid = gapsMinutes.length ~/ 2;
    median = gapsMinutes.length.isOdd
        ? gapsMinutes[mid]
        : (gapsMinutes[mid - 1] + gapsMinutes[mid]) / 2;
  }

  // --- plain-language conclusions ------------------------------------------
  final verdict = <String>[];
  if (keysFailed == hashedAdvertisementKeys.length) {
    verdict.add(
        'The endpoint could not be reached at all — check the URL, login and '
        'that the anisette and endpoint containers are running.');
  } else if (sumOfIndividual == 0) {
    verdict.add(
        'Apple returned no reports for any key. This is not a key problem: '
        'check that the endpoint is still registered with the Apple ID.');
  } else {
    if (keysWithReports == hashedAdvertisementKeys.length) {
      verdict.add(
          'All ${hashedAdvertisementKeys.length} keys returned reports — every '
          'key this tag broadcasts is being harvested.');
    } else {
      verdict.add(
          'Only $keysWithReports of ${hashedAdvertisementKeys.length} keys '
          'returned reports. The keys with a count of 0 are either not going '
          'out on air, or the app is asking Apple about the wrong key.');
    }
    if (combinedCount != null && combinedCount + 5 < sumOfIndividual) {
      verdict.add(
          'IMPORTANT: asking for all keys at once returned $combinedCount '
          'reports, but asking one key at a time returned $sumOfIndividual in '
          'total. Apple is truncating multi-key requests — the endpoint '
          'should query keys one at a time and merge the results.');
    } else if (combinedCount != null) {
      verdict.add(
          'The combined query and the sum of individual queries agree — no '
          'truncation by number of keys.');
    }
  }
  verdict.add(
      'Run this again with a different "days to fetch" setting: if 7 days '
      'returns the same number as 1 day, Apple is only keeping a limited '
      'number of reports per key and older ones are being pushed out.');

  // --- assemble ------------------------------------------------------------
  final report = {
    'reportVersion': 1,
    'generatedAt': startedAt.toIso8601String(),
    'tookSeconds': DateTime.now().difference(startedAt).inSeconds,
    'accessory': {
      'id': accessory.id,
      'name': accessory.name,
      'isActive': accessory.isActive,
      'totalKeys': hashedAdvertisementKeys.length,
      'additionalKeyCount': accessory.additionalKeys.length,
    },
    'settings': {
      'endpointUrl': effectiveUrl,
      'endpointAuthEnabled': user.isNotEmpty || pass.isNotEmpty,
      'daysToFetch': days,
    },
    'perKey': perKey,
    'sumOfIndividualQueries': sumOfIndividual,
    'combinedQuery': {
      'reportCount': combinedCount,
      'error': combinedError,
    },
    'storedHistory': {
      'entryCount': history.length,
      'singlePointEntries': singlePointEntries,
      'mergedEntries': history.length - singlePointEntries,
      'firstEntry':
          history.isEmpty ? null : history.first.start.toIso8601String(),
      'lastEntry': history.isEmpty ? null : history.last.end.toIso8601String(),
      'gapMinutes': {
        'median': median,
        'min': gapsMinutes.isEmpty ? null : gapsMinutes.first,
        'max': gapsMinutes.isEmpty ? null : gapsMinutes.last,
      },
    },
    'verdict': verdict,
  };

  final stamp = '${startedAt.year}'
      '${startedAt.month.toString().padLeft(2, '0')}'
      '${startedAt.day.toString().padLeft(2, '0')}_'
      '${startedAt.hour.toString().padLeft(2, '0')}'
      '${startedAt.minute.toString().padLeft(2, '0')}';
  final filename =
      '${safeFilename(accessory.name)}_diagnostic_$stamp.json';

  const encoder = JsonEncoder.withIndent('  ');
  final jsonContent = encoder.convert(report);

  if (kIsWeb) {
    final blob = html.Blob([jsonContent], 'application/json', 'native');
    final url = html.Url.createObjectUrlFromBlob(blob);

    html.AnchorElement(href: url)
      ..setAttribute('download', filename)
      ..click();

    html.Url.revokeObjectUrl(url);
  } else {
    Directory tempDir = await getTemporaryDirectory();
    File file = File('${tempDir.path}/$filename');
    await file.writeAsString(jsonContent);

    Share.shareXFiles(
      [XFile(file.path)],
      subject: filename,
    );
  }
}
