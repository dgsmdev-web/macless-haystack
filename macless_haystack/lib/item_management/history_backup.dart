import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/item_management/kml_export.dart' show safeFilename;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:universal_html/html.dart' as html;

/// Saves the accessory's entire location history (every day that has
/// ever been recorded, not just the currently-checked days) as a JSON
/// file, and hands it off the same way "Export history (KML)" does —
/// the share sheet on mobile, a direct download on web. Unlike the KML
/// export, this file can be read back in via [restoreHistoryFromFile]
/// to restore the history later (e.g. after reinstalling the app).
Future<void> backupHistoryAsJson(
  String accessoryName,
  List<Pair<dynamic, dynamic>> history,
) async {
  final filename = '${safeFilename(accessoryName)}_history_backup.json';
  final jsonContent = jsonEncode(history.map((p) => p.toJson()).toList());

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

/// Lets the user pick a previously-created backup file (see
/// [backupHistoryAsJson]) and parses it back into a list of history
/// entries. Returns null if the user cancelled the picker, or throws
/// a [FormatException] if the chosen file isn't a valid backup — the
/// caller is expected to show that error to the user.
Future<List<Pair<dynamic, dynamic>>?> restoreHistoryFromFile() async {
  FilePickerResult? result = await FilePicker.platform.pickFiles(
    allowMultiple: false,
    type: FileType.custom,
    allowedExtensions: ['json'],
    dialogTitle: 'Select history backup file',
  );

  if (result == null) {
    return null;
  }

  String jsonContent;
  var bytes = result.files.single.bytes;
  if (bytes != null) {
    jsonContent = utf8.decode(bytes);
  } else if (result.paths.isNotEmpty && result.paths[0] != null) {
    jsonContent = await File(result.paths[0]!).readAsString();
  } else {
    throw const FormatException('Could not read the selected file.');
  }

  var decoded = jsonDecode(jsonContent);
  if (decoded is! List) {
    throw const FormatException(
        'This file is not a valid history backup (expected a list of entries).');
  }

  return decoded
      .map((item) => Pair.fromJson(item as Map<String, dynamic>))
      .toList();
}
