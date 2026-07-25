import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:macless_haystack/accessory/accessory_dto.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
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

  /// Shows the export options for the [accessory].
  void showKeyExportSheet(BuildContext context, Accessory accessory) {
    showModalBottomSheet(
        context: context,
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
                  title: const Text('Export History (KML for Google Maps)'),
                  subtitle: const Text(
                      'All recorded locations as a track, viewable in Google Maps/Earth'),
                  onTap: () async {
                    await exportHistoryAsKML(
                        accessory.name, accessory.getSortedLocationHistory());
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  },
                ),
              ],
            ),
          );
        });
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
