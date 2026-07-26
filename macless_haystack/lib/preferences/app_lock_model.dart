import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:pointycastle/export.dart';

const appLockEnabledStorageKey = 'APP_LOCK_ENABLED';
const appLockPinHashStorageKey = 'APP_LOCK_PIN_HASH';
const appLockUseBiometricStorageKey = 'APP_LOCK_USE_BIOMETRIC';

/// Handles the app's own entry-screen lock ("Password for entering the
/// app") — a standalone 4-digit PIN, optionally backed by the device's
/// fingerprint/biometric unlock instead. Kept separate from the
/// endpoint URL/username/password settings (those authenticate to your
/// server; this authenticates a person to this specific device's copy
/// of the app).
class AppLockModel {
  static const _storage = FlutterSecureStorage();
  static final LocalAuthentication _localAuth = LocalAuthentication();

  static Future<bool> isEnabled() async {
    return (await _storage.read(key: appLockEnabledStorageKey)) == 'true';
  }

  static Future<void> setEnabled(bool enabled) async {
    await _storage.write(
        key: appLockEnabledStorageKey, value: enabled.toString());
  }

  static Future<bool> hasPinSet() async {
    return (await _storage.read(key: appLockPinHashStorageKey)) != null;
  }

  static String _hashPin(String pin) {
    var bytes = Uint8List.fromList(utf8.encode(pin));
    var digest = SHA256Digest().process(bytes);
    return base64Encode(digest);
  }

  static Future<void> setPin(String pin) async {
    await _storage.write(
        key: appLockPinHashStorageKey, value: _hashPin(pin));
  }

  static Future<bool> verifyPin(String pin) async {
    var storedHash = await _storage.read(key: appLockPinHashStorageKey);
    if (storedHash == null) return false;
    return storedHash == _hashPin(pin);
  }

  static Future<void> clearPin() async {
    await _storage.delete(key: appLockPinHashStorageKey);
  }

  static Future<bool> isBiometricEnabled() async {
    return (await _storage.read(key: appLockUseBiometricStorageKey)) ==
        'true';
  }

  static Future<void> setBiometricEnabled(bool enabled) async {
    await _storage.write(
        key: appLockUseBiometricStorageKey, value: enabled.toString());
  }

  /// Whether this device actually offers usable biometrics (fingerprint,
  /// face unlock, etc.) right now — checked before offering the toggle.
  static Future<bool> isBiometricAvailable() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isSupported = await _localAuth.isDeviceSupported();
      return canCheck && isSupported;
    } catch (_) {
      return false;
    }
  }

  /// Prompts for biometric authentication (fingerprint/face). Returns
  /// true only on a genuine successful match.
  static Future<bool> authenticateWithBiometrics() async {
    try {
      return await _localAuth.authenticate(
        localizedReason: 'Unlock AG Find',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// Fully disables and clears the app lock (PIN + biometric preference).
  static Future<void> disableAndClear() async {
    await setEnabled(false);
    await clearPin();
    await setBiometricEnabled(false);
  }
}
