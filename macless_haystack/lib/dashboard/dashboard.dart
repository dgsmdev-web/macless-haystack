
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:logger/logger.dart';
import 'package:macless_haystack/item_management/refresh_action.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/dashboard/accessory_map_list_vert.dart';
import 'package:macless_haystack/item_management/item_management.dart';
import 'package:macless_haystack/item_management/new_item_action.dart';
import 'package:macless_haystack/location/location_model.dart';
import 'package:macless_haystack/preferences/preferences_page.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';

import '../accessory/accessory_model.dart';

class Dashboard extends StatefulWidget {
  /// Displays the layout for the mobile view of the app.
  ///
  /// The layout is optimized for a vertically aligned small screens.
  /// The functionality is structured in a bottom tab bar for easy access
  /// on mobile devices.
  const Dashboard({super.key});

  @override
  State<StatefulWidget> createState() {
    return _DashboardState();
  }
}

class _DashboardState extends State<Dashboard> with WidgetsBindingObserver {
  /// Interval for automatic background refresh of location reports.
  static const Duration _autoRefreshInterval = Duration(minutes: 10);

  Timer? _autoRefreshTimer;

  /// A list of the tabs displayed in the bottom tab bar.
  late final List<Map<String, dynamic>> _tabs = [
    {
      'title': 'My Accessories',
      'body': (ctx) => AccessoryMapListVertical(
            loadLocationUpdates: loadLocationUpdates,
            saveOrderUpdatesCallback: saveAccessories,
          ),
      'icon': Icons.place,
      'label': 'Map',
      'actionButton': (ctx) => RefreshAction(
            callback: () async {
              await loadLocationUpdates(null);
            },
          ),
    },
    {
      'title': 'My Accessories',
      'body': (ctx) => const KeyManagement(),
      'icon': Icons.style,
      'label': 'Accessories',
      'actionButton': (ctx) => const NewKeyAction(),
    },
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Initialize models and preferences
    var userPreferences = Provider.of<UserPreferences>(context, listen: false);
    var locationModel = Provider.of<LocationModel>(context, listen: false);
    var locationPreferenceKnown =
        userPreferences.locationPreferenceKnown ?? false;
    var locationAccessWanted = userPreferences.locationAccessWanted ?? false;
    if (!locationPreferenceKnown || locationAccessWanted) {
      locationModel.requestLocationUpdates();
    }
    // Load new location reports on app start
    if (Settings.getValue<bool>(fetchLocationOnStartupKey,
        defaultValue: true)!) {
      loadLocationUpdates(null);
    }

    _startAutoRefresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAutoRefresh();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Timer.periodic keeps firing while the Dart isolate is alive, but there
    // is no point in hitting the network while the app is not visible.
    // Pause while backgrounded, resume (and refresh once immediately) when
    // the app comes back to the foreground.
    if (state == AppLifecycleState.resumed) {
      _startAutoRefresh();
      loadLocationUpdates(null, silent: true);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _stopAutoRefresh();
    }
  }

  void _startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(_autoRefreshInterval, (timer) {
      loadLocationUpdates(null, silent: true);
    });
  }

  void _stopAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
  }

  var logger = Logger(
    printer: PrettyPrinter(),
  );

  /// Fetch location updates for all accessories.
  ///
  /// If [silent] is true (used by the automatic background refresh), no
  /// snackbar is shown on success so the user isn't interrupted every
  /// 10 minutes. Errors are still logged either way.
  Future<void> loadLocationUpdates(Accessory? accessory,
      {bool silent = false}) async {
    var accessoryRegistry =
        Provider.of<AccessoryRegistry>(context, listen: false);
    var inactive = 0;
    Iterable<Accessory> accessories;
    if (accessory == null) {
      accessories = accessoryRegistry.accessories;
      inactive = accessories.where((a) => !a.isActive).length;
    } else {
      accessories = [accessory];
    }
    try {
      var count = await accessoryRegistry
          .loadLocationReports(accessories.where((a) => a.isActive));
      if (!silent && mounted && accessories.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Theme.of(context).colorScheme.primary,
            content: Text(
              'Fetched $count location(s).${inactive > 0 ? '$inactive inactive accessories skipped' : ''}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
          ),
        );
      }
    } catch (e, stacktrace) {
      logger.e('Error on fetching', error: e, stackTrace: stacktrace);
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Theme.of(context).colorScheme.error,
            content: Text(
              'Could not find location reports. Try again later. Error: ${e.toString()}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onError,
              ),
            ),
          ),
        );
      }
    }
  }

  /// The selected tab index.
  int _selectedIndex = 0;

  /// Updates the currently displayed tab to [index].
  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: const Text('My Accessories'),
          actions: <Widget>[
            IconButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => const PreferencesPage()),
                );
              },
              icon: const Icon(Icons.settings),
            ),
          ],
        ),
        body: _tabs[_selectedIndex]['body'](context),
        bottomNavigationBar: BottomNavigationBar(
          items: _tabs
              .map((tab) => BottomNavigationBarItem(
                    icon: Icon(tab['icon']),
                    label: tab['label'],
                  ))
              .toList(),
          currentIndex: _selectedIndex,
          unselectedItemColor: Theme.of(context).secondaryHeaderColor,
          onTap: _onItemTapped,
        ),
        floatingActionButton:
            _tabs[_selectedIndex]['actionButton']?.call(context),
        floatingActionButtonLocation: FloatingActionButtonLocation.endDocked);
  }

  Future<void> saveAccessories(List<Accessory> accessories) async {
    var accessoryRegistry =
        Provider.of<AccessoryRegistry>(context, listen: false);
    accessoryRegistry.saveOrderUpdates(accessories);
  }
}
