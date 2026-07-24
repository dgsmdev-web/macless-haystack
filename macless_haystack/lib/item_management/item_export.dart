import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_dto.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
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
                  trailing: IconButton(
                    onPressed: () {
                      _showKeyExplanationAlert(context);
                    },
                    icon: const Icon(Icons.info),
                  ),
                ),
                ListTile(
                  title: const Text('Export All Accessories (JSON)'),
                  onTap: () async {
                    var accessories =
                        Provider.of<AccessoryRegistry>(context, listen: false)
                            .accessories;
                    await _exportAccessoriesAsJSON(accessories);
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  },
                ),
                ListTile(
                  title: const Text('Export Accessory (JSON)'),
                  onTap: () async {
                    await _exportAccessoriesAsJSON([accessory]);
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  },
                ),
                ListTile(
                  title: const Text('Export Hashed Advertisement Key (Base64)'),
                  onTap: () async {
                    var advertisementKey =
                        await accessory.getHashedAdvertisementKey();
                    Share.share(advertisementKey);
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  },
                ),
                ListTile(
                  title: const Text('Export Advertisement Key (Base64)'),
                  onTap: () async {
                    var advertisementKey =
                        await accessory.getAdvertisementKey();
                    Share.share(advertisementKey);
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  },
                ),
                ListTile(
                  title: const Text('Export Private Key (Base64)'),
                  onTap: () async {
                    var privateKey = await accessory.getPrivateKey();
                    Share.share(privateKey);
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
                    await _exportHistoryAsKML(accessory);
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
  /// the desktop app.
  Future<void> _exportAccessoriesAsJSON(List<Accessory> accessories) async {
    const filename = 'accessories.json';
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

  /// Export the full location history of [accessory] as a KML track file,
  /// viewable in Google Maps (My Maps import), Google Earth, or any other
  /// app/tool that supports the KML format.
  ///
  /// Includes both a single connected line (the track, in chronological
  /// order) and an individual placemark per recorded point with its
  /// timestamp, so both the overall path and individual stops can be
  /// inspected.
  Future<void> _exportHistoryAsKML(Accessory accessory) async {
    var history = accessory.getSortedLocationHistory();
    var safeName =
        accessory.name.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    final filename = '${safeName}_history.kml';

    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<kml xmlns="http://www.opengis.net/kml/2.2">');
    buffer.writeln('  <Document>');
    buffer.writeln('    <name>${_xmlEscape(accessory.name)}</name>');
    buffer.writeln('    <Style id="trackLine">');
    buffer.writeln('      <LineStyle><color>ff0000ff</color><width>4</width></LineStyle>');
    buffer.writeln('    </Style>');

    if (history.length > 1) {
      buffer.writeln('    <Placemark>');
      buffer.writeln(
          '      <name>${_xmlEscape(accessory.name)} track</name>');
      buffer.writeln('      <styleUrl>#trackLine</styleUrl>');
      buffer.writeln('      <LineString>');
      buffer.writeln('        <tessellate>1</tessellate>');
      buffer.writeln('        <coordinates>');
      for (var entry in history) {
        buffer.writeln(
            '          ${entry.location.longitude},${entry.location.latitude},0');
      }
      buffer.writeln('        </coordinates>');
      buffer.writeln('      </LineString>');
      buffer.writeln('    </Placemark>');
    }

    for (var entry in history) {
      buffer.writeln('    <Placemark>');
      buffer.writeln('      <name>${_xmlEscape(entry.start.toString())}</name>');
      buffer.writeln(
          '      <description>${_xmlEscape('${entry.start} - ${entry.end}')}</description>');
      buffer.writeln('      <Point>');
      buffer.writeln(
          '        <coordinates>${entry.location.longitude},${entry.location.latitude},0</coordinates>');
      buffer.writeln('      </Point>');
      buffer.writeln('    </Placemark>');
    }

    buffer.writeln('  </Document>');
    buffer.writeln('</kml>');
    final kmlContent = buffer.toString();

    if (kIsWeb) {
      final blob =
          html.Blob([kmlContent], 'application/vnd.google-earth.kml+xml', 'native');
      final url = html.Url.createObjectUrlFromBlob(blob);

      html.AnchorElement(href: url)
        ..setAttribute('download', filename)
        ..click();

      html.Url.revokeObjectUrl(url);
    } else {
      Directory tempDir = await getTemporaryDirectory();
      String path = tempDir.path;

      File file = File('$path/$filename');
      await file.writeAsString(kmlContent);

      Share.shareXFiles(
        [XFile(file.path)],
        subject: filename,
      );
    }
  }

  /// Escapes XML-sensitive characters for safe inclusion in the KML file.
  String _xmlEscape(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  /// Show an explanation how the different key types are used.
  Future<void> _showKeyExplanationAlert(BuildContext context) async {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Key Overview'),
          content: const SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text('Private Key:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text('Secret key used for location report decryption.'),
                Text('Advertisement Key:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text('Shortened public key sent out over Bluetooth.'),
                Text('Hashed Advertisement Key:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text('Used to retrieve location reports from the server'),
                Text('Accessory:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text('A file containing all information about the accessory.'),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Close'),
              onPressed: () {
                Navigator.of(context, rootNavigator: true).pop();
              },
            ),
          ],
        );
      },
    );
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
