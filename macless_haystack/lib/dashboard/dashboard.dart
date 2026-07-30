
import 'dart:async';
import 'dart:math' show Random;

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
  /// Среднее время между автоматическими обновлениями, в минутах.
  ///
  /// Замерено: Apple хранит 8 отчётов на ключ, что при обычной городской
  /// активности покрывает около часа. Пятнадцать минут дают четырёхкратный
  /// запас — его хватает и когда меток вокруг много и отчёты идут втрое
  /// чаще, то есть буфер живёт всего минут двадцать.
  static const int refreshIntervalMinutes = 15;

  /// Разброс интервала, доля от него. 0.2 означает 15 минут ± 3.
  ///
  /// Разброс здесь не для красоты. Раньше периодического таймера в
  /// приложении не было СОЗНАТЕЛЬНО: все обновления происходили только
  /// потому, что человек что-то сделал — открыл приложение, вернулся в
  /// него, нажал кнопку. Запросы, приходящие ровно каждые 15 минут
  /// круглосуточно, ни на что человеческое не похожи и сами по себе
  /// являются признаком автоматизации. Случайный разброс возвращает
  /// картину к правдоподобной, почти ничего не стоя.
  static const double refreshJitterFraction = 0.2;

  Timer? _refreshTimer;
  final Random _random = Random();
  bool _appInForeground = true;

  /// Планирует следующее обновление со случайным отклонением.
  ///
  /// Одноразовый таймер, перевзводимый после каждого срабатывания, а не
  /// Timer.periodic: только так интервал получается разным каждый раз.
  void _scheduleNextRefresh() {
    _refreshTimer?.cancel();
    final base = refreshIntervalMinutes * 60;
    final spread = (base * refreshJitterFraction).round();
    final seconds = base - spread + _random.nextInt(spread * 2 + 1);
    _refreshTimer = Timer(Duration(seconds: seconds), () {
      // Таймеры Dart не работают, пока приложение свёрнуто, но на всякий
      // случай проверяем: обновление имеет смысл только на переднем плане.
      if (mounted && _appInForeground) {
        loadLocationUpdates(null, silent: true);
      }
      if (mounted) {
        _scheduleNextRefresh();
      }
    });
  }

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
    // Load new location reports on app start. Обновления происходят:
    // при холодном старте (здесь), при возвращении в приложение из
    // фона (см. didChangeAppLifecycleState ниже), по кнопке обновления
    // и — с этой версии — по таймеру с разбросом, пока приложение
    // открыто.
    //
    // Таймер добавлен потому, что Apple вытесняет отчёты примерно через
    // час, и без него история рвётся всякий раз, когда приложение долго
    // не трогали. Интервал НЕ фиксированный: см. refreshJitterFraction
    // выше — прежнее решение отказаться от ровного периода было верным
    // по сути, и разброс его сохраняет.
    //
    // This resume-on-return listener was temporarily removed for a
    // diagnostic test while chasing the map freeze — confirmed via a
    // real ANR trace from the device that the freeze is an
    // engine/rendering-level issue, unrelated to this. Restored.
    if (Settings.getValue<bool>(fetchLocationOnStartupKey,
        defaultValue: true)!) {
      loadLocationUpdates(null);
    }
    _scheduleNextRefresh();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android normally keeps the app process alive in the background
    // when you switch away from it (Home button, another app, locking
    // the screen) — coming back is a "resume", not a fresh process
    // start, so initState() above does NOT run again on its own. This
    // is the only thing that refreshes on a normal "switched back to
    // the app" — deliberately NOT a timer, just a one-off silent fetch
    // exactly when a person actually returns to the app.
    _appInForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      // Вернулись в приложение — обновляем сразу и отсчитываем интервал
      // заново, чтобы два обновления не пришли подряд.
      _scheduleNextRefresh();
      var accessoryRegistry =
          Provider.of<AccessoryRegistry>(context, listen: false);
      if (accessoryRegistry.suppressResumeRefresh) {
        // A Restore Full History is in progress — the file picker
        // itself just triggered this "resume", not the person
        // actually returning to check on things. Skip this one.
        return;
      }
      loadLocationUpdates(null, silent: true);
    }
  }

  var logger = Logger(
    printer: PrettyPrinter(),
  );

  /// Fetch location updates for all accessories.
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
          // secondaryHeaderColor was used here before — it's meant for
          // header backgrounds, not icon tint, and rendered almost
          // invisible in light theme (see reported screenshots). A
          // fixed mid-grey reads clearly in both light and dark theme,
          // while staying visibly less prominent than the selected tab.
          unselectedItemColor: Theme.of(context).brightness == Brightness.light
              ? const Color(0xFF5F6368)
              : const Color(0xFFB0B0B0),
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
