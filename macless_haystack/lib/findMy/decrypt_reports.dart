import 'dart:typed_data';

import 'package:pointycastle/export.dart';

// ignore: implementation_imports
import 'package:pointycastle/src/utils.dart' as pc_utils;
import 'package:macless_haystack/findMy/models.dart';
import 'package:macless_haystack/accessory/accessory_battery.dart';

class DecryptReports {
  /// Decrypts a given [FindMyReport] with the given private key.
  static Future<FindMyLocationReport> decryptReport(
      FindMyReport report, Uint8List key) async {
    final curveDomainParam = ECCurve_secp224r1();
    var payloadData = report.payload;
    if (payloadData.length > 88) {
      final modifiedData = Uint8List(payloadData.length - 1);
      modifiedData.setRange(0, 4, payloadData);
      modifiedData.setRange(4, modifiedData.length, payloadData, 5);
      payloadData = modifiedData;
    }

    final ephemeralKeyBytes = payloadData.sublist(5, 62);
    final encData = payloadData.sublist(62, 72);
    final tag = payloadData.sublist(72, payloadData.length);

    _decodeTimeAndConfidence(payloadData, report);

    final privateKey =
        ECPrivateKey(pc_utils.decodeBigIntWithSign(1, key), curveDomainParam);

    final decodePoint = curveDomainParam.curve.decodePoint(ephemeralKeyBytes);
    final ephemeralPublicKey = ECPublicKey(decodePoint, curveDomainParam);

    final Uint8List sharedKeyBytes = _ecdh(ephemeralPublicKey, privateKey);
    final Uint8List derivedKey = _kdf(sharedKeyBytes, ephemeralKeyBytes);

    final decryptedPayload = _decryptPayload(encData, derivedKey, tag);
    final locationReport = _decodePayload(decryptedPayload, report);

    return locationReport;
  }

  /// Decodes the unencrypted timestamp and confidence
  static void _decodeTimeAndConfidence(
      Uint8List payloadData, FindMyReport report) {
    final seenTimeStamp =
        payloadData.sublist(0, 4).buffer.asByteData().getInt32(0, Endian.big);
    final timestamp =
        DateTime.utc(2001).add(Duration(seconds: seenTimeStamp)).toLocal();
    final confidence = payloadData.elementAt(4);
    report.timestamp = timestamp;
    report.confidence = confidence;
  }

  /// Performs an Elliptic Curve Diffie-Hellman with the given keys.
  /// Returns the derived raw key data.
  static Uint8List _ecdh(
      ECPublicKey ephemeralPublicKey, ECPrivateKey privateKey) {
    final sharedKey = ephemeralPublicKey.Q! * privateKey.d;

    final bytes = sharedKey!.x!
        .toBigInteger()!
        .toUnsigned(28 * 8)
        .toRadixString(16)
        .padLeft(28 * 2, '0');
    return Uint8List.fromList(List.generate(
        28, (i) => int.parse(bytes.substring(i * 2, i * 2 + 2), radix: 16)));
  }

  /// Decodes the raw decrypted payload and constructs and returns
  /// the resulting [FindMyLocationReport].
  static FindMyLocationReport _decodePayload(
      Uint8List payload, FindMyReport report) {
    final latitude = payload.buffer.asByteData(0, 4).getUint32(0, Endian.big);
    final longitude = payload.buffer.asByteData(4, 4).getUint32(0, Endian.big);
    final accuracy = payload.buffer.asByteData(8, 1).getUint8(0);
    final status = payload.buffer.asByteData(9, 1).getUint8(0);

    AccessoryBatteryStatus? batteryStatus;
    // BATT_ENABLE UPDATE: previously this was gated behind a
    // "does the flag bit say battery reporting is supported, or is
    // the byte nonzero" check — meant to avoid confusing "full battery
    // (0x00)" with "this tag doesn't report battery at all (also
    // 0x00 by default)". Confirmed via a real Wireshark capture (see
    // project notes) that this specific firmware always sends 0x00
    // for a full battery, with no distinguishing flag bit — so the
    // old gate made a full battery indistinguishable from "no data"
    // and the green "full" icon could never appear in practice.
    //
    // Per explicit decision: regardless of whether HAS_BATTERY /
    // Batt_en was enabled when this firmware was built, always decode
    // the status byte's top two bits and show green for the resulting
    // "full battery" case. This trades away the ability to tell "genuinely
    // no battery data" apart from "full battery" — but since this project's
    // firmware never sends anything BUT one of these four values in this
    // byte, that distinction wasn't actually possible to make reliably
    // anyway, and showing a full-battery icon is preferable to showing
    // no icon at all for the common case.
    switch (status >> 6) {
      // get highest 2 bits
      case 0:
        batteryStatus = AccessoryBatteryStatus.ok;
        break;
      case 1:
        batteryStatus = AccessoryBatteryStatus.medium;
        break;
      case 2:
        batteryStatus = AccessoryBatteryStatus.low;
        break;
      case 3:
        batteryStatus = AccessoryBatteryStatus.criticalLow;
        break;
      default:
          batteryStatus = null;
      }
    final latitudeDec = latitude / 10000000.0;
    final longitudeDec = longitude / 10000000.0;

    return FindMyLocationReport(
        latitudeDec,
        longitudeDec,
        accuracy,
        report.timestamp,
        report.confidence,
        batteryStatus);
  }

  /// Decrypts the given cipher text with the key data using an AES-GCM block cipher.
  /// Returns the decrypted raw data.
  static Uint8List _decryptPayload(
      Uint8List cipherText, Uint8List symmetricKey, Uint8List tag) {
    final decryptionKey = symmetricKey.sublist(0, 16);
    final iv = symmetricKey.sublist(16, symmetricKey.length);

    final aesGcm = GCMBlockCipher(AESEngine())
      ..init(
          false,
          AEADParameters(
              KeyParameter(decryptionKey), tag.lengthInBytes * 8, iv, tag));

    final plainText = Uint8List(cipherText.length);
    var offset = 0;
    while (offset < cipherText.length) {
      offset += aesGcm.processBlock(cipherText, offset, plainText, offset);
    }

    assert(offset == cipherText.length);
    return plainText;
  }

  /// ANSI X.963 key derivation to calculate the actual (symmetric) advertisement
  /// key and returns the raw key data.
  static Uint8List _kdf(Uint8List secret, Uint8List ephemeralKey) {
    var shaDigest = SHA256Digest();
    shaDigest.update(secret, 0, secret.length);

    var counter = 1;
    var counterData = ByteData(4)..setUint32(0, counter);
    var counterDataBytes = counterData.buffer.asUint8List();
    shaDigest.update(counterDataBytes, 0, counterDataBytes.lengthInBytes);

    shaDigest.update(ephemeralKey, 0, ephemeralKey.lengthInBytes);

    Uint8List out = Uint8List(shaDigest.digestSize);
    shaDigest.doFinal(out, 0);

    return out;
  }
}
