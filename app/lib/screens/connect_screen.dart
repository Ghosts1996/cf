import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';
import '../services/local_prefs.dart';
import '../services/tunnel_service.dart';
import '../services/locale_service.dart';
import '../state/selected_server.dart';
import 'plans_screen.dart';
import 'servers_screen.dart';

/// Экран подключения.
///
/// Кнопка "Подключить" поднимает и останавливает VLESS-туннель через
/// [TunnelService]; RX/TX и таймер — живые значения из его статуса.
///
/// Поля ключа берутся ровно те, что отдаёт `GET /user/keys`: `expiry_date`
/// (активность = дата в будущем) и `connection_string`. Полей
/// `active_in_panel`, `subscription_url` и `devices_used` у сервера нет,
/// поэтому показывается только `devices_limit`, без "занято/всего".
///
/// Задержка меряется двумя способами: на поднятом туннеле — через единый
/// замерщик TunnelService (то же число, что в списке серверов), без
/// туннеля — секундомером вокруг обычного `getHosts()`, отдельного /ping на
/// сервере нет. Пока туннель поднят, `_latencyTimer` тихо обновляет цифру
/// раз в 15 секунд.
///
/// Платформенная часть (App Group + Network Extension на iOS/macOS,
/// sing-box.exe на Windows) настраивается вне Dart — см. app/NATIVE_SETUP.md.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});
  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen>
    with WidgetsBindingObserver {
  final _api = ApiClient.instance;
  final _tunnel = TunnelService.instance;
  bool _connecting = false;
  bool _loadingKey = true;
  Map<String, dynamic>? _activeKey;
  String? _keyError;
  int? _latencyMs;
  // Флаг "замер идёт сейчас": пока свежий замер летит по сети, предыдущий
  // результат не должен висеть на экране как актуальный.
  bool _latencyChecking = false;
  // Пока туннель поднят, обновляем задержку раз в 15 секунд.
  Timer? _latencyTimer;
  // key_id ключа, на котором поднят туннель прямо сейчас. С "лучшим ключом
  // на момент загрузки экрана" эти значения расходятся, если срок истёк уже
  // после подключения: при перепроверке важно именно "истёк ли ключ живого
  // туннеля".
  int? _connectedKeyId;
  Timer? _keyWatchTimer;
  // Ключ, вставленный вручную на экране "Мои ключи" (ManualKeyStore). Если
  // задан, используется вместо ключа из личного кабинета — см.
  // _effectiveConnectionString.
  String? _manualKey;
  // "Автоподключение уже пробовали в этой сессии экрана": иначе оно
  // срабатывало бы при каждом обновлении _activeKey, а не один раз.
  bool _autoConnectTried = false;
  // "Умное подключение на публичном Wi-Fi": слушаем смену сети через
  // connectivity_plus и подключаемся при переходе на Wi-Fi (именно переходе,
  // иначе сработает на каждое обновление состояния связи), если тумблер
  // включён, ключ есть и туннель не поднят. Отличить публичный Wi-Fi от
  // домашнего приложение без спецправ не может, поэтому срабатывает на любой.
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool? _wasOnWifi;
  // true только если реальное состояние нативного VPN-сервиса удалось
  // прочитать (TunnelService.syncRuntimeState()). Пока оно неизвестно,
  // автоподключение запускать нельзя: приложение решит, что VPN выключен, и
  // поднимет вторую сессию поверх работающей.
  bool _runtimeStateKnown = false;
  // true, если ключ на экране взят из локального кэша: нужно отличать
  // "ключей нет" от "сервер сейчас недоступен".
  bool _keysFromCache = false;
  // Верхняя граница ожидания ответа нативной стороны при старте экрана.
  // Сам syncRuntimeState() уже ограничивает каждый свой нативный вызов
  // (TunnelService._nativeCallTimeout), но их там несколько подряд, и в
  // худшем случае их сумма — это десятки секунд, всё это время экран
  // показывал бы только спиннер. Таймаут ничего не отменяет: сама
  // syncRuntimeState() продолжает выполняться в фоне и обновит status,
  // когда закончит, — он лишь разблокирует загрузку ключей и интерфейс.
  static const Duration _runtimeSyncTimeout = Duration(seconds: 15);

  @override
  void initState() {
    super.initState();
    _tunnel.status.addListener(_onTunnelStatus);
    _tunnel.latencyByRemark.addListener(_onTunnelLatency);
    SelectedServer.hostName.addListener(_onTunnelStatus);
    SelectedServer.displayName.addListener(_onTunnelStatus);
    _tunnel.connectedServerName.addListener(_onTunnelStatus);
    // Если туннель отвалился сам и идёт попытка восстановления, экран должен
    // это показать, а не остаться в "подключено".
    _tunnel.killSwitchBlocking.addListener(_onTunnelStatus);
    _manualKey = ManualKeyStore.instance.value;
    ManualKeyStore.instance.notifier.addListener(_onManualKeyChanged);
    ManualKeyStore.instance.ensureLoaded();
    // Сначала спрашиваем у нативной стороны реальное состояние VPN.
    //
    // TunnelService.status живёт только в памяти текущего изолята: при
    // холодном старте он null, значит isConnected == false — независимо от
    // того, работает ли foreground VpnService на устройстве (а он работает,
    // закрытие Activity не останавливает VPN, поэтому в шторке остаётся значок).
    // syncRuntimeState() спрашивает состояние у нативной стороны и обновляет
    // status под него.
    //
    // Важно дождаться его до _loadKeyState(), а не параллельно: внутри есть
    // проверка !_tunnel.isConnected перед автоподключением, и с ещё не
    // восстановленным состоянием она подняла бы вторую сессию поверх первой.
    _bootstrapConnectionState();
    // Раз в минуту тихо перепроверяем список ключей: если приложение открыто
    // дольше, чем остаток срока текущего ключа, об истечении иначе никто не
    // узнает. Истёк ключ живого туннеля — переключаемся на следующий по сроку
    // или отключаемся и предлагаем купить.
    _keyWatchTimer = Timer.periodic(const Duration(minutes: 1), (_) => _recheckKeyExpiry());
    // Тикаем чаще, чем проверка ключа, но не каждую секунду — это
    // TCP-connect до реального VLESS-узла.
    _latencyTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_tunnel.isConnected && !_latencyChecking) _measureLatency();
    });
    _connectivitySub =
        Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);
    // Android далеко не всегда убивает процесс при сворачивании: Dart-изолят
    // часто выживает, а Activity пересоздаётся — initState() тогда не
    // выполняется. Если за время в фоне VPN отключили из шторки, экран
    // продолжал бы показывать "ПОДКЛЮЧЕНО" и тикающий счётчик поверх мёртвого
    // туннеля. Подписка на жизненный цикл перечитывает состояние при каждом
    // возврате в приложение.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) return;
    // Пока пользователь сам подключается/отключается, состояние и так
    // меняется под контролем _toggleConnection() — лезть туда с
    // параллельной синхронизацией незачем.
    if (_connecting || _tunnel.isBusy) return;
    unawaited(_resyncOnResume());
  }

  Future<void> _resyncOnResume() async {
    try {
      await _tunnel.syncRuntimeState().timeout(_runtimeSyncTimeout);
    } catch (_) {
      // Нативная сторона не ответила — оставляем то состояние, что есть,
      // и не мешаем пользователю работать с экраном.
    }
    if (!mounted) return;
    setState(() {});
    if (_tunnel.isConnected && !_latencyChecking) _measureLatency();
  }

  /// См. `_wasOnWifi` выше.
  Future<void> _onConnectivityChanged(List<ConnectivityResult> results) async {
    final onWifi = results.contains(ConnectivityResult.wifi);
    final previous = _wasOnWifi;
    _wasOnWifi = onWifi;
    // Первое событие после подписки — это просто "текущее состояние сети",
    // а не смена сети, поэтому его не считаем переходом.
    if (previous == null) return;
    final justJoinedWifi = onWifi && !previous;
    if (!justJoinedWifi) return;
    final smartWifi =
        await LocalPrefs.instance.getBool(PrefKeys.smartWifi, fallback: false);
    if (!smartWifi || !mounted) return;
    // Как и при автоподключении на старте: пока реальное состояние туннеля
    // неизвестно, поднимать соединение вслепую нельзя.
    if (_runtimeStateKnown &&
        (_activeKey != null || _hasManualKey) &&
        !_tunnel.isConnected &&
        !_tunnel.isBusy) {
      unawaited(_toggleConnection());
    }
  }

  /// Сначала узнаём у нативной стороны реальное состояние VPN (именно
  /// дожидаясь, а не параллельно — см. initState()), и только потом грузим
  /// ключи и решаем про автоподключение.
  Future<void> _bootstrapConnectionState() async {
    // Верхняя граница по времени обязательна. Внутри — цепочка вызовов в
    // нативный код; если foreground VpnService после свайпа приложения из
    // списка задач подвис, голый await не завершится, _loadKeyState() ниже не
    // вызовется, `_loadingKey` навсегда останется true и в кольце будет вечно
    // крутиться спиннер. Таймаут саму синхронизацию не отменяет — она обновит
    // status, когда нативная сторона ответит.
    var syncOk = false;
    try {
      syncOk = await _tunnel.syncRuntimeState().timeout(_runtimeSyncTimeout);
    } catch (_) {
      syncOk = false;
    }
    if (!mounted) return;
    setState(() => _runtimeStateKnown = syncOk);
    _loadKeyState();
  }

  @override
  void dispose() {
    _tunnel.status.removeListener(_onTunnelStatus);
    _tunnel.latencyByRemark.removeListener(_onTunnelLatency);
    SelectedServer.hostName.removeListener(_onTunnelStatus);
    SelectedServer.displayName.removeListener(_onTunnelStatus);
    _tunnel.connectedServerName.removeListener(_onTunnelStatus);
    _tunnel.killSwitchBlocking.removeListener(_onTunnelStatus);
    ManualKeyStore.instance.notifier.removeListener(_onManualKeyChanged);
    _keyWatchTimer?.cancel();
    _latencyTimer?.cancel();
    _connectivitySub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onTunnelLatency() {
    if (!mounted || !_tunnel.isConnected) return;
    setState(() {
      _latencyMs = _tunnel.latencyForHostName(_tunnel.connectedServerName.value);
    });
  }

  void _onTunnelStatus() {
    if (mounted) setState(() {});
  }

  /// Реагирует на сохранение и удаление ручного ключа во время работы
  /// приложения, а не только при перезапуске.
  void _onManualKeyChanged() {
    if (!mounted) return;
    setState(() => _manualKey = ManualKeyStore.instance.value);
    if (_tunnel.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Ключ обновлён. Переподключись, чтобы применить его.'))),
      );
    }
  }

  /// Ссылка, которая реально пойдёт в TunnelService.connect(): ручной ключ,
  /// если задан, иначе ключ из личного кабинета. Ручной приоритетнее —
  /// вставив ссылку вручную, пользователь осознанно хочет именно её.
  String? get _effectiveConnectionString {
    if (_manualKey != null && _manualKey!.trim().isNotEmpty) return _manualKey!.trim();
    return _activeKey?['connection_string'] as String?;
  }

  bool get _hasManualKey => _manualKey != null && _manualKey!.trim().isNotEmpty;

  /// Был ли уже хоть один завершённый замер задержки. Отличает "ещё меряем"
  /// от "померили и не достучались" — без этого подпись под кольцом навсегда
  /// застревала бы на "проверка соединения…".
  bool _latencyProbed = false;

  /// До подключения экран показывает имя локации из `/hosts`
  /// ("🇩🇪 Германия — Франкфурт"), а после — `remark` из самой VLESS-ссылки,
  /// куда панель 3x-ui дописывает название сервиса:
  /// "VPNonLine | 🇩🇪 Германия — Франкфурт". Строка на глазах удлинялась, а
  /// код локации в кружке менялся с "D" на "VP". Отрезаем всё до последней
  /// вертикальной черты; если её нет, имя не трогаем.
  String _prettyServerName(String raw) {
    final separator = raw.lastIndexOf('|');
    if (separator < 0) return raw.trim();
    final tail = raw.substring(separator + 1).trim();
    return tail.isEmpty ? raw.trim() : tail;
  }

  /// Код локации для ServerPill — те же первые буквы имени, что и на
  /// ServersScreen (см. `_codeFromName` там), чтобы отображение не
  /// расходилось между экранами.
  String _codeFromName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '??';
    final firstWord = trimmed.split(RegExp(r'\s+')).first;
    // Имена локаций начинаются с эмодзи-флага, а каждая его половина занимает
    // в UTF-16 две кодовые единицы: substring(0, 2) разрезал флаг пополам и
    // выводил одинокий региональный индикатор вместо "DE". Считаем по рунам,
    // а сам флаг показываем целиком — он читается лучше любых двух букв.
    final runes = firstWord.runes.toList();
    if (runes.isEmpty) return '??';
    final code = String.fromCharCodes(runes.take(2));
    return runes.first > 0xFFFF ? code : code.toUpperCase();
  }

  bool _isActive(Map<String, dynamic> key) {
    final expiryStr = key['expiry_date'] as String?;
    final expiry = expiryStr != null ? DateTime.tryParse(expiryStr) : null;
    return expiry != null && expiry.isAfter(DateTime.now());
  }

  /// Срок действия ключа как [DateTime] (null, если поле отсутствует/битое) —
  /// общий парсинг для сортировки и для [_isActive].
  DateTime? _expiryOf(Map<String, dynamic> key) {
    final expiryStr = key['expiry_date'] as String?;
    return expiryStr != null ? DateTime.tryParse(expiryStr) : null;
  }

  /// Сортировка активных ключей по убыванию срока действия. Один и тот же
  /// порядок нужен в трёх местах: свежая загрузка, восстановление из кэша и
  /// фоновая перепроверка.
  void _sortByExpiryDesc(List<Map<String, dynamic>> keys) {
    keys.sort((a, b) {
      final ea = _expiryOf(a);
      final eb = _expiryOf(b);
      if (ea == null && eb == null) return 0;
      if (ea == null) return 1; // ключи без даты — в конец
      if (eb == null) return -1;
      return eb.compareTo(ea); // по убыванию: сначала дальше всех истекающий
    });
  }

  /// Несколько попыток подряд с паузой: на слабом сигнале один легитимный,
  /// просто медленный ответ иногда не укладывается в таймаут запроса
  /// (ApiClient._send), и экран сдавался бы с "Сервер не отвечает", оставаясь
  /// на "НЕТ КЛЮЧА" до перезапуска приложения — pull-to-refresh здесь нет, а
  /// переключение вкладок с IndexedStack экран не пересоздаёт.
  ///
  /// Повторяем только сетевые сбои (`statusCode == 0`): настоящую ошибку
  /// сервера повтор не исправит, только продержит человека перед пустым
  /// экраном лишние секунды. Офлайн-копию ключей при этом ведёт сам
  /// ApiClient — он же дедуплицирует одинаковые `getKeys()`, которые вкладки
  /// отправляют одновременно при холодном старте; экрану остаётся флаг
  /// `ApiClient.instance.keysFromCache`.
  Future<List<dynamic>> _fetchKeysWithRetry() async {
    const maxAttempts = 3;
    for (var attempt = 1;; attempt++) {
      try {
        return await _api.getKeys();
      } on ApiException catch (e) {
        if (e.statusCode != 0 || attempt >= maxAttempts) rethrow;
      } catch (_) {
        if (attempt >= maxAttempts) rethrow;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  Future<void> _loadKeyState() async {
    setState(() => _loadingKey = true);
    try {
      // getKeys() сам отдаст сохранённую копию, если сеть не ответила, поэтому
      // цикл повторов срабатывает, только когда показывать вообще нечего.
      final keys = await _fetchKeysWithRetry();
      if (!mounted) return;
      final active = keys.cast<Map<String, dynamic>>().where(_isActive).toList();
      // Берём ключ с максимальным expiry_date, а не первый активный: бэкенд
      // отдаёт их в порядке покупки, и при нескольких ключах подключение уходило
      // бы на тот, что истекает раньше.
      _sortByExpiryDesc(active);
      setState(() {
        _activeKey = active.isNotEmpty ? active.first : null;
        _keysFromCache = _api.keysFromCache;
        _keyError = null;
        _loadingKey = false;
      });
      // "Автоподключение при запуске": только при первой загрузке экрана, не при
      // каждом фоновом обновлении (см. _recheckKeyExpiry).
      if (!_autoConnectTried) {
        _autoConnectTried = true;
        // По умолчанию выключено — автоподключение пользователь включает сам.
        final autoConnect = await LocalPrefs.instance.getBool(PrefKeys.autoConnect, fallback: false);
        // `_runtimeStateKnown` обязателен: если реальное состояние нативного
        // сервиса прочитать не удалось, isConnected ниже равен false просто
        // потому, что мы ничего не знаем, а не потому что VPN выключен — и
        // автоподключение подняло бы вторую сессию поверх работающей.
        if (autoConnect &&
            _runtimeStateKnown &&
            (_activeKey != null || _hasManualKey) &&
            !_tunnel.isConnected &&
            !_tunnel.isBusy) {
          unawaited(_toggleConnection());
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Текст ошибки зависит от того, есть ли что показать: ключ из кэша —
        // это "не удалось обновить", а не "НЕТ КЛЮЧА". Отдельно разбираем
        // частый случай, когда туннель поднят, но трафик через него не идёт:
        // тогда недоступен весь интернет на телефоне, и подсказка должна вести
        // к отключению VPN, а не к "проверь интернет".
        if (_activeKey != null) {
          _keyError = _tunnel.isConnected
              ? tr('Не удалось обновить данные через активный VPN — показан '
                  'последний сохранённый ключ. Если сайты тоже не '
                  'открываются, отключи VPN и подключись заново.')
              : tr('Не удалось обновить список ключей — показан последний '
                  'сохранённый.');
        } else {
          _keyError = '${tr('Не удалось проверить статус ключа:')} $e';
        }
        _loadingKey = false;
      });
    }
    if (!mounted) return;
    _measureLatency();
  }

  /// Тихая фоновая перепроверка ключей — без спиннера на весь экран.
  /// Три исхода:
  ///  1. Туннель не подключён — просто освежаем `_activeKey`.
  ///  2. Туннель подключён, и ключ, на котором он поднят, ещё активен —
  ///     ничего не трогаем: рвать рабочее соединение только потому, что
  ///     где-то есть ключ подлиннее, незачем.
  ///  3. Ключ, на котором поднят туннель, истёк — переключаемся на следующий
  ///     активный, а если активных больше нет, отключаемся и предлагаем
  ///     оформить подписку.
  Future<void> _recheckKeyExpiry() async {
    if (!mounted) return;
    List<dynamic> keys;
    try {
      keys = await _api.getKeys();
    } catch (_) {
      return; // сетевой сбой — не рвём текущее соединение из-за временной недоступности API
    }
    if (!mounted) return;

    final active = keys.cast<Map<String, dynamic>>().where(_isActive).toList();
    _sortByExpiryDesc(active);
    final newBest = active.isNotEmpty ? active.first : null;

    if (_hasManualKey && _tunnel.isConnected) {
      // Туннель поднят на ручном ключе — у него нет expiry_date из API,
      // поэтому логика "истёк/не истёк" сюда неприменима. Не трогаем
      // рабочее соединение.
      setState(() => _activeKey = newBest ?? _activeKey);
      return;
    }

    if (!_tunnel.isConnected || _connectedKeyId == null) {
      // Туннель не поднят прямо сейчас — просто освежаем список для UI.
      setState(() {
        _activeKey = newBest;
        _keyError = null;
      });
      return;
    }

    final connectedStillActive = keys
        .cast<Map<String, dynamic>>()
        .where((k) => (k['key_id'] as num?)?.toInt() == _connectedKeyId)
        .any(_isActive);
    if (connectedStillActive) {
      // Текущий рабочий ключ ещё не истёк — трогать активное соединение не нужно.
      setState(() => _activeKey = newBest ?? _activeKey);
      return;
    }

    // Ключ, на котором сейчас поднят туннель, истёк.
    if (newBest != null) {
      final connectionString = newBest['connection_string'] as String?;
      if (connectionString != null && connectionString.isNotEmpty) {
        setState(() {
          _activeKey = newBest;
          _connecting = true;
        });
        try {
          await _tunnel.disconnect();
          await _tunnel.connect(connectionString, preferredHostName: SelectedServer.hostName.value);
          _connectedKeyId = (newBest['key_id'] as num?)?.toInt();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(tr('Срок действия предыдущего ключа истёк — переключились на следующий активный ключ'))),
            );
          }
        } catch (e) {
          if (mounted) _showError('${tr('Ключ истёк, а переключиться на следующий не удалось:')} $e');
        } finally {
          if (mounted) setState(() => _connecting = false);
          _measureLatency();
        }
        return;
      }
    }

    // Активных ключей больше нет вообще — отключаем и честно предлагаем купить.
    _connectedKeyId = null;
    await _tunnel.disconnect();
    if (mounted) {
      setState(() {
        _activeKey = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Срок действия ключа истёк, других активных ключей нет — оформи новую подписку'))),
      );
    }
  }

  Future<void> _measureLatency() async {
    if (mounted) {
      setState(() {
        _latencyChecking = true;
        _latencyProbed = false;
      });
    }
    try {
      if (_tunnel.isConnected) {
        // Туннель поднят — берём число единого замерщика в TunnelService: это
        // URLTest самого ядра, полный запрос к http://cp.cloudflare.com/ через
        // VLESS. Ровно то же меряет и показывает Hiddify. Собственный пробник
        // здесь был бы вторым независимым замером — отсюда и расхождения вида
        // "215 мс" на главном при 70 мс у той же локации в другом клиенте.
        final ms = _tunnel.latencyForHostName(_tunnel.connectedServerName.value);
        if (mounted) setState(() => _latencyMs = ms);
        return;
      }
      // Туннель не поднят — меряем рукопожатие до того самого сервера, куда
      // пойдёт трафик. Раньше здесь стоял секундомер вокруг запроса к нашему
      // API: он не имеет отношения ни к VPN-серверу, ни к его задержке, и
      // показывал бодрые "15 мс" при неработающей локации.
      final connectionString = _effectiveConnectionString;
      if (connectionString == null || connectionString.isEmpty) {
        if (mounted) setState(() => _latencyMs = null);
        return;
      }
      final endpoints = await _tunnel.listProfileEndpoints(connectionString);
      if (endpoints.isEmpty) {
        if (mounted) setState(() => _latencyMs = null);
        return;
      }
      // Имя локации на экране (host_name из /hosts) и remark в подписке
      // различаются префиксом сервиса — сопоставляем по вхождению, как и
      // везде в приложении.
      final wanted = SelectedServer.hostName.value?.toLowerCase().trim();
      var endpoint = endpoints.values.first;
      if (wanted != null && wanted.isNotEmpty) {
        for (final entry in endpoints.entries) {
          final remark = entry.key.toLowerCase();
          if (remark == wanted ||
              remark.contains(wanted) ||
              wanted.contains(remark)) {
            endpoint = entry.value;
            break;
          }
        }
      }
      final ms = await TunnelService.measureEndpointPingMs(
        endpoint.host,
        endpoint.port,
        security: endpoint.security,
        sni: endpoint.sni,
      );
      if (mounted) setState(() => _latencyMs = ms);
    } catch (_) {
      if (mounted) setState(() => _latencyMs = null);
    } finally {
      if (mounted) {
        setState(() {
          _latencyChecking = false;
          _latencyProbed = true;
        });
      }
    }
  }

  Future<void> _toggleConnection() async {
    if (_connecting || _tunnel.isBusy) return;
    // Проверка наличия ключа нужна только для подключения. Отключение живого
    // туннеля не должно зависеть от того, ответил ли backend: список ключей не
    // грузится как раз тогда, когда туннель поднят, но трафик через него не
    // идёт, и кнопка "Отключить" переставала работать.
    if (!_tunnel.isConnected && _activeKey == null && !_hasManualKey) return;
    final connectionString = _effectiveConnectionString;

    if (_tunnel.isConnected) {
      setState(() => _connecting = true);
      // Сброс `_connecting` обязан пройти через finally: disconnect() может
      // бросить исключение (например, на "призрачном" статусе, когда UI
      // показывает "Подключено", а процесса за этим нет), и тогда флаг навсегда
      // остаётся true, а кнопка блокируется до перезапуска приложения.
      try {
        await _tunnel.disconnect();
        _connectedKeyId = null;
      } catch (e) {
        // Не даём ошибке разрушить экран — пользователь и так уже видит
        // "Отключить", а не тихо повисший спиннер; ошибку показываем, но
        // кнопка остаётся рабочей для повторной попытки.
        if (mounted) {
          _showError('${tr('Не удалось отключиться:')} $e');
        }
      } finally {
        // disconnect() асинхронный — экран мог закрыться, пока он выполнялся.
        if (mounted) setState(() => _connecting = false);
      }
      if (!mounted) return;
      _measureLatency();
      return;
    }

    if (connectionString == null || connectionString.isEmpty) {
      _showError(tr('Для этого ключа пока нет ссылки на конфигурацию сервера — обратись в поддержку.'));
      return;
    }

    setState(() => _connecting = true);
    try {
      // Передаём сервер, выбранный на ServersScreen, иначе туннель всегда
      // поднимается на первом сервере из подписки ключа.
      await _tunnel.connect(connectionString, preferredHostName: SelectedServer.hostName.value);
      // Запоминаем, к какому key_id реально подключился туннель — по нему
      // _recheckKeyExpiry() отличает "истёк рабочий ключ" от "появился ключ
      // подлиннее". У ручного ключа key_id нет, там null, и перепроверка такое
      // соединение не трогает.
      _connectedKeyId = _hasManualKey ? null : (_activeKey?['key_id'] as num?)?.toInt();
      _measureLatency();
    } on TunnelException catch (e) {
      _showError(e.message, fallbackConnectionString: connectionString);
    } catch (e) {
      _showError('${tr('Не удалось подключиться:')} $e', fallbackConnectionString: connectionString);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _showError(String message, {String? fallbackConnectionString}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.danger,
        // При ошибке подключения ведём в системные настройки VPN: самый частый
        // сценарий — разрешение на VPN отозвано вручную или его держит другое
        // VPN-приложение, программно это не чинится.
        action: fallbackConnectionString == null
            ? null
            : SnackBarAction(
                label: tr('Настройки VPN'),
                textColor: AppColors.violet2,
                onPressed: () => _tunnel.openSystemVpnSettingsHint(),
              ),
        duration: fallbackConnectionString == null
            ? const Duration(seconds: 4)
            : const Duration(seconds: 8),
      ),
    );
  }

  String get _timerLabel {
    final seconds = _tunnel.status.value?.duration ?? 0;
    final d = Duration(seconds: seconds);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  /// Принимает накопленный трафик сессии в байтах — `downloadTotalBytes` и
  /// `uploadTotalBytes`, а не мгновенную скорость.
  String _formatBytes(num? bytes) {
    if (bytes == null || bytes <= 0) return '0 MB';
    final mb = bytes / (1024 * 1024);
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  String get _latencyLabel {
    if (_latencyChecking && _latencyMs == null) return tr('проверка соединения…');
    // Ноль и отрицательное — это не замер, а его отсутствие: иначе значение
    // попадает в ветку `< 80` и выводится как "0 мс · отличный сигнал". Второй
    // рубеж: сам источник уже отфильтрован в _measureLatency().
    if (_latencyMs != null && _latencyMs! <= 0) {
      return _tunnel.isConnected
          ? tr('сервер не отвечает на проверку задержки')
          : tr('проверка соединения…');
    }
    if (_latencyMs == null) {
      // Замер завершился, но значения нет. До первого прогона это просто
      // "ещё меряем"; после — сервер не ответил, и говорить "проверка
      // соединения…" бесконечно нельзя: со стороны это выглядит как
      // зависший экран.
      if (!_latencyProbed) return tr('проверка соединения…');
      return tr('сервер не отвечает на проверку задержки');
    }
    // Пороги рассчитаны на настоящие миллисекунды. При поднятом туннеле это
    // URLTest ядра — полный HTTP-запрос через VLESS, где 150-400 мс обычное
    // дело (те же числа показывает Hiddify); до подключения — рукопожатие с
    // сервером, там значения меньше и в "отлично" попадают легко.
    if (_latencyMs! < 150) return '$_latencyMs ${tr('мс · отличный сигнал')}';
    if (_latencyMs! < 400) return '$_latencyMs ${tr('мс · стабильно')}';
    return '$_latencyMs ${tr('мс · медленно')}';
  }

  @override
  Widget build(BuildContext context) {
    final hasKey = _activeKey != null || _hasManualKey;
    final connected = _tunnel.isConnected;
    final s = _tunnel.status.value;
    // При ручном ключе `_activeKey` может отсутствовать: ключ есть, но
    // лимит устройств API не возвращал. Не разыменовываем nullable значение.
    final devicesLimit = (_activeKey?['devices_limit'] as num?)?.toInt();

    // Главный экран — то место, куда возвращаются сразу после смены языка в
    // "Настройках", поэтому подписка на LocaleService здесь особенно нужна.
    return AnimatedBuilder(
      animation: LocaleService.instance,
      builder: (context, _) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      child: Column(
        children: [
          AppHeader(trailing: Icons.menu_rounded, screenLabel: tr('Подключение')),
          // Честная пометка: ключ взят из сохранённой копии, потому что сервер не
          // отвечает. Без неё рабочее состояние не отличить от "показываю последнее,
          // что помню".
          if (_keysFromCache)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  const Icon(Icons.cloud_off_rounded, size: 14, color: AppColors.textDim),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(tr('Данные о ключах сохранённые — сервер сейчас не отвечает'),
                        style: const TextStyle(fontSize: 11, color: AppColors.textDim)),
                  ),
                ],
              ),
            ),
          if (_hasManualKey)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  const Icon(Icons.edit_note_rounded, size: 14, color: AppColors.violetGlow),
                  const SizedBox(width: 6),
                  Text(tr('Используется ключ, добавленный вручную'),
                      style: const TextStyle(fontSize: 11, color: AppColors.violetGlow, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          const SizedBox(height: 18),
          if (_tunnel.killSwitchBlocking.value)
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_rounded, color: AppColors.danger, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      tr('Туннель неожиданно оборвался — восстанавливаю соединение. '
                      'Интернет сейчас идёт БЕЗ защиты VPN.'),
                      style: const TextStyle(fontSize: 11.5, color: AppColors.text, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          _ConnectRing(
            connected: connected,
            // Если туннель реально поднят, кольцо не имеет права писать "НЕТ КЛЮЧА"
            // только потому, что /user/keys не ответил: состояние туннеля известно от
            // нативной стороны и от доступности backend не зависит.
            hasKey: hasKey || connected,
            // `_loadingKey` на плохой сети держится десятки секунд (повторы в
            // _fetchKeysWithRetry), и всё это время при живом VPN показывался бы
            // спиннер вместо "ПОДКЛЮЧЕНО". Спиннер в кольце нужен, только когда
            // показать нечего: идёт подключение либо первая загрузка при отключённом
            // туннеле и пустом кэше.
            loading: _connecting || (_loadingKey && !connected && !hasKey),
            timerLabel: _timerLabel,
          ),
          const SizedBox(height: 28),
          if (_keyError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _keyError!,
                    style: TextStyle(
                      // Красным — только когда показать действительно
                      // нечего. Если ключ есть (пусть и из кэша), это
                      // предупреждение, а не авария.
                      color: _activeKey != null
                          ? AppColors.textDim
                          : AppColors.danger,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Явная кнопка "повторить" рядом с текстом ошибки: pull-to-refresh на
                  // этом экране нет, а с IndexedStack возврат на вкладку больше не
                  // пересоздаёт экран и не запускает загрузку сам.
                  GestureDetector(
                    onTap: _loadingKey ? null : _loadKeyState,
                    child: Text(
                      tr('Повторить попытку'),
                      style: const TextStyle(
                        color: AppColors.violet2,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Builder(builder: (context) {
            // Имя сервера, к которому туннель реально подключён сейчас (если connect()
            // ушёл на резервный сервер подписки — покажет именно его), иначе
            // выбранный на ServersScreen, иначе "Автовыбор".
            final activeName = connected
                ? (_tunnel.connectedServerName.value ?? SelectedServer.displayName.value)
                : SelectedServer.displayName.value;
            final label = activeName != null
                ? _prettyServerName(activeName)
                : tr('Автовыбор');
            return ServerPill(
              code: _codeFromName(label),
              name: label,
              pingLabel: _latencyLabel,
              pingColor: (!_latencyChecking && _latencyMs != null && _latencyMs! < 200)
                  ? AppColors.success
                  : AppColors.textDim,
              trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textDim, size: 18),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ServersScreen())),
            );
          }),
          Row(
            children: [
              // Карточки "Приём"/"Отдача" подписаны как накопленный за сессию трафик,
              // поэтому читают downloadTotalBytes/uploadTotalBytes. `download`/`upload` —
              // мгновенная скорость с последнего тика sing-box: в секунду, когда ничего
              // не передавалось, она равна нулю, и карточки показывали "0.0 MB" всю
              // сессию.
              StatMiniCard(label: tr('Приём'), value: _formatBytes(s?.downloadTotalBytes)),
              const SizedBox(width: 10),
              StatMiniCard(label: tr('Отдача'), value: _formatBytes(s?.uploadTotalBytes)),
              const SizedBox(width: 10),
              StatMiniCard(
                label: tr('Устройств'),
                value: devicesLimit != null ? '$devicesLimit' : '—',
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (!hasKey && !connected && !_loadingKey)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () =>
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const PlansScreen())),
                child: Text(tr('Оформить подписку')),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    // Кнопка использует тот же флаг `_connecting || _tunnel.isBusy`, что и
                    // "Отключить". Иначе она оставалась активной те секунды, пока в фоне
                    // выполняется disconnect(): экран "Выбор сервера" смотрит на
                    // _tunnel.isConnected, а тот в этом окне ещё true — отсюда "Нет активного
                    // туннеля" при статусе "ПОДКЛЮЧЕНО" на экране.
                    onPressed: (_connecting || _tunnel.isBusy)
                        ? null
                        : () => Navigator.push(
                            context, MaterialPageRoute(builder: (_) => const ServersScreen())),
                    child: Text(tr('Сменить сервер')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    // `_loadingKey` в условии блокировки быть не должно — см. комментарий в
                    // _toggleConnection(): пока грузится список ключей, "Отключить" на
                    // поднятом туннеле обязана оставаться нажимаемой.
                    onPressed: (_connecting ||
                            _tunnel.isBusy ||
                            (!connected && !hasKey))
                        ? null
                        : _toggleConnection,
                    style: connected
                        ? ElevatedButton.styleFrom(backgroundColor: const Color(0xFF241028))
                        : null,
                    child: (_connecting || _tunnel.isBusy)
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : Text(connected ? tr('Отключить') : tr('Подключить')),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 14),
          PillButton(
            label: tr('Тест скорости'),
            icon: '⚡',
            onTap: () {
              if (!connected) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(tr('Тест скорости доступен после подключения к серверу'))),
                );
                return;
              }
              _measureLatency();
            },
          ),
        ],
      ),
      ),
    );
  }
}

