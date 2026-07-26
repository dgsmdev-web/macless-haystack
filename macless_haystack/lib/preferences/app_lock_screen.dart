import 'package:flutter/material.dart';
import 'package:macless_haystack/preferences/app_lock_model.dart';

/// Full-screen PIN/biometric prompt shown before the dashboard becomes
/// visible, whenever the user has enabled "Password for entering the
/// app" in Settings. Calls [onUnlocked] once the correct PIN was
/// entered or biometric authentication succeeded.
class AppLockScreen extends StatefulWidget {
  final VoidCallback onUnlocked;

  const AppLockScreen({super.key, required this.onUnlocked});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final TextEditingController _pinController = TextEditingController();
  String? _error;
  bool _checkingBiometric = false;

  @override
  void initState() {
    super.initState();
    _tryBiometricIfEnabled();
  }

  Future<void> _tryBiometricIfEnabled() async {
    if (await AppLockModel.isBiometricEnabled() &&
        await AppLockModel.isBiometricAvailable()) {
      setState(() => _checkingBiometric = true);
      var success = await AppLockModel.authenticateWithBiometrics();
      if (!mounted) return;
      setState(() => _checkingBiometric = false);
      if (success) {
        widget.onUnlocked();
      }
    }
  }

  Future<void> _submitPin() async {
    var pin = _pinController.text;
    if (pin.length != 4) {
      setState(() => _error = 'Enter your 4-digit PIN');
      return;
    }
    var correct = await AppLockModel.verifyPin(pin);
    if (correct) {
      widget.onUnlocked();
    } else {
      setState(() {
        _error = 'Incorrect PIN';
        _pinController.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'Password for entering the app',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (_checkingBiometric) const CircularProgressIndicator(),
                if (!_checkingBiometric) ...[
                  SizedBox(
                    width: 160,
                    child: TextField(
                      controller: _pinController,
                      autofocus: true,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 24, letterSpacing: 8),
                      decoration: InputDecoration(
                        counterText: '',
                        errorText: _error,
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _submitPin(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _submitPin,
                    child: const Text('Unlock'),
                  ),
                  FutureBuilder<bool>(
                    future: (() async {
                      var enabled = await AppLockModel.isBiometricEnabled();
                      var available =
                          await AppLockModel.isBiometricAvailable();
                      return enabled && available;
                    })(),
                    builder: (context, snapshot) {
                      if (snapshot.data != true) return const SizedBox();
                      return TextButton.icon(
                        onPressed: _tryBiometricIfEnabled,
                        icon: const Icon(Icons.fingerprint),
                        label: const Text('Use fingerprint instead'),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
