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
import 'services/tray_service.dart';

Future<void> main() async {
  // [НОВОЕ] main() теперь асинхронный (ждёт LocaleService.ensureLoaded()
  // ниже перед runApp) — обязательный явный WidgetsFlutterBinding нужен
  // именно из-за этого await ДО runApp(): без него платформенный канал
  // SharedPreferences, к которому обращается LocaleService, может упасть с
  // "Binding has not yet been initialized".
  WidgetsFlutterBinding.ensureInitialized();
  // [ИСПРАВЛЕНО — критично перед публикацией репозитория] Теперь
  // defaultValue пуст — ключ ОБЯЗАН передаваться через
  // --dart-define=SHOPBOT_API_KEY=... при
  // сборке (см. .github/workflows/build-android.yml, секрет уже там).
  // Если ключ не передан — приложение получит apiKey: '', и запросы к API
  // будут падать с явной ошибкой авторизации сразу, а не тихо "работать"
  // с ключом, зашитым в код.
  ApiClient.init(
    apiKey: const String.fromEnvironment('SHOPBOT_API_KEY'),
    baseUrl: const String.fromEnvironment(
      'API_BASE_URL',
      // [ИЗМЕНЕНО] домен API сменился с api.vpnonline.shop на
      // api.vpnonline.su — это только запасное значение на случай сборки
      // без --dart-define=API_BASE_URL=...; реальная сборка через
      // GitHub Actions берёт адрес из секрета API_BASE_URL (см. ниже).
      defaultValue: 'https://api.vpnonline.su/api/v1',
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
  // [НОВОЕ] Модуль переводчика — читает сохранённый язык из LocalPrefs ДО
  // первого runApp(), чтобы приложение сразу открылось на нужном языке, а
  // не мигнуло русским на первом кадре. Сам виджет ниже (VpnOnlineApp)
  // слушает LocaleService.instance и перестраивается при смене языка из
  // кнопки "Язык" на экране "Настройки" — грузить язык заново не нужно.
  await LocaleService.instance.ensureLoaded();
  // [НОВОЕ] Значок в системном трее Windows — см. services/tray_service.dart
  // за подробным разбором, почему его раньше не было (не баг — просто не
  // существовало кода). Внутри сам себя выключает на Android/iOS/web, так
  // что вызывать безусловно здесь безопасно.
  await TrayService.instance.init();
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
    // [НОВОЕ] Модуль переводчика — `AnimatedBuilder` слушает
    // `LocaleService.instance` (обычный `ChangeNotifier`, без сторонних
    // пакетов вроде provider) и перестраивает MaterialApp при каждой смене
    // языка кнопкой "Язык" на экране "Настройки". `locale:` ниже переключает
    // системную локаль Flutter (даты, кнопки "ОК"/"Отмена" в системных
    // диалогах и т.п.).
    //
    // Собственный текст экранов (Text('Настройки') и т.д.) берётся через
    // `tr('...')` — см. lib/services/locale_service.dart и lib/l10n/.
    // НАМЕРЕННО не пересоздаём `home:` целиком с новым `key` при смене
    // языка (как можно было бы сделать проще) — это откатило бы
    // пользователя на первую вкладку и потеряло бы весь стек навигации
    // (например открытый поверх "Меню" экран "Настройки", где как раз и
    // находится кнопка "Язык" — самое частое место, откуда язык меняют).
    // Вместо этого каждый экран, где есть переведённый текст, сам слушает
    // `LocaleService.instance` через `AnimatedBuilder` в своём build() —
    // см. например settings_screen.dart — и перерисовывает СЕБЯ на месте,
    // не теряя ни навигацию, ни состояние остальных экранов.
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
          // [НОВОЕ] Интерфейс спроектирован под телефонный экран. На Windows
          // системное окно теперь стартует компактным (см.
          // windows/runner/main.cpp), но пользователь может вручную растянуть
          // его на весь монитор — без этого builder'а контент растягивался
          // бы на всю ширину и выглядел неестественно. Ограничиваем контент
          // "телефонной" шириной и центрируем его, только на Windows —
          // Android/iOS не затрагиваем.
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

  // [НОВОЕ] Показывается на экране входа только когда сессию сбросил именно
  // sessionExpired-сигнал (см. api_client.dart) — а не при обычном ручном
  // выходе из "Меню", где отдельное объяснение не нужно.
  String? _authInfo;

  @override
  void initState() {
    super.initState();
    // [НОВОЕ — исправляет зависание на "Unauthorized: Invalid token
    // signature" после смены домена api.vpnonline.shop -> api.vpnonline.su]
    // Слушаем глобальный сигнал "сессия недействительна" на самом верхнем
    // уровне дерева виджетов, а не в отдельных экранах (BalanceScreen,
    // KeysScreen и т.д.) — сигнал может прийти с ЛЮБОЙ вкладки RootShell
    // (все 5 держатся смонтированными одновременно, см. IndexedStack ниже),
    // и в любом случае должен привести к одному и тому же результату: выйти
    // из мёртвой сессии и показать экран входа, а не оставлять пользователя
    // разглядывать ошибку 401 на той вкладке, где она случайно всплыла
    // первой.
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
  // [ИСПРАВЛЕНО — главная причина "пункты меню очень долго грузятся или
  // вовсе не грузят" на мобильном интернете] IndexedStack ниже держит ВСЕ
  // 5 вкладок смонтированными одновременно — это специально (см. докстринг
  // про сохранение State при переключении вкладок), но раньше это же
  // означало, что все 5 экранов (Главная/Ключи/Баланс/Серверы/Меню)
  // строились и запускали initState() СРАЗУ при первом же открытии
  // приложения, ещё до того как пользователь нажал хоть одну вкладку кроме
  // "Главная". Каждый из них при этом сам лезет в сеть: ConnectScreen ->
  // getKeys(), KeysScreen -> getKeys(), BalanceScreen -> getProfile()+
  // getKeys(), ServersScreen -> getKeys()+getHosts() (и сразу следом ещё
  // открывает TCP-сокеты для замера пинга к каждому серверу), MenuScreen ->
  // getProfile()+getKeys(). То есть только getKeys() улетал в сеть ПЯТЬ раз
  // одновременно при каждом холодном старте — на хорошем Wi-Fi разница не
  // заметна, а на слабом мобильном интернете эти запросы реально
  // конкурируют за один и тот же канал, и любая вкладка (в том числе
  // "Меню", хотя сама по себе она ничего тяжёлого не делает) может висеть
  // в спиннере просто потому, что её запрос застрял в очереди за
  // остальными четырьмя. `_visited` решает это, не отменяя исходную идею
  // IndexedStack: экран реально строится (и, соответственно, стартует
  // свою сетевую загрузку) только один раз — при первом переходе на
  // вкладку. Уже посещённые вкладки остаются в дереве и не пересоздаются
  // при последующих переключениях — старое поведение "не перезагружать
  // вкладку при возврате на неё" полностью сохранено.
  final Set<int> _visited = {0};

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
    // [НОВОЕ] Модуль переводчика — оборачиваем именно тут, а не весь
    // MaterialApp (см. докстринг в VpnOnlineApp.build), чтобы смена языка
    // на экране "Настройки" (открытом поверх вкладки "Меню") сразу
    // перерисовала подписи нижней навигации "на месте", без сброса
    // текущей выбранной вкладки и без потери состояния уже загруженных
    // экранов в IndexedStack ниже.
    return AnimatedBuilder(
      animation: LocaleService.instance,
      builder: (context, _) => Scaffold(
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
      // [ИСПРАВЛЕНО] Не посещённые вкладки заменяются на дешёвый пустой
      // виджет вместо реального экрана — см. докстринг `_visited` выше:
      // это то, что реально убирает одновременный залп из 5 сетевых
      // запросов при холодном старте.
      body: SafeArea(
        child: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < screens.length; i++)
              _visited.contains(i) ? screens[i] : const SizedBox.shrink(),
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