class _ConnectRing extends StatelessWidget {
  const _ConnectRing({
    required this.connected,
    required this.hasKey,
    required this.loading,
    required this.timerLabel,
  });

  final bool connected;
  final bool hasKey;
  final bool loading;
  final String timerLabel;

  @override
  Widget build(BuildContext context) {
    final ringColor = !hasKey ? AppColors.danger : (connected ? AppColors.violet2 : AppColors.border);
    return SizedBox(
      width: 200,
      height: 200,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Внешнее свечение — .globe-bg аналог за кольцом.
          Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [AppColors.violet2.withOpacity(connected ? 0.14 : 0.05), Colors.transparent],
              ),
            ),
          ),
          SizedBox(
            width: 200,
            height: 200,
            child: CustomPaint(
              painter: _RingPainter(
                progress: connected ? 0.86 : (hasKey ? 0.18 : 0.04),
                color: ringColor,
                glow: connected,
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.violetGlow),
                )
              else ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: !hasKey ? AppColors.danger : (connected ? AppColors.success : AppColors.textDim),
                    boxShadow: connected
                        ? AppColors.glow(AppColors.success, blur: 8, alpha: 0.8)
                        : null,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  !hasKey ? tr('НЕТ КЛЮЧА') : (connected ? tr('ПОДКЛЮЧЕНО') : tr('ОТКЛЮЧЕНО')),
                  style: orbitron(fontSize: 15, letterSpacing: 1),
                ),
                const SizedBox(height: 4),
                Text(tr('VLESS · Reality'), style: const TextStyle(color: AppColors.textDim, fontSize: 11)),
                if (connected) ...[
                  const SizedBox(height: 10),
                  Text(timerLabel,
                      style: orbitron(fontSize: 11, color: AppColors.violetGlow, fontWeight: FontWeight.w500)),
                ],
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Кольцо с градиентной обводкой и свечением — воспроизводит SVG
/// .ring-fg с linearGradient(#a855f7 → #8b5cf6) и drop-shadow из макета.
class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.color, required this.glow});
  final double progress; // 0..1 доля дуги
  final Color color;
  final bool glow;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 6;
    final bgPaint = Paint()
      ..color = const Color(0xFF1C1330)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, bgPaint);

    final rect = Rect.fromCircle(center: center, radius: radius);
    final gradient = SweepGradient(
      startAngle: -1.5708,
      endAngle: -1.5708 + 6.28319,
      colors: const [AppColors.violet2, AppColors.violet, AppColors.violet2],
      stops: const [0.0, 0.5, 1.0],
    );
    final fgPaint = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    if (glow) {
      fgPaint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    }
    final sweep = 6.28319 * progress;
    canvas.drawArc(rect, -1.5708, sweep, false, fgPaint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color || oldDelegate.glow != glow;
}