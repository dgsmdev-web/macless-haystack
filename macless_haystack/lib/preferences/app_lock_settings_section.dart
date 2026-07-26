import 'package:flutter/material.dart';
import 'package:macless_haystack/preferences/app_lock_model.dart';

/// Settings section for "Password for entering the app" — lives on the
/// same Settings page as the endpoint URL/username/password, but is a
/// clearly separate concept: this PIN (optionally backed by the
/// device's fingerprint) locks the app itself on this device, it has
/// nothing to do with authenticating to your server.
class AppLockSettingsSection extends StatefulWidget {
  const AppLockSettingsSection({super.key});

  @override
  State<AppLockSettingsSection> createState() =>
      _AppLockSettingsSectionState();
}

class _AppLockSettingsSectionState extends State<AppLockSettingsSection> {
  bool _enabled = false;
  bool _biometricEnabled = false;
  bool _biometricAvailable = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var enabled = await AppLockModel.isEnabled();
    var bioEnabled = await AppLockModel.isBiometricEnabled();
    var bioAvailable = await AppLockModel.isBiometricAvailable();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _biometricEnabled = bioEnabled;
      _biometricAvailable = bioAvailable;
      _loaded = true;
    });
  }

  /// Shows a two-step (enter, confirm) 4-digit PIN dialog. Returns the
  /// chosen PIN, or null if the user cancelled / the two entries didn't
  /// match.
  Future<String?> _promptForNewPin() async {
    final firstController = TextEditingController();
    var first = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Set a 4-digit PIN'),
        content: TextField(
          controller: firstController,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 4,
          decoration: const InputDecoration(counterText: ''),
        ),
        actions: [
          TextButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
          TextButton(
            child: const Text('Next'),
            onPressed: () {
              if (firstController.text.length == 4) {
                Navigator.of(dialogContext).pop(firstController.text);
              }
            },
          ),
        ],
      ),
    );
    if (first == null || !mounted) return null;

    final secondController = TextEditingController();
    var second = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm your PIN'),
        content: TextField(
          controller: secondController,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 4,
          decoration: const InputDecoration(counterText: ''),
        ),
        actions: [
          TextButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
          TextButton(
            child: const Text('Confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(secondController.text),
          ),
        ],
      ),
    );
    if (second == null || !mounted) return null;

    if (first != second) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PINs did not match. Try again.')),
        );
      }
      return null;
    }
    return first;
  }

  Future<void> _onToggleEnabled(bool value) async {
    if (value) {
      var pin = await _promptForNewPin();
      if (pin == null) {
        return; // user cancelled or mismatch — leave disabled
      }
      await AppLockModel.setPin(pin);
      await AppLockModel.setEnabled(true);
    } else {
      await AppLockModel.disableAndClear();
    }
    await _load();
  }

  Future<void> _onChangePin() async {
    var pin = await _promptForNewPin();
    if (pin == null) return;
    await AppLockModel.setPin(pin);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PIN updated.')),
      );
    }
  }

  Future<void> _onToggleBiometric(bool value) async {
    await AppLockModel.setBiometricEnabled(value);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const ListTile(
        title: Text('Password for entering the app'),
        trailing: SizedBox(
            width: 20, height: 20, child: CircularProgressIndicator()),
      );
    }

    return Column(
      children: [
        SwitchListTile(
          title: const Text('Password for entering the app'),
          subtitle: const Text('Require a PIN (or fingerprint) to open AG Find'),
          value: _enabled,
          onChanged: _onToggleEnabled,
        ),
        if (_enabled) ...[
          ListTile(
            title: const Text('Change PIN'),
            leading: const Icon(Icons.pin),
            onTap: _onChangePin,
          ),
          if (_biometricAvailable)
            SwitchListTile(
              title: const Text('Use fingerprint instead of PIN'),
              value: _biometricEnabled,
              onChanged: _onToggleBiometric,
            ),
        ],
      ],
    );
  }
}
