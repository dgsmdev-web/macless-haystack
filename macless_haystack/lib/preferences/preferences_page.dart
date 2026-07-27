import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/location/location_model.dart';
import 'package:macless_haystack/preferences/app_lock_settings_section.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:url_launcher/url_launcher.dart';

class PreferencesPage extends StatefulWidget {
  /// Displays this preferences page with information about the app.
  const PreferencesPage({super.key});

  @override
  State<StatefulWidget> createState() {
    return _PreferencesPageState();
  }
}

class _PreferencesPageState extends State<PreferencesPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: Center(
        child: Column(
          children: <Widget>[
            getLocationTile(),
            getFetchOnStartupTile(),
            getUrlTile(),
            getUserTile(),
            getPassTile(),
            getNumberofDaysTile(),
            const Divider(),
            const AppLockSettingsSection(),
            ListTile(
              title: getAbout(),
            ),
            // Version of the actually installed build (from the app's
            // own manifest/package metadata, not just the source code)
            // — makes it obvious at a glance which build is on the
            // device, instead of guessing from file names or timestamps.
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const SizedBox();
                final info = snapshot.data!;
                return Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 12),
                  child: Text(
                    'AG Find v${info.version}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  getLocationTile() {
    return SwitchSettingsTile(
      settingKey: locationAccessWantedKey,
      title: 'Show this devices location',
      onChange: (showLocation) {
        var locationModel = Provider.of<LocationModel>(context, listen: false);
        if (showLocation) {
          locationModel.requestLocationUpdates();
        } else {
          locationModel.cancelLocationUpdates();
        }
      },
    );
  }

  getNumberofDaysTile() {
    return const DropDownSettingsTile<int>(
      title: 'Number of days to fetch location',
      settingKey: numberOfDaysToFetch,
      values: <int, String>{
        0: "latest location only",
        1: "1",
        2: "2",
        3: "3",
        4: "4",
        5: "5",
        6: "6",
        7: "7",
      },
      selected: 7,
    );
  }

  getUrlTile() {
    return TextInputSettingsTile(
      initialValue: 'http://localhost:6176',
      settingKey: endpointUrl,
      title: 'Url to endpoint',
      validator: (String? url) {
        if (url != null &&
            url.startsWith(RegExp('http[s]?://', caseSensitive: false))) {
          return null;
        }
        return "Invalid Url";
      },
    );
  }

  getUserTile() {
    return const TextInputSettingsTile(
      initialValue: '',
      settingKey: endpointUser,
      title: 'Username for endpoint',
    );
  }

  getPassTile() {
    return const TextInputSettingsTile(
      obscureText: true,
      initialValue: '',
      settingKey: endpointPass,
      title: 'Password for endpoint',
    );
  }

  getAbout() {
    return TextButton(
        style: ButtonStyle(
            padding:
                WidgetStateProperty.all<EdgeInsets>(const EdgeInsets.all(10)),
            foregroundColor: WidgetStateProperty.resolveWith<Color?>(
              (Set<WidgetState> states) {
                return Colors.white;
              },
            ),
            backgroundColor: WidgetStateProperty.resolveWith<Color?>(
              (Set<WidgetState> states) {
                return Colors.indigo;
              },
            )),
        child: const Text('About AG Find'),
        onPressed: () async {
          final uri = Uri.parse('https://www.aggroupbg.com/');
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        });
  }

  getFetchOnStartupTile() {
    return SwitchSettingsTile(
      settingKey: fetchLocationOnStartupKey,
      defaultValue: true,
      title: 'Fetch locations on startup',
    );
  }
}
