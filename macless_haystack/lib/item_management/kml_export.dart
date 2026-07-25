import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:universal_html/html.dart' as html;

/// Turns a name into a safe filename fragment — keeps letters, digits,
/// underscores and dashes, replaces everything else (spaces, emoji,
/// punctuation) with an underscore.
String safeFilename(String input) {
  var safe = input.trim().replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
  return safe.isEmpty ? 'accessory' : safe;
}

/// Escapes XML-sensitive characters for safe inclusion in a KML file.
String _xmlEscape(String input) {
  return input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

/// Exports [history] (already filtered to whichever entries the caller
/// wants — e.g. the full track, or just a single day) as a KML track
/// file, viewable in Google Maps (My Maps import), Google Earth, or any
/// other app/tool that supports the KML format.
///
/// Includes both a single connected line (the track, in chronological
/// order) and an individual placemark per recorded point with its
/// timestamp, so both the overall path and individual stops can be
/// inspected. [nameSuffix], if given, is appended to the exported
/// filename (e.g. to indicate which day this export covers).
Future<void> exportHistoryAsKML(
  String accessoryName,
  List<Pair<dynamic, dynamic>> history, {
  String? nameSuffix,
}) async {
  final suffixPart = nameSuffix != null ? '_${safeFilename(nameSuffix)}' : '';
  final filename = '${safeFilename(accessoryName)}$suffixPart.kml';

  final buffer = StringBuffer();
  buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
  buffer.writeln('<kml xmlns="http://www.opengis.net/kml/2.2">');
  buffer.writeln('  <Document>');
  buffer.writeln('    <name>${_xmlEscape(accessoryName)}</name>');
  buffer.writeln('    <Style id="trackLine">');
  buffer.writeln(
      '      <LineStyle><color>ff0000ff</color><width>4</width></LineStyle>');
  buffer.writeln('    </Style>');

  if (history.length > 1) {
    buffer.writeln('    <Placemark>');
    buffer.writeln('      <name>${_xmlEscape(accessoryName)} track</name>');
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
    final blob = html.Blob(
        [kmlContent], 'application/vnd.google-earth.kml+xml', 'native');
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
