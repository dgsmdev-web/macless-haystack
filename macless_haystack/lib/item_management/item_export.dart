import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_dto.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/item_management/diagnostic_report.dart';
import 'package:macless_haystack/item_management/kml_export.dart';
import 'package:share_plus/share_plus.dart';

import 'package:universal_html/html.dart' as html;

import 'package:flutter/foundation.dart' show kIsWeb;

class ItemExportMenu extends StatelessWidget {
  /// The accessory to export from
  final Accessory accessory;

  /// Displays a bottom sheet with export options.
  ///
  /// The accessory can be exported to a JSON file or the
  /// key parameters can be exported separately.
  const ItemExportMenu({
    super.key,
    required this.accessory,
  });

  /// Shows the export options for the [accessory]. [outerContext] is the
  /// context of the page this menu was opened from — kept separate from
  /// the bottom sheet's own inner builder context (below), since the
  /// sheet's context stops being valid the instant the sheet closes,
  /// while outerContext stays mounted for as long as the page itself is
  /// on screen.
  void showKeyExportSheet(BuildContext outerContext, Accessory accessory) {
    showModalBottomSheet(
        context: outerContext,
        builder: (BuildContext context) {
          return SafeArea(
            child: ListView(
              physics: const NeverScrollableScrollPhysics(),
              shrinkWrap: true,
              children: [
                ListTile(
                  title: const Text('Export Accessory (JSON)'),
                  subtitle: const Text(
                      'Share this tag with someone else so they can import it'),
                  onTap: () async {
                    await _exportAccessoriesAsJSON([accessory]);
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  },
                ),
                ListTile(
                  title:
                      const Text('Export Full History (KML for Google Maps)'),
                  subtitle: const Text(
                      'Every recorded location since this tag was added, as a track viewable in Google Maps/Earth'),
                  onTap: () async {
                    await exportHistoryAsKML(
                        accessory.name, accessory.getSortedLocationHistory());
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  },
                ),
                ListTile(
                  title: const Text('Diagnostic Report (JSON)'),
                  subtitle: const Text(
                      'Asks Apple for each key of this tag separately and saves how many reports came back'),
                  onTap: () {
                    // Same reasoning as Delete below: close the sheet
                    // first, then work with the OUTER page context,
                    // because this sheet's context dies with the sheet.
                    Navigator.pop(context);
                    _runDiagnosticReport(outerContext, accessory);
                  },
                ),
                ListTile(
                  title: const Text(
                    'Delete All History',
                    style: TextStyle(color: Colors.red),
                  ),
                  subtitle: const Text(
                      'Permanently erases all recorded location points for this tag — cannot be undone'),
                  onTap: () {
                    // Close the export sheet first, then run the
                    // confirm-and-delete flow using the OUTER page
                    // context (captured below as `outerContext`) —
                    // not this sheet's own inner `context`, which
                    // becomes unmounted the instant the sheet closes.
                    // Using the now-dead inner context here silently
                    // no-ops the whole delete (the `context.mounted`
                    // guard in _confirmAndDeleteHistory quietly skips
                    // it), which is why "Delete" previously appeared
                    // to do nothing.
                    Navigator.pop(context);
                    _confirmAndDeleteHistory(outerContext, accessory);
                  },
                ),
              ],
            ),
          );
        });
  }

  /// Collects the diagnostic report while showing a blocking spinner —
  /// it makes one network request per key plus one combined request, so
  /// it can take a while and must not look like the tap did nothing.
  Future<void> _runDiagnosticReport(
      BuildContext context, Accessory accessory) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return const AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Expanded(
                  child: Text('Collecting diagnostic report...')),
            ],
          ),
        );
      },
    );

    String? error;
    try {
      await exportDiagnosticReport(accessory);
    } catch (e) {
      error = e.toString();
    }

    if (context.mounted) {
      // Close the spinner dialog.
      Navigator.of(context, rootNavigator: true).pop();
    }
    if (error != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Diagnostic report failed: $error')),
      );
    }
  }

  /// Shows a confirmation dialog before permanently wiping [accessory]'s
  /// location history. Only proceeds if the user explicitly confirms.
  Future<void> _confirmAndDeleteHistory(
      BuildContext context, Accessory accessory) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Delete All History?'),
          content: Text(
              'This will permanently delete all recorded location history for "${accessory.name}". '
              'The current known location and battery status are kept — only the history trail is erased. '
              'This cannot be undone.'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Delete'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
            ),
          ],
        );
      },
    );

    if (confirmed == true && context.mounted) {
      await Provider.of<AccessoryRegistry>(context, listen: false)
          .clearHistory(accessory);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('History deleted for "${accessory.name}".')),
        );
      }
    }
  }

  /// Export the serialized [accessories] as a JSON file.
  ///
  /// The OpenHaystack export format is used for interoperability with
  /// the desktop app. The filename includes the accessory's own name
  /// (sanitized) so it's clear which tag the file belongs to.
  Future<void> _exportAccessoriesAsJSON(List<Accessory> accessories) async {
    final filename = accessories.length == 1
        ? '${safeFilename(accessories.first.name)}.json'
        : 'accessories.json';
    // Convert accessories to export format
    List<AccessoryDTO> exportAccessories = [];
    for (Accessory accessory in accessories) {
      String privateKey = await accessory.getPrivateKey();

      List<String> additionalPrivateKeys =
          await accessory.getAdditionalPrivateKeys();

      exportAccessories.add(AccessoryDTO(
          id: int.tryParse(accessory.id) ?? 0,
          colorComponents: [
            accessory.color.r / 255,
            accessory.color.g / 255,
            accessory.color.b / 255,
            accessory.color.a,
          ],
          name: accessory.name,
          privateKey: privateKey,
          icon: accessory.rawIcon,
          isActive: accessory.isActive,
          additionalKeys: additionalPrivateKeys));
    }
    JsonEncoder encoder = const JsonEncoder.withIndent('  '); // format output
    String encodedAccessories = encoder.convert(exportAccessories);

    if (kIsWeb) {
      final blob =
          html.Blob([encodedAccessories], 'application/json', 'native');
      final url = html.Url.createObjectUrlFromBlob(blob);

      html.AnchorElement(href: url)
        ..setAttribute('download', filename)
        ..click();

      html.Url.revokeObjectUrl(url);
    } else {
      // Create temporary directory to store export file
      Directory tempDir = await getTemporaryDirectory();
      String path = tempDir.path;

      // Create file and write accessories as json

      File file = File('$path/$filename');

      await file.writeAsString(encodedAccessories);
      // Share export file over os share dialog

      Share.shareXFiles(
        [XFile(file.path)],
        subject: filename,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () {
        showKeyExportSheet(context, accessory);
      },
      icon: const Icon(Icons.open_in_new),
    );
  }
}
