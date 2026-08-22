import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme.dart';
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

void main() {
  // [ИСПРАВЛЕНО — критично перед публикацией репозитория] Раньше здесь
  // стоял РЕАЛЬНЫЙ боевой SHOPBOT_API_KEY как defaultValue прямо в
  // исходном коде — при открытии репозитория (что и планируется для
  // соответствия GPL-3.0 у flutter_singbox_client) ключ был бы виден
  // любому, кто просто откроет main.dart на GitHub, независимо от того,
  // что тот же ключ аккуратно лежит в Secrets. Теперь defaultValue пуст —
  // ключ ОБЯЗАН передаваться через --dart-define=SHOPBOT_API_KEY=... при
  // сборке (см. .github/workflows/build-android.yml, секрет уже там).
  // Если ключ не передан — приложение получит apiKey: '', и запросы к API
  // будут падать с явной ошибкой авторизации сразу, а не тихо "работать"
  // с ключом, зашитым в код.
  ApiClient.init(
    apiKey: const String.fromEnvironment('SHOPBOT_API_KEY'),
    baseUrl: const String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'https://api.vpnonline.shop/api/v1',
    ),
  );
  // [ИСПРАВЛЕНО] Раньше цвет статус-бара/шторки нигде не задавался —
  // приложение использовало системные значения по умолчанию, а на тёмной
  // теме (фон #050308) это на части устройств/прошивок Android выглядит
  // как светлая или прозрачная полоса поверх контента — визуально похоже
  // на то, что "дизайн вылезает в шторку". Явно закрепляем тёмный статус-
  // бар в цвет приложения со светлыми иконками, и такую же навигационную
  // панель снизу, чтобы обе системные области были предсказуемо тёмными
  // на любом устройстве, а не зависели от темы прошивки.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: AppColors.bg,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  // [НОВОЕ] Наполняет локальный журнал (см. services/app_log_service.dart и
  // экран "Безопасность" -> "Хранение логов") реальными событиями туннеля —
  // подключение/отключение и ошибки. Слушает уже существующие публичные
  // ValueNotifier'ы TunnelService снаружи, ничего не меняя в самом
  // tunnel_service.dart. main() вызывается ровно один раз за время жизни
  // процесса, поэтому здесь не нужен dispose()/отписка — в отличие от
  // подписки внутри State какого-либо экрана, повторной регистрации при
  // навигации по приложению тут не будет.
  _wireAppLogging();
  runApp(const VpnOnlineApp());
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
}

class VpnOnlineApp extends StatelessWidget {
  const VpnOnlineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VPNonLine',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const AppEntryPoint(),
    );
  }
}

/// [ИСПРАВЛЕНО v4] Раньше после онбординга приложение сразу показывало
/// RootShell без единой проверки токена — экрана входа не существовало,
/// и ApiClient() в каждом экране создавался заново без токена (см. разбор
/// в services/api_client.dart). Теперь порядок такой:
/// онбординг (1 раз) -> восстановление сессии из защищённого хранилища ->
/// если сессии нет, AuthScreen -> после входа RootShell.
class AppEntryPoint extends StatefulWidget {
  const AppEntryPoint({super.key});
  @override
  State<AppEntryPoint> createState() => _AppEntryPointState();
}

enum _Stage { loading, onboarding, auth, app }

class _AppEntryPointState extends State<AppEntryPoint> {
  _Stage _stage = _Stage.loading;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final showOnboarding = await OnboardingScreen.shouldShow();
    if (showOnboarding) {
      if (mounted) setState(() => _stage = _Stage.onboarding);
      return;
    }
    await _checkSession();
  }

  Future<void> _checkSession() async {
    final restored = await ApiClient.instance.restoreSession();
    if (mounted) setState(() => _stage = restored ? _Stage.app : _Stage.auth);
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _Stage.loading:
        return const Scaffold(backgroundColor: AppColors.bg, body: SizedBox.shrink());
      case _Stage.onboarding:
        return OnboardingScreen(onDone: () => _checkSession());
      case _Stage.auth:
        return AuthScreen(onAuthenticated: () => setState(() => _stage = _Stage.app));
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

  @override
  Widget build(BuildContext context) {
    final screens = [
      const ConnectScreen(),
      const KeysScreen(),
      // [ИСПРАВЛЕНО] Раньше здесь стоял PlansScreen (покупка ключа) —
      // пункт нижнего меню назывался "Баланс", но фактически открывал
      // экран покупки, а не сам баланс, и мгновенно дёргал /plans при
      // каждом заходе на вкладку (сетевая ошибка на скриншоте — оттуда).
      // Теперь здесь BalanceScreen: сумма на счету + число ключей + явная
      // кнопка "Пополнить баланс". Покупка ключа никуда не делась — она
      // доступна с этого же экрана кнопкой и из общего меню.
      const BalanceScreen(),
      const ServersScreen(),
      MenuScreen(onLoggedOut: widget.onLoggedOut),
    ];
    return Scaffold(
      // [ИСПРАВЛЕНО — вторая по значимости причина "приложение очень долго
      // грузится" на мобильном интернете] Раньше в дерево виджетов
      // вставлялся только `screens[_index]` — один-единственный экран из
      // списка. При переключении вкладки старый экран (например,
      // ConnectScreen) полностью УДАЛЯЛСЯ из дерева вместе со своим
      // State, а при возврате на неё создавался заново — с нуля вызывался
      // initState() и, соответственно, все сетевые запросы (getKeys(),
      // getHosts(), getProfile()...) на этой вкладке. На хорошем Wi-Fi
      // это почти незаметно, а на плохом мобильном интернете каждое
      // переключение "Главная -> Ключи -> Главная" означало полный
      // повторный спиннер загрузки и заново уходящие в сеть запросы —
      // именно это и выглядит как "приложение долго грузится", хотя на
      // деле оно перезагружает уже один раз загруженные данные. IndexedStack
      // держит ВСЕ экраны смонтированными одновременно и просто показывает
      // нужный по индексу — State (и уже загруженные данные) сохраняется
      // между переключениями вкладок, повторной загрузки при возврате на
      // вкладку больше нет.
      body: SafeArea(
        child: IndexedStack(index: _index, children: screens),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_rounded), label: 'Главная'),
          NavigationDestination(icon: Icon(Icons.vpn_key_rounded), label: 'Ключи'),
          NavigationDestination(icon: Icon(Icons.payments_rounded), label: 'Баланс'),
          NavigationDestination(icon: Icon(Icons.public_rounded), label: 'Серверы'),
          NavigationDestination(icon: Icon(Icons.menu_rounded), label: 'Меню'),
        ],
      ),
    );
  }
}