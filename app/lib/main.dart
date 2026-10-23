import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'theme.dart';
import 'l10n/app_language.dart';
import 'screens/connect_screen.dart';
import 'screens/keys_screen.dart';
import 'screens/balance_screen.dart';
import 'screens/servers_screen.dart';
import 'screens/menu_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/auth_screen.dart';
import 'services/api_client.dart';
import 'services/app_log_service.dart';
import 'services/tunnel_service.dart';
import 'services/locale_service.dart';
import 'services/startup_guard.dart';
import 'services/tray_service.dart';
import 'services/update_service.dart';
import 'services/vpn_notification_service.dart';
import 'widgets/neon.dart';

Future<void> main() async {
  // main() асинхронный: LocaleService.ensureLoaded() ниже ждётся до
  // runApp(), а без явного WidgetsFlutterBinding платформенный канал
  // SharedPreferences падает с "Binding has not yet been initialized".
  WidgetsFlutterBinding.ensureInitialized();
  // defaultValue пуст: ключ обязан приходить через
  // --dart-define=SHOPBOT_API_KEY=... при сборке (секрет уже заведён в
  // .github/workflows/build-android.yml). Без него apiKey будет пустым и
  // запросы сразу упадут с явной ошибкой авторизации, а не заработают тихо
  // с ключом, зашитым в код.
  ApiClient.init(
    apiKey: const String.fromEnvironment('SHOPBOT_API_KEY'),
    baseUrl: const String.fromEnvironment(
      'API_BASE_URL',
      // Запасное значение на случай сборки без --dart-define=API_BASE_URL=...;
      // сборка через GitHub Actions берёт адрес из секрета API_BASE_URL.
      defaultValue: 'https://api.vpnonline.su/api/v1',
    ),
  );
  // Закрепляем тёмный статус-бар и навигационную панель в цвет приложения.
  // Без этого на части прошивок системные области берут свои значения по
  // умолчанию и на тёмной теме выглядят светлой полосой поверх контента.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: AppColors.bg,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  // До первого чтения настроек: на Windows их файл мог остаться обрезанным
  // после закрытия посреди записи, и тогда приложение не доходило до первого
  // кадра — чёрное окно (см. repairCorruptWindowsPrefs).
  await repairCorruptWindowsPrefs();
  // Пишет события туннеля (подключение, отключение, ошибки) в локальный
  // журнал, слушая публичные ValueNotifier'ы TunnelService снаружи. main()
  // вызывается один раз за жизнь процесса, поэтому отписка здесь не нужна.
  _wireAppLogging();
  // Всё до runApp() — под защитой: упавший или зависший шаг не должен
  // оставить окно пустым. Интерфейс запускается в любом случае.
  final startupProblems = <String>[];
  // Читаем сохранённый язык до первого runApp(), чтобы приложение сразу
  // открылось на нужном, а не мигнуло русским на первом кадре. Дальше
  // VpnOnlineApp слушает LocaleService.instance сам.
  await guardedStartupStep('язык', LocaleService.instance.ensureLoaded,
      onProblem: startupProblems.add);
  // На Android/iOS/web сервис выключает сам себя, так что вызывать
  // безусловно безопасно.
  await guardedStartupStep('значок в трее', TrayService.instance.init,
      onProblem: startupProblems.add);
  // Содержимое уведомления VPN в шторке Android (сервер, пинг, ключ).
  VpnNotificationService.instance.start();
  runApp(const VpnOnlineApp());
  // Журнал сам хранится в настройках — пишем в него уже после запуска
  // интерфейса.
  final backup = repairedPrefsBackupPath;
  if (backup != null) {
    AppLogService.instance.log(
        'Файл настроек был повреждён (приложение закрыли во время записи) — '
        'начал с чистых настроек, повреждённая копия: $backup',
        level: AppLogLevel.warning);
  }
  for (final problem in startupProblems) {
    AppLogService.instance.log(problem, level: AppLogLevel.warning);
  }
}

void _wireAppLogging() {
  String? lastLoggedStateLabel;
  TunnelService.instance.status.addListener(() {
    final state = TunnelService.instance.status.value?.state;
    if (state == null) return;
    final label = switch (state) {
      TunnelConnState.connected => 'Туннель подключён',
      TunnelConnState.disconnected => 'Туннель отключён',
      TunnelConnState.connecting => 'Подключение к туннелю…',
      TunnelConnState.disconnecting => 'Отключение туннеля…',
    };
    if (label == lastLoggedStateLabel) return;
    lastLoggedStateLabel = label;
    AppLogService.instance.log(label);
  });
  TunnelService.instance.lastError.addListener(() {
    final error = TunnelService.instance.lastError.value;
    if (error == null || error.isEmpty) return;
    AppLogService.instance.log('Ошибка: $error', level: AppLogLevel.error);
  });
  if (!kIsWeb && Platform.isAndroid) unawaited(_logDevice());
}

/// Телефон и сборка — строкой журнала при запуске: по присланному журналу
/// сразу видно, на какой прошивке что случилось (как она рисует
/// уведомления, как обращается с VPN в фоне).
Future<void> _logDevice() async {
  try {
    final info = await const MethodChannel('vpnonline/native_stats')
        .invokeMapMethod<String, Object?>('getDeviceInfo');
    if (info == null) return;
    final brand = '${info['brand'] ?? ''}';
    final maker = '${info['manufacturer'] ?? ''}';
    final name = brand.isEmpty || brand.toLowerCase() == maker.toLowerCase()
        ? maker
        : '$maker ($brand)';
    await AppLogService.instance.log(
        'Устройство: $name ${info['model'] ?? ''}, Android ${info['android'] ?? '?'}'
        ' · сборка приложения $kAppBuild');
  } catch (_) {
    // Старая нативная часть без метода — без этой строки журнал обойдётся.
  }
}

class VpnOnlineApp extends StatelessWidget {
  const VpnOnlineApp({super.key});

  @override
  Widget build(BuildContext context) {
    // AnimatedBuilder слушает LocaleService.instance и перестраивает
    // MaterialApp при смене языка; `locale:` ниже переключает системную локаль
    // Flutter (даты, кнопки "ОК"/"Отмена" в системных диалогах).
    //
    // Текст самих экранов идёт через `tr('...')`. `home:` при смене языка
    // намеренно не пересоздаётся с новым key: это откатило бы пользователя на
    // первую вкладку и потеряло стек навигации — в том числе экран
    // "Настройки", откуда язык обычно и меняют. Вместо этого каждый экран с
    // переведённым текстом сам слушает LocaleService в своём build() и
    // перерисовывает себя на месте.
    return AnimatedBuilder(
      animation: LocaleService.instance,
      builder: (context, _) {
        return MaterialApp(
          title: 'VPNonLine',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          locale: LocaleService.instance.language.locale,
          supportedLocales: AppLanguage.values.map((l) => l.locale),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const AppEntryPoint(),
          // Интерфейс рассчитан на телефонный экран. На Windows окно стартует
          // компактным (windows/runner/main.cpp), но его можно растянуть на весь
          // монитор — ограничиваем контент телефонной шириной и центрируем.
          builder: (context, child) {
            if (kIsWeb || !Platform.isWindows) return child ?? const SizedBox.shrink();
            return ColoredBox(
              color: AppColors.bg,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: child,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Порядок запуска: онбординг (один раз) -> восстановление сессии из
/// защищённого хранилища -> AuthScreen, если сессии нет -> RootShell.
class AppEntryPoint extends StatefulWidget {
  const AppEntryPoint({super.key});
  @override
  State<AppEntryPoint> createState() => _AppEntryPointState();
}

enum _Stage { loading, onboarding, auth, app }

class _AppEntryPointState extends State<AppEntryPoint> {
  _Stage _stage = _Stage.loading;

  // Показывается на экране входа только когда сессию сбросил
  // sessionExpired-сигнал, а не при обычном выходе из "Меню".
  String? _authInfo;

  @override
  void initState() {
    super.initState();
    // Сигнал "сессия недействительна" слушаем на верхнем уровне дерева, а не
    // в отдельных экранах: прийти он может с любой из пяти вкладок RootShell
    // (все смонтированы одновременно), а результат должен быть один — выйти
    // из мёртвой сессии и показать экран входа, а не оставлять пользователя
    // с ошибкой 401 на той вкладке, где она всплыла первой.
    ApiClient.sessionExpired.addListener(_onSessionExpired);
    _bootstrap();
  }

  @override
  void dispose() {
    ApiClient.sessionExpired.removeListener(_onSessionExpired);
    super.dispose();
  }

  void _onSessionExpired() {
    if (!mounted || _stage != _Stage.app) return;
    setState(() {
      _authInfo = tr('Сессия устарела — войдите заново');
      _stage = _Stage.auth;
    });
  }

  Future<void> _bootstrap() async {
    // SharedPreferences.getInstance() и чтение токена из защищённого
    // хранилища могут бросить исключение — например, при недоступном Keystore
    // после смены блокировки экрана или восстановления из бэкапа. Без
    // try/catch Future цепочки падает необработанным, setState() ниже не
    // вызывается, `_stage` навсегда остаётся `_Stage.loading`, а он рисует
    // пустой Scaffold на почти чёрном фоне — приложение висит на чёрном
    // экране. Здесь такая ошибка откатывает на экран входа и попадает в
    // локальный журнал.
    try {
      final showOnboarding = await OnboardingScreen.shouldShow();
      if (showOnboarding) {
        if (mounted) setState(() => _stage = _Stage.onboarding);
        return;
      }
      await _checkSession();
    } catch (e) {
      AppLogService.instance.log(
        'Ошибка запуска приложения: $e',
        level: AppLogLevel.error,
      );
      if (mounted) setState(() => _stage = _Stage.auth);
    }
  }

  Future<void> _checkSession() async {
    try {
      // Хранилище входа (Keystore, диспетчер учётных данных Windows) изредка
      // не отвечает вовсе — без предела экран так и оставался бы пустым.
      final restored = await ApiClient.instance
          .restoreSession()
          .timeout(const Duration(seconds: 8));
      if (mounted) setState(() => _stage = restored ? _Stage.app : _Stage.auth);
    } catch (e) {
      AppLogService.instance.log(
        'Ошибка восстановления сессии: $e',
        level: AppLogLevel.error,
      );
      if (mounted) setState(() => _stage = _Stage.auth);
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _Stage.loading:
        // Логотип и индикатор, а не пустой тёмный экран: если загрузка
        // задержится, видно, что приложение живо.
        return const Scaffold(
          backgroundColor: AppColors.bg,
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppLogo(size: 88, glow: 18),
                SizedBox(height: 24),
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.violet2),
                ),
              ],
            ),
          ),
        );
      case _Stage.onboarding:
        return OnboardingScreen(onDone: () => _checkSession());
      case _Stage.auth:
        return AuthScreen(
          initialInfo: _authInfo,
          onAuthenticated: () => setState(() {
            _authInfo = null;
            _stage = _Stage.app;
          }),
        );
      case _Stage.app:
        return RootShell(onLoggedOut: () => setState(() => _stage = _Stage.auth));
    }
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key, required this.onLoggedOut});
  final VoidCallback onLoggedOut;

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;
  // IndexedStack ниже держит все 5 вкладок смонтированными одновременно —
  // это нужно, чтобы не терять State при переключении. Но каждая вкладка в
  // initState() сама идёт в сеть (getKeys(), getHosts(), getProfile(), а
  // ServersScreen ещё и открывает сокеты для замера пинга), и без `_visited`
  // весь этот залп уходил бы при холодном старте разом. Экран строится и
  // стартует свою загрузку при первом переходе на вкладку; уже посещённые
  // остаются в дереве и не пересоздаются.
  final Set<int> _visited = {0};

  @override
  void initState() {
    super.initState();
    // Достраиваем остальные вкладки сразу следом за "Главной", чтобы данные
    // были готовы к первому переключению, но не в этом же кадре:
    // addPostFrameCallback откладывает это на кадр после того, как "Главная"
    // отрисовалась и начала свою загрузку. У каждого запроса есть собственный
    // таймаут (api_client.dart::_requestTimeout), так что в худшем случае
    // вкладка покажет ошибку с кнопкой "Повторить", а не вечный спиннер.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _visited.addAll({1, 2, 3, 4}));
    });
  }

  void _onDestinationSelected(int i) {
    setState(() {
      _index = i;
      _visited.add(i);
    });
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      const ConnectScreen(),
      const KeysScreen(),
      const BalanceScreen(),
      const ServersScreen(),
      MenuScreen(onLoggedOut: widget.onLoggedOut),
    ];
    // Оборачиваем здесь, а не весь MaterialApp (см. VpnOnlineApp.build):
    // тогда смена языка на "Настройках" перерисовывает подписи нижней
    // навигации на месте, не сбрасывая выбранную вкладку и состояние экранов
    // в IndexedStack.
    return AnimatedBuilder(
      animation: LocaleService.instance,
      builder: (context, _) => Scaffold(
      // IndexedStack держит все экраны смонтированными и показывает нужный по
      // индексу. Иначе при переключении вкладки старый экран удалялся бы из
      // дерева вместе со State, а при возврате создавался заново — со всеми
      // сетевыми запросами в initState(); на слабой сети каждое
      // "Главная -> Ключи -> Главная" означало полный повторный спиннер.
      // Непосещённые вкладки подменяются дешёвым пустым виджетом — см. `_visited`.
      body: SafeArea(
        child: IndexedStack(
          index: _index,
          children: [
            // TickerMode выключает анимации и сообщает экрану, что его
            // вкладка скрыта: скрытые вкладки не крутят анимации и не гоняют
            // свои периодические замеры (см. ServersScreen._onScreen).
            for (var i = 0; i < screens.length; i++)
              TickerMode(
                enabled: i == _index,
                child: _visited.contains(i)
                    ? screens[i]
                    : const SizedBox.shrink(),
              ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _onDestinationSelected,
        destinations: [
          NavigationDestination(icon: const Icon(Icons.home_rounded), label: tr('Главная')),
          NavigationDestination(icon: const Icon(Icons.vpn_key_rounded), label: tr('Ключи')),
          NavigationDestination(icon: const Icon(Icons.payments_rounded), label: tr('Баланс')),
          NavigationDestination(icon: const Icon(Icons.public_rounded), label: tr('Серверы')),
          NavigationDestination(icon: const Icon(Icons.menu_rounded), label: tr('Меню')),
        ],
      ),
      ),
    );
  }
}