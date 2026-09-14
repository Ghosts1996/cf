import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show MethodChannel, PlatformException, MissingPluginException;
import 'package:flutter_singbox_client/flutter_singbox_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:app_settings/app_settings.dart';
import 'app_log_service.dart';
import 'local_prefs.dart';
import 'singbox_runtime.dart';

class TunnelService {
  TunnelService._();
  static final TunnelService instance = TunnelService._();

  final SingboxRuntimeClient _client = createSingboxRuntime();

  // Верхняя граница на любой вызов в нативный код плагина.
  //
  // `_client.disconnect()`, `_client.getServiceState()` и остальные — это
  // MethodChannel-вызовы в Kotlin-код flutter_singbox_client (git-зависимость,
  // см. pubspec.yaml). Если нативная сторона не отвечает — застрявший
  // foreground VpnService случается на части прошивок, особенно после того как
  // ОС заморозила процесс в фоне, — await на такой строке не завершается
  // никогда, и весь код после него (сброс `_connecting`, finally, обновление
  // status) просто не выполняется. Отсюда кнопка "Отключить", залипшая в
  // "отключается", и зависание при повторном открытии приложения.
  //
  // Починить зависший нативный сервис отсюда нельзя, но Dart-сторона и
  // интерфейс висеть вместе с ним не должны: через 8 секунд управление
  // вернётся вызывающему коду через TimeoutException. Если сервис отпустит
  // позже сам, serviceStateStream всё равно пришлёт настоящее состояние.
  static const Duration _nativeCallTimeout = Duration(seconds: 8);

  Future<void> _disconnectNative() => _client.disconnect().timeout(_nativeCallTimeout);

  Future<dynamic> _getServiceStateNative() =>
      _client.getServiceState().timeout(_nativeCallTimeout);
  static const _nativeStatsChannel = MethodChannel('vpnonline/native_stats');
  bool _initialized = false;
  // Выключен по умолчанию — совпадает с fallback при чтении из LocalPrefs в
  // connect(), пока не переопределится сохранённым значением.
  bool _killSwitchEnabled = false;
  // См. PrefKeys.strictKillSwitch: "физически блокировать трафик", а не
  // только "пытаться переподключиться".
  bool _strictKillSwitchEnabled = false;
  // true, пока активна служебная блокирующая сессия (_engageHardKillSwitch):
  // чтобы не поднимать её повторно и чтобы disconnect()/connect() знали, что
  // снимать нужно именно её, а не обычную сессию.
  bool _hardKillSwitchEngaged = false;
  // true, пока идёт одноразовая тестовая сессия realCheckProfile(). Нужен
  // только чтобы disconnect()/connect() не стартовали поверх незавершённой
  // проверки; изоляция публичного status сделана временной отпиской от
  // стримов внутри самого realCheckProfile().
  bool _probeInProgress = false;
  bool _userInitiatedDisconnect = false;
  String? _lastConnectionString;
  String? _lastPreferredHostName;
  int _autoReconnectAttempt = 0;
  // Читается из LocalPrefs при каждом connect() — тумблер "Агрессивное
  // переподключение" на экране "Безопасность".
  int _maxAutoReconnectAttempts = 3;

  StreamSubscription? _stateSub;
  StreamSubscription? _statsSub;
  StreamSubscription? _faultSub;
  StreamSubscription? _coreLogSub;
  DateTime? _connectStartedAt;
  int _downloadTotalBytes = 0;
  int _uploadTotalBytes = 0;
  int _displayDownloadBytes = 0;
  int _displayUploadBytes = 0;
  DateTime? _lastTrafficAt;
  int? _lastNativeRxBytes;
  int? _lastNativeTxBytes;
  DateTime? _lastNativeStatsAt;
  bool _nativeStatsPolling = false;
  // Тикает раз в секунду, пока статус connected, чтобы таймер сессии на
  // экране реально считал время. См. _restartDurationTicker.
  Timer? _durationTicker;
  bool _runtimeStateSynced = false;
  // Пока syncRuntimeState() восстанавливает `_connectStartedAt` из
  // LocalPrefs, _applyServiceState() не должен сам его трогать — ни ставить
  // DateTime.now(), ни обнулять сохранённое значение. Этот флаг выключает обе
  // его ветки на время восстановления: единственный источник истины в этом
  // окне — сама syncRuntimeState().
  bool _restoringConnectStartedAt = false;

  // Зеркало того, что лежит на диске о текущей сессии. Читается один раз в
  // начале _initializeOnce() — до подписки на serviceStateStream, то есть до
  // того, как нативная сторона физически может прислать первое событие.
  //
  // Если читать момент старта только внутри syncRuntimeState(), то при её
  // падении или таймауте пришедшее по стриму "connected" попадает в
  // _applyServiceState() с пустым `_connectStartedAt`, тот подставляет
  // DateTime.now() — счётчик стартует заново на не отключавшемся туннеле, а
  // сохранённое время тут же затирается этим now.
  int _persistedConnectedAtMillis = 0;
  String? _persistedConnectionString;
  String? _persistedPreferredHost;
  String? _persistedServerName;
  // Кэшируется сам Future, а не флаг "уже загружено": флаг, взводимый
  // синхронно до завершения чтения с диска, — та же ошибка, что была в
  // ManualKeyStore (см. local_prefs.dart).
  Future<void>? _persistedSessionLoadFuture;

  // Сохранённая отметка старше этого срока считается мусором, оставшимся
  // от давно завершившейся сессии (процесс мог быть убит до того, как в
  // LocalPrefs успел записаться ноль). Без верхней границы такой мусор
  // однажды показал бы "сессия идёт 43 дня" на только что поднятом туннеле.
  static const Duration _maxRestorableSessionAge = Duration(days: 7);

  // true, пока выполняется connect(). Цикл авто-переподключения Kill Switch
  // (_onStatusChanged) не должен запускать второй connect() поверх идущего:
  // connect() между попытками сам гасит сессию (_settleAfterDisconnect), и
  // каждое гашение приходит сюда обычным "disconnected" — иначе это
  // считалось бы обрывом и планировало ещё одно подключение параллельно
  // перебору серверов.
  bool _connectInProgress = false;

  // true на время смены сервера у поднятого туннеля (switchPreferredHost).
  // Технически это разрыв и новое подключение, но для пользователя — одна
  // непрерывная сессия: он не отключался, трафик просто пошёл через другую
  // страну. Флаг говорит остальному коду не обнулять то, что относится к
  // сессии целиком: счётчик времени, счётчики трафика и данные для
  // восстановления.
  bool _switchInProgress = false;

  // Порядок локаций, в котором они легли в конфиг текущей сессии: индекс в
  // списке равен цифре в теге outbound'а (`out-0`, `out-1`, ...). Пустой
  // список означает сессию с одним outbound'ом — тогда мгновенное
  // переключение недоступно и switchPreferredHost() идёт через разрыв.
  List<_ParsedVless> _sessionOutboundOrder = const <_ParsedVless>[];
  // Гасится до перезапуска приложения, если ядро отвергло конфиг с
  // группой-селектором: дальше собираем сессию одним outbound'ом.
  bool _selectorSupported = true;

  // Имя пакета этой сборки — нужно, чтобы исключить само приложение из
  // туннеля (PrefKeys.excludeAppFromTunnel, _resolveSelfPackageName ниже).
  // Спрашивается у системы один раз за запуск и кэшируется.
  static const _fallbackSelfPackage = 'su.vpnonline.vpnonline_app';
  Future<String?>? _selfPackageFuture;

  // ══════════════════════════════════════════════════════════════════
  // Единый замерщик задержки при поднятом туннеле
  // ══════════════════════════════════════════════════════════════════
  //
  // Почему число на экране скакало (189 → 246 → 194 → 5520 → 207 мс у одной
  // локации за несколько минут):
  //
  //  1. Замер запускали два экрана независимо: список серверов по своему
  //     таймеру, главный — своим пробником через локальный прокси. Два
  //     прогона по одной группе outbound'ов мешают друг другу.
  //  2. Пробный запрос идёт по тому же соединению, что и трафик пользователя:
  //     при включённом Mux (а он включён по умолчанию) все потоки outbound'а
  //     лежат в одном TCP-соединении, и пока качается видео, пробник стоит в
  //     очереди за данными. 5520 мс — это глубина очереди, а не сеть.
  //  3. Каждое единичное значение сразу попадало на экран: один выброс — и
  //     авто-балансировка могла дёрнуть туннель на другую страну.
  //
  // Поэтому: один таймер на весь сервис, один прогон за раз, пауза между
  // прогонами, пропуск цикла при заметном трафике и публикация медианы трёх
  // последних замеров. Экраны только читают `latencyByRemark`.

  /// Задержка до каждой локации подписки, ключ — remark из VLESS-ссылки.
  /// Значение уже сглажено (медиана трёх последних измерений). Локации,
  /// до которых ядро не достучалось в последнем прогоне, здесь отсутствуют.
  final ValueNotifier<Map<String, int>> latencyByRemark =
      ValueNotifier(const <String, int>{});

  Timer? _latencyProbeTimer;
  bool _latencyProbeRunning = false;
  final Map<String, List<int>> _latencySamples = {};
  static const Duration _latencyProbeInterval = Duration(seconds: 25);
  /// Сколько последних замеров участвует в выборе минимума. Больше окно —
  /// устойчивее число, но дольше реакция на реальное ухудшение канала.
  static const int _latencySampleWindow = 5;
  // Выше этой скорости (байт/с в любую сторону) прогон пропускается —
  // пробник встанет в очередь за реальными данными и измерит не сеть.
  static const int _latencyProbeBusyBps = 300 * 1024;

  // Отложенное стирание сохранённого момента старта сессии — см.
  // _schedulePersistedStartWipe(). null, когда стирание не запланировано.
  Timer? _persistedStartWipeTimer;

  final ValueNotifier<TunnelStatus?> status = ValueNotifier(null);
  final ValueNotifier<String?> lastError = ValueNotifier(null);
  final ValueNotifier<bool> killSwitchBlocking = ValueNotifier(false);
  // true, когда строгий Kill Switch физически держит интернет
  // заблокированным (после исчерпания попыток переподключения) — в отличие от
  // killSwitchBlocking, который включается уже на первой попытке и означает
  // просто "идёт восстановление".
  final ValueNotifier<bool> hardKillSwitchActive = ValueNotifier(false);
  final ValueNotifier<String?> connectedServerName = ValueNotifier(null);
  final ValueNotifier<String?> localProxyAddress = ValueNotifier(null);

  bool get isConnected => status.value?.state == TunnelConnState.connected;
  bool get isBusy =>
      status.value?.state == TunnelConnState.connecting ||
      status.value?.state == TunnelConnState.disconnecting;

  String? _cachedSource;
  List<_ParsedVless>? _cachedProfiles;
  DateTime? _cachedAt;
  static const _cacheTtl = Duration(seconds: 45);

  // Кэшируем сам Future первой инициализации. Два почти одновременных вызова
  // _ensureInitialized() оба видели бы `_initialized == false` и оба дошли до
  // подписки на стримы — реальный сценарий при холодном старте, когда
  // RootShell монтирует все вкладки одним кадром и ConnectScreen идёт в
  // syncRuntimeState(), а ServersScreen параллельно в realCheckProfile().
  // Вторая подписка затирала поля `_stateSub`/`_statsSub`/`_faultSub`, первая
  // продолжала жить: _applyServiceState вызывался дважды на каждое событие, а
  // dispose() отменял только последнюю.
  Future<void>? _initializing;

  Future<void> _ensureInitialized() {
    if (_initialized) return Future<void>.value();
    return _initializing ??= _initializeOnce();
  }

  Future<void> _initializeOnce() async {
    try {
      // Сохранённое состояние сессии читаем ДО подписки на стримы: как
      // только подписка оформлена, нативная сторона может прислать событие
      // в любой момент, а `_applyServiceState()` обязан к этому моменту уже
      // знать сохранённый момент старта (см. `_restorableConnectStart`),
      // иначе он подставит `DateTime.now()` и обнулит счётчик работающей
      // сессии.
      await _loadPersistedSession();
      await _applyCompatDefaults();
      // Таймаут нужен и здесь: `_client.initialize()` — тоже MethodChannel-вызов,
      // и он единственный оставался без ограничения по времени. Если после свайпа
      // приложения из списка задач foreground VpnService подвис, await на этой
      // строке не завершается никогда, а вместе с ним не завершается и вся
      // цепочка выше: syncRuntimeState() -> _bootstrapConnectionState() ->
      // _loadKeyState(). Экран навсегда остаётся в загрузке.
      await _client.initialize().timeout(_nativeCallTimeout);
    } on TimeoutException {
      lastError.value = 'Ядро VPN не ответило за '
          '${_nativeCallTimeout.inSeconds} с — состояние туннеля может быть '
          'неточным. Если VPN не отключается, отключи его из шторки '
          'уведомлений.';
    } catch (_) {
      // Инициализация провалилась не по таймауту, а по существу — старое
      // поведение сохраняем: ошибка уходит вызывающему коду, `_initialized`
      // остаётся false, следующий вызов попробует ещё раз (для этого
      // сбрасываем кэш Future, иначе повторная попытка вечно получала бы
      // ту же самую упавшую Future).
      _initializing = null;
      rethrow;
    }

    try {
      _stateSub = _client.serviceStateStream.listen(_applyServiceState);
      _statsSub = _client.trafficStatsStream.listen(_applyTrafficStats);
      _faultSub = _client.faultStream.listen((error) {
        lastError.value = error.toString();
      });
      // Предупреждения и ошибки самого ядра — единственное место, где видно
      // настоящую причину "подключено, а трафика нет": отказ сервера в
      // рукопожатии, непонятый транспорт, сорванный резолв. Без этой
      // подписки они оставались только в logcat. Пишем в тот же журнал, что
      // показывает экран "Безопасность", и не трогаем info/debug — иначе
      // полезное тонет в служебном потоке.
      _coreLogSub = _client.coreLogStream.listen((entries) {
        if (entries is! List) return;
        for (final entry in entries) {
          final level = entry.level;
          if (level == LogLevel.warn) {
            AppLogService.instance
                .log('Ядро: ${entry.message}', level: AppLogLevel.warning);
          } else if (level == LogLevel.error ||
              level == LogLevel.fatal ||
              level == LogLevel.panic) {
            AppLogService.instance
                .log('Ядро: ${entry.message}', level: AppLogLevel.error);
          }
        }
      });
    } catch (e) {
      // Плагин мог не отдать стримы, если его initialize() выше отвалился
      // по таймауту. Это не повод рушить весь запуск приложения — состояние
      // всё равно будет перечитано явным getServiceState() в
      // syncRuntimeState(), просто без живых обновлений по подписке.
      lastError.value = 'Не удалось подписаться на события ядра VPN: $e';
    }

    _initialized = true;
  }

  /// Разовый сброс трёх настроек, которые раньше включались по умолчанию и
  /// ломают трафик на серверах Xray (вся линейка x-ui, включая 3x-ui):
  /// мультиплексор, Fake IP и фрагментация TLS. Симптом одинаковый и
  /// обманчивый — туннель поднимается, счётчик времени идёт, а любой сайт
  /// отвечает разрывом соединения.
  ///
  /// Сбрасываем именно сохранённые значения, а не выставляем новые: после
  /// миграции пользователь волен включить любую из трёх обратно, и второй раз
  /// его выбор никто не тронет.
  Future<void> _applyCompatDefaults() async {
    try {
      final prefs = LocalPrefs.instance;
      if (await prefs.getBool(PrefKeys.compatDefaultsApplied)) return;
      await prefs.remove(PrefKeys.muxEnabled);
      await prefs.remove(PrefKeys.fakeIpDns);
      await prefs.remove(PrefKeys.dpiBypass);
      await prefs.setBool(PrefKeys.compatDefaultsApplied, true);
    } catch (_) {
      // Недоступный SharedPreferences не должен мешать запуску: в худшем
      // случае миграция повторится при следующем старте.
    }
  }

  /// Однократное чтение сохранённого состояния сессии с диска. Никогда не
  /// бросает наружу: недоступный или битый SharedPreferences не должен мешать
  /// запуску приложения — в худшем случае не восстановится счётчик.
  Future<void> _loadPersistedSession() {
    return _persistedSessionLoadFuture ??= _loadPersistedSessionOnce();
  }

  Future<void> _loadPersistedSessionOnce() async {
    try {
      _persistedConnectedAtMillis = await LocalPrefs.instance
          .getInt(PrefKeys.tunnelConnectedAtMillis, fallback: 0);
      final raw =
          await LocalPrefs.instance.getString(PrefKeys.tunnelSessionRouteJson);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final savedConnectionString = decoded['connection_string'];
      final savedPreferredHost = decoded['preferred_host'];
      final savedServerName = decoded['server_name'];
      _persistedConnectionString =
          savedConnectionString is String && savedConnectionString.isNotEmpty
              ? savedConnectionString
              : null;
      _persistedPreferredHost =
          savedPreferredHost is String && savedPreferredHost.isNotEmpty
              ? savedPreferredHost
              : null;
      _persistedServerName =
          savedServerName is String && savedServerName.isNotEmpty
              ? savedServerName
              : null;
    } catch (_) {
      // Значения остаются нулевыми/null — восстановления просто не будет.
    }
  }

  /// Сохранённый момент старта сессии, если ему можно доверять. `null`
  /// означает "нет пригодного значения" — вызывающий код в этом случае
  /// начинает отсчёт заново.
  DateTime? _restorableConnectStart() {
    if (_persistedConnectedAtMillis <= 0) return null;
    final saved =
        DateTime.fromMillisecondsSinceEpoch(_persistedConnectedAtMillis);
    final now = DateTime.now();
    // Время на устройстве перевели назад (или часовой пояс сменился так,
    // что отметка оказалась "в будущем") — считать разницу бессмысленно.
    if (saved.isAfter(now)) return null;
    if (now.difference(saved) > _maxRestorableSessionAge) return null;
    return saved;
  }

  /// Стирание сохранённого времени старта с отложенной паузой.
  ///
  /// Нативная сторона вполне может прислать короткую пару
  /// disconnected -> connected на живом туннеле: при возврате приложения из
  /// фона, пересоздании Activity, переключении Wi-Fi и мобильной сети,
  /// повторной привязке плагина к работающему foreground VpnService.
  /// Немедленное стирание превращало такой миг в потерю истории сессии —
  /// обратно приходило "connected", восстанавливать было нечего, и отсчёт
  /// начинался с нуля при живом туннеле.
  ///
  /// Настоящее отключение паузы не замечает: она короткая, а disconnect()
  /// стирает сохранённое сразу, не дожидаясь её.
  void _schedulePersistedStartWipe() {
    _persistedStartWipeTimer?.cancel();
    _persistedStartWipeTimer = Timer(const Duration(seconds: 5), () {
      _persistedStartWipeTimer = null;
      // За время паузы туннель мог вернуться — тогда стирать нечего.
      if (isConnected) return;
      _persistConnectStart(null);
      _clearPersistedSessionRoute();
    });
  }

  void _cancelPersistedStartWipe() {
    _persistedStartWipeTimer?.cancel();
    _persistedStartWipeTimer = null;
  }

  /// Пишет момент старта сессии и на диск, и в зеркало в памяти — оба
  /// источника обязаны меняться вместе, иначе `_restorableConnectStart()`
  /// вернёт устаревшее значение уже в этом же запуске приложения.
  void _persistConnectStart(DateTime? at) {
    final millis = at?.millisecondsSinceEpoch ?? 0;
    _persistedConnectedAtMillis = millis;
    unawaited(
        LocalPrefs.instance.setInt(PrefKeys.tunnelConnectedAtMillis, millis));
  }

  /// Сохраняет, чем именно поднят текущий туннель: подписка, предпочтённая
  /// локация и имя сервера, к которому реально подключились.
  ///
  /// `_lastConnectionString` — поле в памяти, оно исчезает вместе с
  /// процессом. После закрытия приложения свайпом (при том что foreground
  /// VpnService продолжает работать) на живом туннеле оно было null, и
  /// ломались сразу две вещи: switchPreferredHost() отвечал "Нет активного
  /// туннеля" на кнопку "Сменить сервер", а _onStatusChanged() молча
  /// выходил по проверке `_lastConnectionString == null` — Kill Switch и
  /// авто-переподключение не работали до первого ручного подключения.
  void _persistSessionRoute() {
    _persistedConnectionString = _lastConnectionString;
    _persistedPreferredHost = _lastPreferredHostName;
    _persistedServerName = connectedServerName.value;
    final payload = <String, String>{
      if (_lastConnectionString != null)
        'connection_string': _lastConnectionString!,
      if (_lastPreferredHostName != null)
        'preferred_host': _lastPreferredHostName!,
      if (connectedServerName.value != null)
        'server_name': connectedServerName.value!,
    };
    unawaited(LocalPrefs.instance
        .setString(PrefKeys.tunnelSessionRouteJson, jsonEncode(payload)));
  }

  void _clearPersistedSessionRoute() {
    _persistedConnectionString = null;
    _persistedPreferredHost = null;
    _persistedServerName = null;
    unawaited(
        LocalPrefs.instance.setString(PrefKeys.tunnelSessionRouteJson, ''));
  }

  void _applyServiceState(dynamic state) {
    // События служебной блокирующей сессии строгого Kill Switch не должны
    // ни затрагивать публичный status, счётчики времени и трафика обычного
    // туннеля, ни запускать авто-переподключение через _onStatusChanged.
    if (_hardKillSwitchEngaged) return;
    // var, а не final: при смене сервера промежуточное "отключено"
    // подменяется на "подключение" — см. ниже.
    var mapped = _mapServiceState(state);
    final prevDownload = status.value?.download ?? 0;
    final prevUpload = status.value?.upload ?? 0;

    // Пока идёт восстановление (`_restoringConnectStartedAt == true`), обе
    // ветки ниже не трогают `_connectStartedAt`: менять его в этом окне
    // разрешено только syncRuntimeState(). Иначе событие "не подключено",
    // которое плагин часто присылает сразу при подписке на стрим — раньше, чем
    // выполнится явный getServiceState(), — считалось бы концом сессии и
    // стёрло сохранённое время; пришедшее следом настоящее "connected" уже не
    // находило бы его и подставляло DateTime.now().
    //
    // Во время смены сервера промежуточное "отключено" наружу не публикуется —
    // показываем "подключение", иначе экран на несколько секунд мигает
    // "ОТКЛЮЧЕНО", хотя пользователь ничего не отключал. Подменяем только
    // когда не идёт сам connect(): между попытками разных серверов он зовёт
    // _settleAfterDisconnect(), который ждёт именно `disconnected` в этом же
    // status, и подмена заставила бы его висеть до полного таймаута.
    if (_switchInProgress &&
        !_connectInProgress &&
        mapped == TunnelConnState.disconnected) {
      mapped = TunnelConnState.connecting;
    }

    if (!_restoringConnectStartedAt) {
      if (mapped == TunnelConnState.connected && _connectStartedAt == null) {
        // Сначала спрашиваем сохранённое значение (оно прочитано с диска ещё до
        // подписки на стрим, см. _loadPersistedSession), и `now` берём, только
        // если пригодного сохранённого действительно нет. Безусловный `now` здесь
        // означал бы, что любое "connected" мимо окна восстановления —
        // syncRuntimeState() подвисла, отвалилась по таймауту или не успела —
        // считается началом новой сессии и затирает настоящее время старта.
        final restored = _restorableConnectStart();
        _connectStartedAt = restored ?? DateTime.now();
        if (restored == null && _runtimeStateSynced) {
          _persistConnectStart(_connectStartedAt);
        }
      }
      // Сессия считается завершённой только по настоящему 'disconnected'. На
      // промежуточных 'connecting'/'disconnecting' отметку стирать нельзя:
      // плагин при повторном подключении Flutter-стороны к работающему сервису
      // вполне присылает сначала 'connecting', и между этими двумя событиями в
      // LocalPrefs успевал записаться ноль.
      if (mapped == TunnelConnState.connected) {
        // Туннель на месте — если стирание было запланировано мигом ранее,
        // отменяем его (см. _schedulePersistedStartWipe).
        _cancelPersistedStartWipe();
      }
      // Во время смены сервера отметку старта не трогаем: для пользователя
      // сессия продолжается, счётчик не должен прыгать на ноль.
      if (mapped == TunnelConnState.disconnected && !_switchInProgress) {
        // Отметку в памяти сбрасываем сразу — от неё зависит то, что видит
        // пользователь. Запись на диске переживает короткую паузу, см.
        // _schedulePersistedStartWipe().
        _connectStartedAt = null;
        if (_runtimeStateSynced) {
          _schedulePersistedStartWipe();
        }
      }
    }
    // Соединение для замера задержки (см. докстринг `_delayProbeClient`)
    // прогрето под конкретный сеанс туннеля — вне зависимости от флага
    // восстановления выше, если сеанс на самом деле закончился, прогретый
    // канал больше ни на что не годен и его нужно закрыть. `_closeDelayProbeClient()`
    // безопасно вызывать и когда клиента ещё не существует (ничего не делает).
    if (mapped != TunnelConnState.connected) {
      _closeDelayProbeClient();
    }

    // duration обновляет отдельный Timer.periodic (_restartDurationTicker):
    // serviceStateStream шлёт событие только при смене состояния, а не каждую
    // секунду, поэтому после перехода в connected значение застывало на нуле.
    _restartDurationTicker(mapped == TunnelConnState.connected);

    status.value = TunnelStatus(
      state: mapped,
      duration: mapped == TunnelConnState.connected
          ? DateTime.now()
              .difference(_connectStartedAt ?? DateTime.now())
              .inSeconds
          : 0,
      download: prevDownload,
      upload: prevUpload,
      downloadTotalBytes:
          mapped == TunnelConnState.connected ? _downloadTotalBytes : 0,
      uploadTotalBytes:
          mapped == TunnelConnState.connected ? _uploadTotalBytes : 0,
    );
    _onStatusChanged(mapped);
  }

  void _applyTrafficStats(dynamic stats) {
    final current = status.value;
    if (current == null) return;
    final now = DateTime.now();
    final nextDownloadTotal = stats.downlinkTotalBytes as int;
    final nextUploadTotal = stats.uplinkTotalBytes as int;
    // На части версий libbox total остаётся нулевым, хотя каждый тик
    // содержит throughput. Накапливаем его сами, чтобы UI не сбрасывался.
    final reportedDownload = nextDownloadTotal > _displayDownloadBytes
        ? nextDownloadTotal
        : _displayDownloadBytes +
            ((stats.downlinkBps as num).toDouble().clamp(0, 1e12)).round();
    final reportedUpload = nextUploadTotal > _displayUploadBytes
        ? nextUploadTotal
        : _displayUploadBytes +
            ((stats.uplinkBps as num).toDouble().clamp(0, 1e12)).round();
    _displayDownloadBytes = reportedDownload;
    _displayUploadBytes = reportedUpload;
    final elapsedSeconds = _lastTrafficAt == null
        ? 0.0
        : now.difference(_lastTrafficAt!).inMilliseconds / 1000.0;
    final derivedDownload = elapsedSeconds > 0
        ? ((nextDownloadTotal - _downloadTotalBytes) / elapsedSeconds)
            .round()
            .clamp(0, 1 << 62)
        : 0;
    final derivedUpload = elapsedSeconds > 0
        ? ((nextUploadTotal - _uploadTotalBytes) / elapsedSeconds)
            .round()
            .clamp(0, 1 << 62)
        : 0;
    _lastTrafficAt = now;
    _downloadTotalBytes = reportedDownload;
    _uploadTotalBytes = reportedUpload;
    status.value = TunnelStatus(
      state: current.state,
      duration: current.state == TunnelConnState.connected
          ? DateTime.now()
              .difference(_connectStartedAt ?? DateTime.now())
              .inSeconds
          : current.duration,
      // На некоторых версиях libbox мгновенные up/down приходят нулевыми,
      // хотя session total растёт: тогда берём скорость, посчитанную по дельте
      // totals, и только если и она нулевая — оставляем прошлое значение.
      // Без промежуточного шага цифра залипала на последнем ненулевом замере:
      // `current.*` не пересчитывается сам, а UID-счётчики Android не видят
      // трафик других приложений.
      download: stats.downlinkBps > 0
          ? stats.downlinkBps
          : (derivedDownload > 0 ? derivedDownload : current.download),
      upload: stats.uplinkBps > 0
          ? stats.uplinkBps
          : (derivedUpload > 0 ? derivedUpload : current.upload),
      downloadTotalBytes: reportedDownload,
      uploadTotalBytes: reportedUpload,
    );
  }

  /// Перечитывает фактическое состояние нативного foreground-сервиса.
  /// Пока Activity была в фоне или пересоздавалась, событие Dart-стрима
  /// могло потеряться, хотя VPN продолжает работать.
  ///
  /// `_ensureInitialized()` внутри подписывает _applyServiceState на
  /// serviceStateStream, и нативная сторона может прислать своё (не всегда
  /// точное) состояние раньше, чем завершится явный getServiceState() ниже.
  /// Флаг `_restoringConnectStartedAt` не даёт входящим событиям трогать
  /// `_connectStartedAt`, пока этот метод не проставит правильное значение.
  ///
  /// Возвращает true, если состояние нативной стороны действительно удалось
  /// прочитать. ConnectScreen._bootstrapConnectionState() использует это,
  /// чтобы не запускать автоподключение вслепую: при неизвестном состоянии
  /// приложение решило бы, что VPN выключен, и подняло бы вторую сессию
  /// поверх работающей.
  Future<bool> syncRuntimeState() {
    // Тот же приём, что в _ensureInitialized(): вызовов два (initState экрана
    // и возврат приложения из фона), и они могут пересечься. Два одновременных
    // восстановления мешали бы друг другу через общий флаг
    // `_restoringConnectStartedAt` — закончивший первым снял бы защиту у
    // второго посреди работы.
    return _syncingRuntimeState ??= _syncRuntimeStateOnce().whenComplete(() {
      _syncingRuntimeState = null;
    });
  }

  Future<bool>? _syncingRuntimeState;

  Future<bool> _syncRuntimeStateOnce() async {
    _restoringConnectStartedAt = true;
    var synced = false;
    try {
      await _ensureInitialized();
      final actualState = await _getServiceStateNative();
      final actuallyConnected =
          _mapServiceState(actualState) == TunnelConnState.connected;
      // Сначала восстанавливаем момент подключения и лишь затем публикуем
      // состояние: иначе экран при возврате в приложение кратко покажет
      // 00:00:00 на давно поднятом туннеле.
      if (actuallyConnected) {
        // Читаем не с диска повторно, а из уже загруженного зеркала — и через ту
        // же проверку на вменяемость значения, что и в _applyServiceState().
        final restored = _restorableConnectStart();
        // Если сохранённого значения нет (первый запуск после обновления, чистая
        // установка поверх работающего туннеля, стёртые данные), фиксируем и
        // сохраняем старт прямо здесь: `_runtimeStateSynced` взводится только в
        // finally, то есть позже, и _applyServiceState() записать его на диск ещё
        // не сможет — отсчёт шёл бы в памяти, но не переживал перезапуск.
        _connectStartedAt = restored ?? DateTime.now();
        if (restored == null) _persistConnectStart(_connectStartedAt);
        // Туннель поднят, но процесс приложения перезапускался:
        // `_lastConnectionString`, `_lastPreferredHostName` и connectedServerName
        // живут только в памяти. Возвращаем их из сохранённого состояния
        // (_persistSessionRoute), иначе на живом туннеле не работают ни "Сменить
        // сервер", ни Kill Switch.
        if (_lastConnectionString == null &&
            _persistedConnectionString != null) {
          _lastConnectionString = _persistedConnectionString;
          _lastPreferredHostName = _persistedPreferredHost;
        }
        if (connectedServerName.value == null &&
            _persistedServerName != null) {
          connectedServerName.value = _persistedServerName;
        }
      } else {
        // Туннель по данным нативной стороны не поднят — сбрасываем отметку
        // времени в памяти.
        //
        // На диске её здесь стирать нельзя. При холодном старте плагин далеко не
        // всегда успевает привязаться к работающему foreground VpnService к моменту
        // getServiceState() и честно отвечает "не подключено", хотя туннель в фоне
        // живёт и трафик по нему идёт. Стерев сохранённое время, мы к моменту
        // настоящего "connected" через долю секунды остались бы ни с чем. То же
        // самое при каждом возврате приложения из фона.
        //
        // Стирать с диска имеет право только подтверждённое 'disconnected' в
        // _applyServiceState() и явный disconnect().
        _connectStartedAt = null;
      }
      _restoringConnectStartedAt = false;
      _applyServiceState(actualState);
      // Состояние туннеля уже прочитано и опубликовано — именно это `synced` и
      // означает для вызывающего кода. Счётчики трафика ниже — только цифры на
      // экране, их неудача не должна блокировать автоподключение.
      synced = true;
      if (actuallyConnected) {
        try {
          _applyTrafficStats(
              await _client.getTrafficStats().timeout(_nativeCallTimeout));
        } catch (_) {
          // Счётчики подтянутся сами при следующем тике trafficStatsStream
          // или нативного поллинга (_pollNativeTraffic).
        }
      }
    } catch (e) {
      lastError.value = 'Не удалось обновить состояние VPN: $e';
    } finally {
      // Флаг взводится в finally, гарантированно один раз при первой попытке
      // синхронизации. Внутри try он оставался бы false навсегда, если бы любой
      // из трёх await бросил исключение (платформенный канал не готов в первые
      // доли секунды после холодного старта — обычная ситуация), а это
      // единственный флаг, разрешающий _applyServiceState() писать
      // tunnelConnectedAtMillis в LocalPrefs: таймер считался бы в памяти верно,
      // но на диск не попадал, и следующий запуск снова начинал с нуля.
      _runtimeStateSynced = true;
      _restoringConnectStartedAt = false;
    }
    return synced;
  }

  TunnelConnState _mapServiceState(dynamic state) {
    final s = state.toString().toLowerCase();
    if (s.contains('connecting') || s.contains('starting'))
      return TunnelConnState.connecting;
    if (s.contains('disconnecting') || s.contains('stopping'))
      return TunnelConnState.disconnecting;
    if (s.contains('connected') ||
        s.contains('started') ||
        s.contains('running')) return TunnelConnState.connected;
    return TunnelConnState.disconnected;
  }

  /// Держит секундный тик, пока туннель connected, чтобы таймер сессии
  /// считал реальное время, а не ждал редких событий плагина. Безопасно
  /// вызывать многократно — старый таймер всегда гасится перед новым.
  void _restartDurationTicker(bool shouldRun) {
    _durationTicker?.cancel();
    _durationTicker = null;
    _restartLatencyProbe(shouldRun);
    if (!shouldRun) {
      _lastNativeRxBytes = null;
      _lastNativeTxBytes = null;
      _lastNativeStatsAt = null;
      return;
    }
    if (Platform.isAndroid) unawaited(_pollNativeTraffic());
    var ticksSincePersist = 0;
    _durationTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final current = status.value;
      if (current == null || current.state != TunnelConnState.connected) return;
      // Раз в минуту переписываем момент старта на диск, пока туннель поднят.
      // Основная запись происходит один раз при подключении, и если она не
      // доехала до диска (процесс убили в ту же секунду, значение позже стёрли),
      // чинить это было бы уже нечем. Значение при этом не меняется — пишется
      // тот же `_connectStartedAt`.
      ticksSincePersist++;
      if (ticksSincePersist >= 60) {
        ticksSincePersist = 0;
        final startedAt = _connectStartedAt;
        if (startedAt != null &&
            startedAt.millisecondsSinceEpoch != _persistedConnectedAtMillis) {
          _persistConnectStart(startedAt);
        }
      }
      status.value = TunnelStatus(
        state: current.state,
        duration: DateTime.now()
            .difference(_connectStartedAt ?? DateTime.now())
            .inSeconds,
        download: current.download,
        upload: current.upload,
        downloadTotalBytes: current.downloadTotalBytes,
        uploadTotalBytes: current.uploadTotalBytes,
      );
      if (Platform.isAndroid) unawaited(_pollNativeTraffic());
    });
  }

  /// Android продолжает учитывать байты VPN на UID приложения даже тогда,
  /// когда Flutter Activity была выгружена, а foreground VpnService остался
  /// работать. Это надёжный fallback для бага плагина, у которого после
  /// восстановления процесса больше не возобновлялся trafficStatsStream.
  Future<void> _pollNativeTraffic() async {
    if (_nativeStatsPolling || !isConnected) return;
    _nativeStatsPolling = true;
    try {
      final raw = await _nativeStatsChannel
          .invokeMapMethod<String, dynamic>('getUidTraffic');
      final rx = (raw?['rxBytes'] as num?)?.toInt();
      final tx = (raw?['txBytes'] as num?)?.toInt();
      if (rx == null || tx == null) return;

      final now = DateTime.now();
      final elapsedSeconds = _lastNativeStatsAt == null
          ? 0.0
          : now.difference(_lastNativeStatsAt!).inMilliseconds / 1000.0;
      final current = status.value;
      if (current != null &&
          current.state == TunnelConnState.connected &&
          elapsedSeconds > 0 &&
          _lastNativeRxBytes != null &&
          _lastNativeTxBytes != null) {
        final download = ((rx - _lastNativeRxBytes!) / elapsedSeconds)
            .round()
            .clamp(0, 1 << 62);
        final upload = ((tx - _lastNativeTxBytes!) / elapsedSeconds)
            .round()
            .clamp(0, 1 << 62);
        // UID-счётчики Android не включают трафик других приложений при
        // split/full VPN и часто дают одинаковые значения. Не затираем ими
        // уже полученную от sing-box скорость нулями.
        if (download > 0 || upload > 0) {
          status.value = TunnelStatus(
            state: current.state,
            duration: current.duration,
            download: download > 0 ? download : current.download,
            upload: upload > 0 ? upload : current.upload,
            downloadTotalBytes: current.downloadTotalBytes,
            uploadTotalBytes: current.uploadTotalBytes,
          );
        }
      }
      _lastNativeRxBytes = rx;
      _lastNativeTxBytes = tx;
      _lastNativeStatsAt = now;
    } catch (_) {
      // Не-Android платформы и старые сборки нативного слоя продолжают
      // использовать штатный trafficStatsStream выше.
    } finally {
      _nativeStatsPolling = false;
    }
  }

  /// Имя пакета приложения. Спрашиваем у нативной стороны, а не пишем
  /// константой: при появлении applicationIdSuffix для debug- или
  /// flavor-сборок константа станет неверной, а на неверное имя в
  /// addDisallowedApplication Android бросает NameNotFoundException и VPN
  /// просто не поднимется. Константа ниже — запасной вариант на случай
  /// старого APK, собранного до появления "getPackageName" в MainActivity.kt.
  Future<String?> _resolveSelfPackageName() {
    return _selfPackageFuture ??= _resolveSelfPackageNameOnce();
  }

  Future<String?> _resolveSelfPackageNameOnce() async {
    if (!Platform.isAndroid) return null;
    try {
      final name = await _nativeStatsChannel
          .invokeMethod<String>('getPackageName')
          .timeout(_nativeCallTimeout);
      if (name != null && name.isNotEmpty) return name;
    } on MissingPluginException {
      // Старая сборка APK без этого метода канала.
    } on PlatformException {
      // Нативная сторона ответила ошибкой.
    } on TimeoutException {
      // Канал не ответил — не повод задерживать подключение.
    }
    return _fallbackSelfPackage;
  }

  void _onStatusChanged(TunnelConnState state) {
    if (state != TunnelConnState.disconnected) return;
    if (_userInitiatedDisconnect) return;
    // connect() между попытками сам гасит сессию (_settleAfterDisconnect), и
    // каждое гашение приходит сюда обычным "disconnected". Без этой проверки
    // оно считалось бы обрывом: счётчик попыток рос, и через 3 секунды
    // планировался ещё один connect() параллельно тому, который всё ещё
    // перебирал серверы подписки. Две конкурирующие попытки поднять VpnService
    // на одном нативном клиенте дают PlatformException(CONNECT_FAILED) на всех
    // серверах подряд.
    if (_connectInProgress) return;
    if (_lastConnectionString == null) return;
    if (!_killSwitchEnabled) return;
    // При исчерпании попыток авто-переподключения, если включён строгий Kill
    // Switch, поднимаем блокирующую сессию, а не оставляем устройство с
    // незащищённым интернетом.
    if (_autoReconnectAttempt >= _maxAutoReconnectAttempts) {
      if (_strictKillSwitchEnabled) _engageHardKillSwitch();
      return;
    }

    killSwitchBlocking.value = true;
    _autoReconnectAttempt++;
    Future.delayed(Duration(seconds: 3), () async {
      if (_userInitiatedDisconnect) return;
      // За эти 3 секунды подключение могло начаться другим путём (кнопка
      // "Подключить", смена сервера, автоподключение при возврате Wi-Fi).
      if (_connectInProgress) return;
      try {
        await connect(_lastConnectionString!,
            preferredHostName: _lastPreferredHostName);
        killSwitchBlocking.value = false;
        _autoReconnectAttempt = 0;
      } catch (_) {
        // connect() сам исчерпает попытки и снова придёт сюда через
        // _onStatusChanged при следующем disconnected — здесь ничего не делаем,
        // чтобы не задваивать логику.
      }
    });
  }

  /// Строгий Kill Switch: поднимает служебную VPN-сессию с конфигом без
  /// рабочего внешнего outbound'а (route.final = 'block'). Пакеты, которые
  /// иначе улетели бы напрямую в обход упавшего туннеля, отбрасываются на
  /// уровне TUN-интерфейса. Это не настройка ОС, а заглушка вместо реального
  /// туннеля, держащая системный маршрут на себе.
  ///
  /// Снимается, как только пользователь нажмёт "Отключить" или начнётся
  /// новое обычное подключение.
  Future<void> _engageHardKillSwitch() async {
    if (_hardKillSwitchEngaged) return;
    if (_userInitiatedDisconnect) return;
    // Флаг взводится до await, а не после успешного connect():
    // serviceStateStream может прислать промежуточные события самой
    // блокирующей сессии ещё во время выполнения await, а guard в
    // _ensureInitialized проверяет именно его, чтобы состояние служебной сессии
    // не просочилось в публичный status.
    _hardKillSwitchEngaged = true;
    try {
      final blockConfig = _buildBlockAllConfig();
      await _client.checkConfig(blockConfig);
      await _client.connect(SessionOptions(
        config: blockConfig,
        networkMode: NetworkMode.vpn,
        notification: const NotificationConfig(
          title: 'VPNOnline — трафик заблокирован',
          showTrafficStats: false,
          showStopButton: true,
          stopButtonLabel: 'Отключить',
        ),
      ));
      hardKillSwitchActive.value = true;
    } catch (e) {
      // Если даже блокирующую сессию поднять не удалось (например, нет самого
      // VPN-разрешения) — откатываем флаг и оставляем lastError.
      // killSwitchBlocking всё ещё сигнализирует, что защиты сейчас нет.
      _hardKillSwitchEngaged = false;
      lastError.value = 'Не удалось включить строгую блокировку трафика: $e';
    }
  }

  /// Снимает служебную блокирующую сессию (см. _engageHardKillSwitch), если
  /// она сейчас активна. Безопасно вызывать всегда — если сессии нет, ничего
  /// не делает.
  Future<void> _disengageHardKillSwitch() async {
    if (!_hardKillSwitchEngaged) return;
    try {
      await _disconnectNative();
    } catch (_) {}
    // `_hardKillSwitchEngaged` намеренно остаётся true ещё немного после
    // disconnect(): пока он true, guard в листенере игнорирует 'disconnected'
    // от этой блокирующей сессии. Без паузы событие прошло бы как обычный
    // обрыв и запустило цикл авто-переподключения поверх того подключения,
    // которое вызвавший код и так начинает следующим шагом.
    await Future.delayed(const Duration(milliseconds: 250));
    _hardKillSwitchEngaged = false;
    hardKillSwitchActive.value = false;
    _autoReconnectAttempt = 0;
  }

  /// Минимальный конфиг sing-box без внешнего outbound'а: TUN-инбаунд, весь
  /// трафик которого отбрасывается правилом `reject`.
  ///
  /// Блокировка описана через `action`-правила, а не через outbound'ы `block`
  /// и `dns` — те объявлены устаревшими в sing-box 1.11 и удаляются в 1.13,
  /// то есть на более новом ядре строгий Kill Switch просто перестал бы
  /// подниматься. Оба варианта проверены на собранных ядрах: этот принимают
  /// и 1.12, и форк на 1.13, причём без предупреждений.
  String _buildBlockAllConfig() {
    final config = <String, dynamic>{
      'log': {'level': 'warn'},
      'dns': {
        'servers': [
          {'type': 'local', 'tag': 'local-dns'},
        ],
        'final': 'local-dns',
      },
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'interface_name': 'vpnonline-killswitch',
          'mtu': 1500,
          'strict_route': true,
          'stack': 'mixed',
          'auto_route': true,
          'endpoint_independent_nat': true,
          // hijack-dns на Android требует явный IPv4-адрес интерфейса — без
          // него ядро откажется стартовать ("need one more IPv4 address for
          // DNS hijacking"), как и в основном конфиге.
          'address': ['172.19.0.1/28'],
        },
      ],
      // Валидный конфиг обязан содержать хотя бы один outbound: direct нужен
      // как цель `route.final`, но до него ничего не доходит — правило ниже
      // отбрасывает весь трафик TUN-интерфейса.
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'auto_detect_interface': true,
        'final': 'direct',
        'rules': [
          {'protocol': 'dns', 'action': 'hijack-dns'},
          {'inbound': ['tun-in'], 'action': 'reject'},
        ],
      },
    };
    return jsonEncode(config);
  }

  Future<List<String>> listProfileNames(String connectionString) async {
    try {
      final profiles = await _loadProfiles(connectionString);
      return profiles.map((p) => p.remark).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Реальные адреса серверов из подписки: host_name (совпадает с remark в
  /// VLESS-ссылке, см. _matchProfile) -> (host, port, security, sni) — то,
  /// куда пойдёт трафик при подключении к этой локации.
  ///
  /// Нужен для автобалансировки на ServersScreen. Замер до `connect_host`,
  /// который бэкенд вычисляет из домена `subscription_url`, там не годится:
  /// этот домен может быть общим сервисом подписки на все локации сразу, и
  /// тогда все они показывают одинаковый пинг.
  ///
  /// `security` и `sni` отдаются потому, что одного TCP-рукопожатия мало:
  /// открытый порт не означает работающий VLESS-сервис — панель 3x-ui может
  /// быть выключена или инбаунд удалён, а SYN/ACK всё равно придёт. Имея
  /// security и sni, ServersScreen делает поверх TCP настоящее
  /// TLS-рукопожатие для профилей с `security=tls`; для `security=reality`
  /// проверить с клиента нельзя в принципе (см. servers_screen.dart).
  Future<
          Map<String,
              ({String host, int port, String security, String? sni, String transport})>>
      listProfileEndpoints(String connectionString) async {
    try {
      final profiles = await _loadProfiles(connectionString);
      final result = <String,
          ({
            String host,
            int port,
            String security,
            String? sni,
            String transport
          })>{};
      for (final p in profiles) {
        if (p.remark.isEmpty) continue;
        result[p.remark] = (
          host: p.host,
          port: p.port,
          security: p.security,
          sni: p.sni,
          transport: p.transportType ?? 'tcp',
        );
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  void _restartLatencyProbe(bool shouldRun) {
    _latencyProbeTimer?.cancel();
    _latencyProbeTimer = null;
    if (!shouldRun) {
      _latencySamples.clear();
      if (latencyByRemark.value.isNotEmpty) {
        latencyByRemark.value = const <String, int>{};
      }
      return;
    }
    if (_sessionOutboundOrder.isEmpty) return; // старый конфиг без группы
    // Первый прогон с небольшой задержкой: сразу после подключения ядро ещё
    // поднимает соединения, и первое измерение всегда завышено.
    _latencyProbeTimer = Timer(const Duration(seconds: 3), () {
      unawaited(_runLatencyProbe());
      _latencyProbeTimer =
          Timer.periodic(_latencyProbeInterval, (_) => unawaited(_runLatencyProbe()));
    });
  }

  /// Немедленный замер задержки по всем локациям поднятого туннеля.
  ///
  /// Нужен экрану «Серверы»: кнопка «Проверить» при включённом VPN больше не
  /// отказывается работать, а просит ядро прогнать URLTest прямо сейчас —
  /// туннель при этом не рвётся. Ограничение «не мерить под нагрузкой» здесь
  /// снято: пользователь нажал кнопку и ждёт ответа, а не фонового цикла.
  ///
  /// Возвращает то, что получилось: имя локации из подписки -> задержка в мс.
  Future<Map<String, int>> refreshLatencyNow() async {
    if (!isConnected) return const <String, int>{};
    await _runLatencyProbe(force: true);
    return latencyByRemark.value;
  }

  Future<void> _runLatencyProbe({bool force = false}) async {
    if (_latencyProbeRunning || !isConnected) return;
    final current = status.value;
    if (!force &&
        current != null &&
        (current.download > _latencyProbeBusyBps ||
            current.upload > _latencyProbeBusyBps)) {
      return; // идёт трафик — измерим в следующий раз, а не очередь
    }
    _latencyProbeRunning = true;
    try {
      // Два прогона подряд: одиночный замер на мобильной сети сильно скачет,
      // и показывать этот скачок как «пинг» нельзя.
      final raw = await measureLatenciesThroughTunnel();
      final second = await measureLatenciesThroughTunnel();
      for (final entry in second.entries) {
        final known = raw[entry.key];
        if (known == null || entry.value < known) raw[entry.key] = entry.value;
      }

      final smoothed = <String, int>{};
      for (final entry in raw.entries) {
        final samples = _latencySamples.putIfAbsent(entry.key, () => <int>[]);
        samples.add(entry.value);
        if (samples.length > _latencySampleWindow) samples.removeAt(0);
        // Минимум, а не медиана. Так же считает Hiddify: он гоняет несколько
        // проверок по разным адресам и оставляет наименьшее
        // (common/monitoring: `if t < his.Delay { his.Delay = t }` и
        // getMinGroupOutboundHistory). Медиана вбирает в себя случайные
        // задержки радиоканала — отсюда и брались числа вдвое больше, чем в
        // других клиентах на тех же серверах. Минимум — это чистый круговой
        // путь, то есть то, что пользователь и называет пингом.
        smoothed[entry.key] = samples.reduce((a, b) => a < b ? a : b);
      }
      // Локация выпала из прогона — забываем её историю, иначе после
      // возвращения она унаследует устаревшие значения.
      _latencySamples.removeWhere((remark, _) => !raw.containsKey(remark));

      // Запасной вариант: если ядро не отдало задержку ни по одной локации
      // (группы нет — старая сессия, ядро не поддержало urltest), меряем
      // текущий сервер сами. Число будет завышено — свой замер включает
      // рукопожатие, — но лучше так, чем пустой экран.
      final currentName = connectedServerName.value;
      if (smoothed.isEmpty && currentName != null && currentName.isNotEmpty) {
        final warm = await connectedDelayMs();
        if (warm != null && warm > 0) smoothed[currentName] = warm;
      }
      latencyByRemark.value = smoothed;
      // Результат замера в журнал: если ядро не достучалось ни до одной
      // локации, это первое, что стоит увидеть при разборе.
      unawaited(AppLogService.instance.log(
          'Задержка через туннель: '
          '${smoothed.entries.map((e) => '${e.key} — ${e.value} мс').join('; ')}'));
    } finally {
      _latencyProbeRunning = false;
    }
  }

  /// Задержка до адреса сервера без поднятого туннеля: TCP-рукопожатие, а для
  /// профилей с обычным TLS — ещё и TLS поверх него. Настоящее сетевое время
  /// до той машины, куда пойдёт трафик, без всяких пересчётов.
  ///
  /// null — не достучались. Для `security=reality` проверка ограничена TCP:
  /// Reality с клиента не проверить, узел отвечает сертификатом
  /// сайта-приманки в любом состоянии инбаунда.
  static Future<int?> measureEndpointPingMs(
    String host,
    int port, {
    String security = 'none',
    String? sni,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    Socket? socket;
    try {
      final sw = Stopwatch()..start();
      socket = await Socket.connect(host, port, timeout: timeout);
      sw.stop();
      if (security != 'tls') {
        return sw.elapsedMilliseconds;
      }
      final tlsSw = Stopwatch()..start();
      final secure = await SecureSocket.secure(
        socket,
        host: (sni != null && sni.isNotEmpty) ? sni : host,
      ).timeout(timeout);
      tlsSw.stop();
      secure.destroy();
      socket = null;
      return sw.elapsedMilliseconds + tlsSw.elapsedMilliseconds;
    } catch (_) {
      return null;
    } finally {
      socket?.destroy();
    }
  }

  /// Задержка до локации по её имени с экрана (host_name из /hosts).
  /// Ключи `latencyByRemark` — remark'и подписки ("VPNonLine | 🇩🇪 Германия —
  /// Франкфурт"), имена на экране идут без префикса сервиса; сопоставляем по
  /// вхождению, как и _matchProfile. Один метод на оба экрана, чтобы они не
  /// разошлись в логике сопоставления.
  int? latencyForHostName(String? hostName) {
    if (hostName == null || hostName.isEmpty) return null;
    final needle = hostName.toLowerCase().trim();
    for (final entry in latencyByRemark.value.entries) {
      final remark = entry.key.toLowerCase();
      if (remark == needle || remark.contains(needle) || needle.contains(remark)) {
        return entry.value;
      }
    }
    return null;
  }

  /// Замер задержки при поднятом туннеле — самый верный из трёх способов,
  /// что есть в приложении.
  ///
  /// Чем он отличается от остальных:
  ///  * TCP-стук (servers_screen::_measureLivePing) бьётся в порт напрямую.
  ///    До Reality-узла он всегда успешен — тот отвечает сертификатом
  ///    сайта-приманки даже со сломанным инбаундом;
  ///  * realCheckProfile поднимает и гасит тестовую сессию своим же ядром —
  ///    верно, но требует выключенного VPN, потому что ядро одно;
  ///  * здесь мы просим уже работающее ядро прогнать проверку по всем
  ///    outbound'ам группы `proxy` — той самой, что кладётся в конфиг ради
  ///    бесшовного переключения. Рукопожатие настоящее, туннель не
  ///    прерывается.
  ///
  /// Возвращает имя локации -> задержка в мс. Локации, до которых ядро не
  /// достучалось, в результат не попадают — так вызывающий отличит
  /// "не работает" от "ещё не измерено".
  ///
  /// Пустой результат означает, что замер невозможен: туннель не поднят,
  /// сессия собрана без группы или платформа не Android.
  Future<Map<String, int>> measureLatenciesThroughTunnel({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final order = _sessionOutboundOrder;
    if (order.isEmpty || !isConnected) return const <String, int>{};
    return _collectGroupDelays(order, timeout: timeout);
  }

  /// Сам сбор задержек по группе `latency`: просит ядро прогнать URLTest и
  /// слушает, что оно отдаёт по каждому участнику.
  ///
  /// Вынесено отдельно от [measureLatenciesThroughTunnel], потому что тем же
  /// кодом меряется и временная сессия «Реальной проверки», где боевого
  /// туннеля нет и `_sessionOutboundOrder` ещё не заполнен — порядок
  /// outbound'ов там передаётся снаружи.
  Future<Map<String, int>> _collectGroupDelays(
    List<_ParsedVless> order, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (order.isEmpty) return const <String, int>{};

    final completer = Completer<Map<String, int>>();
    StreamSubscription<dynamic>? sub;
    Timer? deadline;
    final collected = <String, int>{};

    void finish() {
      if (completer.isCompleted) return;
      completer.complete(Map<String, int>.from(collected));
    }

    try {
      sub = _client.outboundGroupStream.listen((groups) {
        if (groups is! List) return;
        for (final group in groups) {
          // Нас интересует только наша группа, а не любые другие, которые
          // ядро может отдавать.
          if (_groupTagOf(group) != _latencyGroupTag) continue;
          final items = _groupItemsOf(group);
          for (final item in items) {
            final tag = _groupTagOf(item);
            final delay = _itemDelayOf(item);
            // Ноль у sing-box означает "не измерено", а 65535 (0xFFFF) —
            // "проверка не прошла": именно это число libbox отдаёт за
            // недоступный outbound. Показанное как есть, оно превращалось на
            // экране в "65535 мс · медленно" у полностью мёртвого сервера.
            if (tag == null || delay == null || delay <= 0) continue;
            if (delay >= _urlTestFailedDelayMs) continue;
            final index = _indexOfOutboundTag(tag);
            if (index == null || index >= order.length) continue;
            // Ключ — remark из VLESS-ссылки ("VPNonLine | 🇩🇪 Германия — Франкфурт").
            // Он не совпадает с host_name из /hosts ("🇩🇪 Германия — Франкфурт"):
            // панель 3x-ui дописывает в remark название сервиса. Сопоставление имён —
            // забота вызывающего, здесь отдаём как есть.
            final remark = order[index].remark;
            if (remark.isEmpty) continue;
            // Это честный URLTest ядра: время полного запроса к
            // http://cp.cloudflare.com/ через VLESS — ровно то же число, что
            // показывает Hiddify.
            collected[remark] = delay;
          }
          // Все участники ответили — ждать дальше нечего.
          if (collected.length >= order.length) finish();
        }
      }, onError: (_) => finish());

      deadline = Timer(timeout, finish);
      await _client.urlTest(_latencyGroupTag).timeout(_nativeCallTimeout);
      return await completer.future;
    } catch (e) {
      lastError.value = 'Не удалось измерить задержку через туннель: $e';
      return Map<String, int>.from(collected);
    } finally {
      deadline?.cancel();
      await sub?.cancel();
    }
  }

  /// Задержка одного участника группы `latency` по версии самого ядра.
  /// Используется «Реальной проверкой», где сессия поднята временно и
  /// [measureLatenciesThroughTunnel] неприменим: там ещё нет ни
  /// `_sessionOutboundOrder`, ни статуса «подключено».
  Future<int?> _measureGroupDelayMs(
      {Duration timeout = const Duration(seconds: 10)}) async {
    final completer = Completer<int?>();
    StreamSubscription<dynamic>? sub;
    Timer? deadline;
    void finish(int? value) {
      if (!completer.isCompleted) completer.complete(value);
    }

    try {
      sub = _client.outboundGroupStream.listen((groups) {
        if (groups is! List) return;
        for (final group in groups) {
          if (_groupTagOf(group) != _latencyGroupTag) continue;
          for (final item in _groupItemsOf(group)) {
            final delay = _itemDelayOf(item);
            if (delay == null || delay <= 0) continue;
            if (delay >= _urlTestFailedDelayMs) continue;
            finish(delay);
            return;
          }
        }
      }, onError: (_) => finish(null));
      deadline = Timer(timeout, () => finish(null));
      await _client.urlTest(_latencyGroupTag).timeout(_nativeCallTimeout);
      return await completer.future;
    } catch (_) {
      return null;
    } finally {
      deadline?.cancel();
      await sub?.cancel();
    }
  }

  /// Разбор ответа плагина сделан через dynamic: поток отдаёт
  /// `List<OutboundGroup>` из пакета, но через платформенную абстракцию
  /// (singbox_runtime.dart) он приходит как dynamic, и завязываться здесь на
  /// конкретный класс пакета нельзя — иначе Windows-реализация перестанет
  /// компилироваться.
  String? _groupTagOf(dynamic value) {
    try {
      final tag = value.tag;
      return tag is String && tag.isNotEmpty ? tag : null;
    } catch (_) {
      return null;
    }
  }

  List<dynamic> _groupItemsOf(dynamic value) {
    try {
      final items = value.items;
      return items is List ? items : const <dynamic>[];
    } catch (_) {
      return const <dynamic>[];
    }
  }

  int? _itemDelayOf(dynamic value) {
    try {
      final delay = value.urlTestDelayMs;
      return delay is int ? delay : null;
    } catch (_) {
      return null;
    }
  }

  /// 'out-3' -> 3. Когда локация в подписке одна, группы-селектора нет и
  /// единственный outbound называется 'proxy' — это нулевой участник.
  int? _indexOfOutboundTag(String tag) {
    if (tag == 'proxy') return 0;
    if (!tag.startsWith('out-')) return null;
    return int.tryParse(tag.substring(4));
  }

  /// Смена страны у уже поднятого туннеля.
  ///
  /// Если сессия собрана с группой-селектором, переключение идёт внутри
  /// работающего ядра и туннель не прерывается. Иначе это разрыв и новое
  /// подключение: две сессии ядра одновременно flutter_singbox_client не
  /// держит. Но всё, что пользователь видел как "меня отключили", убрано:
  ///
  ///  * счётчик времени сессии не прыгает на 00:00:00;
  ///  * счётчики принято/отдано не обнуляются;
  ///  * вместо "ОТКЛЮЧЕНО" с кнопкой "Подключить" показывается
  ///    "подключение" (см. _applyServiceState);
  ///  * строка подписки и предпочтение не стираются в disconnect(), так что
  ///    Kill Switch всё это время остаётся с данными для переподключения.
  ///
  /// При неудаче нового сервера возвращаемся на ту страну, где всё работало,
  /// и только потом сообщаем об ошибке: иначе пользователь оставался бы без
  /// VPN — старая сессия погашена, новая не поднялась.
  Future<String> switchPreferredHost(String hostName) async {
    final connectionString = _lastConnectionString;
    if (connectionString == null || connectionString.isEmpty) {
      throw TunnelException(
          'Нет активного туннеля, который можно переключить.');
    }
    // Если текущая сессия поднята с группой-селектором и нужная локация лежит
    // в ней отдельным outbound'ом, просто просим ядро переключить активный
    // outbound внутри группы. TUN остаётся поднятым, сервис не
    // перезапускается, уведомление не моргает, уже открытые соединения
    // доживают на прежнем сервере (`interrupt_exist_connections: false`).
    final order = _sessionOutboundOrder;
    if (order.isNotEmpty && isConnected) {
      final target = _matchProfile(order, hostName);
      if (target != null) {
        final index = order.indexWhere((e) => identical(e, target));
        if (index >= 0) {
          try {
            await _client
                .selectOutbound('proxy', 'out-$index')
                .timeout(_nativeCallTimeout);
            _lastPreferredHostName = hostName;
            connectedServerName.value = hostName;
            _persistSessionRoute();
            return hostName;
          } catch (e) {
            // Мгновенное переключение не удалось (ядро не ответило, группы в этой
            // сессии нет) — не считаем это отказом всей операции, уходим ниже на
            // обычный путь с разрывом.
            lastError.value = null;
          }
        }
      }
    }

    final previousHostName = _lastPreferredHostName;
    _switchInProgress = true;
    try {
      await disconnect();
      return await connect(connectionString, preferredHostName: hostName);
    } catch (_) {
      // Новая страна не поднялась — возвращаем ту, на которой пользователь
      // только что сидел, чтобы он не остался в открытой сети.
      try {
        await connect(connectionString, preferredHostName: previousHostName);
      } catch (_) {
        // Не поднялась и прежняя: сеть могла отвалиться целиком. Сообщаем исходную
        // ошибку вызывающему, дальше в дело вступает обычное авто-переподключение
        // (_onStatusChanged), ради которого мы и сохранили _lastConnectionString
        // выше.
        //
        // Чтобы оно сработало, снимаем флаг "пользователь сам отключился": его
        // выставил наш же disconnect() в начале переключения, а connect() снимает
        // его только при успехе. Пользователь ничего не отключал — он остался без
        // VPN из-за неудачной смены сервера, и это ровно тот случай, ради которого
        // Kill Switch существует.
        _userInitiatedDisconnect = false;
      }
      rethrow;
    } finally {
      _switchInProgress = false;
    }
  }

  // Транспорты, которые умеет ядро sing-box внутри flutter_singbox_client.
  // XHTTP (в старых панелях splithttp) сюда не входит: это транспорт
  // Xray-core, sing-box его не реализует, и конфиг с таким блоком ядро
  // отвергает на checkConfig целиком — вместе со всеми остальными локациями
  // подписки, попавшими в тот же конфиг.
  static const _supportedTransports = <String>{
    'tcp',
    'ws',
    'grpc',
    'http',
    'httpupgrade',
    'quic',
  };

  /// Приводит написание транспорта к одному виду:
  ///  - `splithttp` — прежнее имя XHTTP, встречается в старых панелях;
  ///  - `raw` — как называет голый TCP новый Xray, в sing-box это `tcp`;
  ///  - `h2` — прежнее имя HTTP/2-транспорта, в sing-box это `http`.
  static String _normalizeTransportType(String raw) {
    final type = raw.trim().toLowerCase();
    switch (type) {
      case '':
      case 'raw':
      case 'none':
        return 'tcp';
      case 'splithttp':
        return 'xhttp';
      case 'h2':
        return 'http';
      default:
        return type;
    }
  }

  /// ALPN для TLS-блока. Транспорт диктует его жёстче, чем ссылка: ws и
  /// httpupgrade работают поверх HTTP/1.1, gRPC — поверх HTTP/2, QUIC — поверх
  /// HTTP/3. Панели этот параметр в ссылке часто не проставляют вовсе или
  /// проставляют неверно, и сервер отвечает отказом на ALPN, которого не ждёт.
  /// Порядок и состав повторяют ray2sing (hiddify): для HTTP-подобных
  /// транспортов отдаём обе версии, чтобы сервер выбрал сам.
  static List<String>? _alpnForTransport(String? transportType, String? alpn) {
    switch (transportType) {
      case 'ws':
      case 'httpupgrade':
      case 'grpc':
      case 'http':
        return const ['h2', 'http/1.1'];
      case 'quic':
        return const ['h3'];
    }
    if (alpn == null || alpn.trim().isEmpty) return null;
    final parts = alpn
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return parts.isEmpty ? null : parts;
  }

  /// Разбирает адрес DNS-сервера в поля sing-box. Принимает и голый IP
  /// (`1.1.1.1` — обычный UDP), и адрес со схемой (`https://dns.google/dns-query`,
  /// `tls://1.1.1.1`). Так же это делает Hiddify (hiddify-core: getDnsAddress).
  static Map<String, dynamic> _dnsServerOptions(String address) {
    final raw = address.trim();
    if (!raw.contains('://')) {
      return {'type': 'udp', 'server': raw};
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) {
      return {'type': 'udp', 'server': raw};
    }
    final scheme = uri.scheme.toLowerCase();
    const known = {'udp', 'tcp', 'tls', 'https', 'quic', 'h3'};
    return {
      'type': known.contains(scheme) ? scheme : 'udp',
      'server': uri.host,
      if (uri.hasPort) 'server_port': uri.port,
      if ((scheme == 'https' || scheme == 'h3') && uri.path.isNotEmpty)
        'path': uri.path,
    };
  }

  /// Отделяет параметр `ed` (ранние данные, 0-RTT) от пути ws/httpupgrade.
  /// Xray передаёт его внутри пути, sing-box ждёт отдельным полем.
  static _WsPath _splitEarlyData(String? rawPath) {
    var path = (rawPath == null || rawPath.isEmpty) ? '/' : rawPath;
    if (!path.startsWith('/')) path = '/$path';
    final q = path.indexOf('?');
    if (q < 0) return _WsPath(path, 0);
    final query = Uri.splitQueryString(path.substring(q + 1));
    final ed = int.tryParse(query['ed'] ?? '') ?? 0;
    if (ed <= 0) return _WsPath(path, 0);
    final rest = Map<String, String>.from(query)..remove('ed');
    final base = path.substring(0, q);
    final tail = rest.isEmpty
        ? ''
        : '?${rest.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&')}';
    return _WsPath('$base$tail', ed);
  }

  static bool _isTransportSupported(_ParsedVless p) {
    final type = (p.transportType ?? 'tcp').trim().toLowerCase();
    return type.isEmpty || _supportedTransports.contains(type);
  }

  // Что ядро умеет сверх базового списка, спрашиваем у него самого: отдаём на
  // checkConfig минимальный конфиг с нужным транспортом — ядро разбирает
  // схему, ничего не запуская. Так одна и та же сборка приложения работает и
  // со штатным ядром (XHTTP отсеивается, как и раньше), и с ядром на форке
  // hiddify-sing-box (XHTTP используется), без флагов сборки и версий в коде.
  final Map<String, bool> _transportSupport = {};
  bool? _probeConfigUsable;

  /// Умеет ли установленное ядро транспорт [type]. Результат кэшируется на
  /// время жизни процесса: ядро внутри одной сессии не меняется.
  Future<bool> _coreSupportsTransport(String type) async {
    final normalized = _normalizeTransportType(type);
    if (_supportedTransports.contains(normalized)) return true;
    final cached = _transportSupport[normalized];
    if (cached != null) return cached;

    try {
      await _ensureInitialized();
      // Контрольный прогон: убеждаемся, что сама форма пробного конфига ядру
      // нравится. Иначе отказ по постороннему поводу (не та схема, не тот
      // набор обязательных полей) мы приняли бы за "транспорт не поддержан".
      _probeConfigUsable ??= await _checkProbeConfig('ws');
      if (_probeConfigUsable != true) {
        _transportSupport[normalized] = false;
        return false;
      }
      final supported = await _checkProbeConfig(normalized);
      _transportSupport[normalized] = supported;
      return supported;
    } catch (_) {
      // Ядро не ответило — не выдаём желаемое за действительное: считаем, что
      // транспорта нет, и профиль просто не попадёт в конфиг.
      _transportSupport[normalized] = false;
      return false;
    }
  }

  /// Умеет ли ядро фрагментировать собственное TLS-рукопожатие к серверу
  /// (`tls_fragment` на диалере outbound'а). Это есть в форке
  /// hiddify-sing-box и нет в апстриме, поэтому спрашиваем у ядра так же, как
  /// про транспорты, — пробным конфигом.
  bool? _tlsFragmentSupport;

  Future<bool> _coreSupportsTlsFragment() async {
    final cached = _tlsFragmentSupport;
    if (cached != null) return cached;
    try {
      await _ensureInitialized();
      final supported = await _checkConfigQuietly(jsonEncode({
        'log': {'level': 'error'},
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'probe',
            'server': '127.0.0.1',
            'server_port': 443,
            'uuid': '00000000-0000-0000-0000-000000000000',
            'tls_fragment': _tlsFragmentOptions,
          }
        ],
      }));
      _tlsFragmentSupport = supported;
      return supported;
    } catch (_) {
      _tlsFragmentSupport = false;
      return false;
    }
  }

  /// Умеет ли ядро «единую задержку» (`experimental.unified_delay`).
  ///
  /// Это главное, чем ping Hiddify отличается от нашего на тех же серверах.
  /// Обычный URLTest в sing-box меряет всё сразу: дозвон до сервера,
  /// VLESS/Reality-рукопожатие и только потом HTTP-запрос — три-четыре
  /// круговых пути, отсюда и 200-400 мс. С unified_delay ядро после первого
  /// запроса делает по уже установленному соединению второй и возвращает
  /// время именно второго (см. common/urltest: `if IsUnifiedDelayFromContext`)
  /// — то есть один чистый круговой путь, те самые 40-80 мс.
  ///
  /// Опция есть в форке hiddify-sing-box и отсутствует в апстриме, поэтому
  /// спрашиваем ядро пробным конфигом — как про транспорты и tls_fragment.
  bool? _unifiedDelaySupport;

  Future<bool> _coreSupportsUnifiedDelay() async {
    final cached = _unifiedDelaySupport;
    if (cached != null) return cached;
    try {
      await _ensureInitialized();
      final supported = await _checkConfigQuietly(jsonEncode({
        'log': {'level': 'error'},
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'}
        ],
        'experimental': {
          'unified_delay': {'enabled': true},
        },
      }));
      _unifiedDelaySupport = supported;
      return supported;
    } catch (_) {
      _unifiedDelaySupport = false;
      return false;
    }
  }

  /// Параметры фрагментации — те же, что по умолчанию у Hiddify: рвать
  /// ClientHello на куски по 10-100 байт с паузой 50-200 мс между ними.
  /// Именно ClientHello видит DPI, когда решает, пропускать ли соединение.
  static const Map<String, dynamic> _tlsFragmentOptions = {
    'enabled': true,
    'size': '10-100',
    'sleep': '50-200',
    'method': 'tlsHello',
  };

  Future<bool> _checkConfigQuietly(String config) async {
    try {
      await _client.checkConfig(config).timeout(_nativeCallTimeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _checkProbeConfig(String type) async {
    try {
      await _client
          .checkConfig(_buildTransportProbeConfig(type))
          .timeout(_nativeCallTimeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Минимальный конфиг ровно с одним vless-outbound'ом нужного транспорта:
  /// ни tun-инбаунда, ни DNS, ни маршрутов — чтобы отказ мог означать только
  /// одно, неизвестный транспорт.
  String _buildTransportProbeConfig(String type) {
    return jsonEncode({
      'log': {'level': 'error'},
      'outbounds': [
        {
          'type': 'vless',
          'tag': 'probe',
          'server': '127.0.0.1',
          'server_port': 443,
          'uuid': '00000000-0000-0000-0000-000000000000',
          'transport': {
            'type': type,
            'path': '/',
            // XHTTP требует mode даже на проверке конфига: без него ядро с
            // поддержкой транспорта ответит "xhttp: mode is not set", и мы
            // ошибочно решили бы, что транспорта нет.
            if (type == 'xhttp') 'mode': 'auto',
          },
        },
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'probe'},
    });
  }

  /// Пройдёт ли профиль в конфиг: базовый список транспортов плюс то, что
  /// ядро подтвердило само (см. [_coreSupportsTransport]).
  Future<bool> _isProfileSupported(_ParsedVless p) async {
    if (_isTransportSupported(p)) return true;
    final type = (p.transportType ?? '').trim();
    if (type.isEmpty) return true;
    return _coreSupportsTransport(type);
  }

  _ParsedVless? _matchProfile(List<_ParsedVless> profiles, String? hostName) {
    if (hostName == null || hostName.isEmpty) return null;
    final needle = hostName.trim().toLowerCase();
    for (final p in profiles) {
      if (p.remark.trim().toLowerCase() == needle) return p;
    }
    for (final p in profiles) {
      final remark = p.remark.trim().toLowerCase();
      if (remark.isEmpty) continue;
      if (remark.contains(needle) || needle.contains(remark)) return p;
    }
    return null;
  }

  /// Публичная обёртка над `_connectInternal`: не даёт двум подключениям
  /// выполняться одновременно. ConnectScreen блокирует свою кнопку флагом
  /// `_connecting`, но цикл авто-переподключения Kill Switch
  /// (`_onStatusChanged`) и автобалансировка (`switchPreferredHost`) зовут
  /// connect() мимо любого UI-флага.
  Future<String> connect(String connectionString,
      {String? preferredHostName}) async {
    if (_connectInProgress) {
      throw TunnelException(
          'Подключение уже выполняется — дождись его завершения.');
    }
    _connectInProgress = true;
    try {
      return await _connectInternal(connectionString,
          preferredHostName: preferredHostName);
    } finally {
      _connectInProgress = false;
    }
  }

  Future<String> _connectInternal(String connectionString,
      {String? preferredHostName}) async {
    lastError.value = null;
    await _ensureInitialized();
    // На Android 13+ одного объявления POST_NOTIFICATIONS в манифесте
    // недостаточно: пока пользователь не подтвердит runtime-разрешение,
    // foreground VPN продолжает работать, но его карточка скрыта в шторке.
    // Запрашиваем его до старта VpnService, чтобы первое подключение уже
    // показало постоянное уведомление с кнопкой отключения.
    if (Platform.isAndroid) {
      try {
        final notificationsAllowed = await _nativeStatsChannel
                .invokeMethod<bool>('requestNotificationPermission') ??
            false;
        if (!notificationsAllowed) {
          lastError.value =
              'Разрешите уведомления, чтобы видеть статус VPN в шторке.';
        }
      } on PlatformException {
        // Не прерываем VPN на старых сборках/устройствах: разрешение влияет
        // только на видимость уведомления, а не на безопасность туннеля.
      } on MissingPluginException {
        // MissingPluginException не наследуется от PlatformException, поэтому
        // ловится отдельно. Он прилетает, когда нативная сторона канала
        // 'vpnonline/native_stats' не знает метод requestNotificationPermission —
        // обычно на APK, собранном до его появления в MainActivity.kt. Рвать из-за
        // этого VPN нельзя: разрешение влияет только на видимость уведомления.
      }
    }
    // Обычное подключение может получить событие connected раньше, чем
    // ConnectScreen вызовет syncRuntimeState(), поэтому с этого момента
    // разрешаем сохранить время старта сессии.
    _runtimeStateSynced = true;
    // Явное начало новой сессии: обнуляем и отметку в памяти, и сохранённую на
    // диске, иначе восстановление в _applyServiceState() подставит сюда время
    // старта предыдущей сессии. При смене сервера у работающего туннеля
    // ничего этого не делаем: для пользователя сессия не прерывалась, и
    // обнулять её часы и накопленный трафик значило бы показать разрыв там,
    // где его нет.
    if (!_switchInProgress) {
      _connectStartedAt = null;
      _cancelPersistedStartWipe();
      _persistConnectStart(null);
      _downloadTotalBytes = 0;
      _uploadTotalBytes = 0;
      _displayDownloadBytes = 0;
      _displayUploadBytes = 0;
    }
    _lastTrafficAt = null;
    _lastNativeRxBytes = null;
    _lastNativeTxBytes = null;
    _lastNativeStatsAt = null;

    // Fallback'и совпадают со стартовыми значениями полей на экранах
    // "Безопасность" и "Настройки", чтобы поведение туннеля не расходилось с
    // тем, что видит пользователь.
    final dnsProtection = await LocalPrefs.instance
        .getBool(PrefKeys.dnsProtection, fallback: true);
    final blockAds =
        await LocalPrefs.instance.getBool(PrefKeys.blockAds, fallback: true);
    final dpiBypass =
        await LocalPrefs.instance.getBool(PrefKeys.dpiBypass, fallback: false);
    final proxyOnly = await LocalPrefs.instance
        .getBool(PrefKeys.proxyOnlyMode, fallback: false);
    final dnsProvider =
        await LocalPrefs.instance.getString(PrefKeys.dnsServerProvider) ??
            'cloudflare';
    final customDns =
        await LocalPrefs.instance.getString(PrefKeys.customDnsServer);
    _killSwitchEnabled = await LocalPrefs.instance
        .getBool(PrefKeys.killSwitch, fallback: false);
    // Строгий Kill Switch читается заранее, чтобы _onStatusChanged знал, нужно
    // ли поднимать блокирующую сессию, когда обычное переподключение исчерпает
    // попытки.
    _strictKillSwitchEnabled = await LocalPrefs.instance
        .getBool(PrefKeys.strictKillSwitch, fallback: false);
    // Fallback 3 — столько же, сколько даёт выключенное "Агрессивное
    // переподключение" на экране "Безопасность".
    _maxAutoReconnectAttempts = await LocalPrefs.instance
        .getInt(PrefKeys.reconnectAttempts, fallback: 3);
    final bypassedMap =
        await LocalPrefs.instance.getBoolMap(PrefKeys.splitTunnelBypass);
    final splitTunnelMode =
        await LocalPrefs.instance.getString(PrefKeys.splitTunnelMode) ??
            'exclude';
    final selectedPackages =
        bypassedMap.entries.where((e) => e.value).map((e) => e.key).toList();
    final bypassLan =
        await LocalPrefs.instance.getBool(PrefKeys.bypassLan, fallback: false);
    final muxEnabled = await LocalPrefs.instance
        .getBool(PrefKeys.muxEnabled, fallback: false);
    final muxProtocol =
        await LocalPrefs.instance.getString(PrefKeys.muxProtocol) ?? 'h2mux';
    final fakeIpDns =
        await LocalPrefs.instance.getBool(PrefKeys.fakeIpDns, fallback: false);
    final ipv6Enabled = await LocalPrefs.instance
        .getBool(PrefKeys.ipv6Enabled, fallback: false);
    // Спрашиваем у ядра один раз за запуск: умеет ли оно рвать собственное
    // рукопожатие. На штатном ядре — нет, и «Обход DPI» остаётся прежним
    // правилом маршрутизации.
    final tlsFragmentSupported =
        dpiBypass ? await _coreSupportsTlsFragment() : false;
    // Спрашиваем тем же способом: умеет ли ядро «единую задержку». От ответа
    // зависит только то, какое число пользователь увидит как пинг, — на сам
    // туннель опция не влияет.
    final unifiedDelaySupported = await _coreSupportsUnifiedDelay();
    // См. PrefKeys.excludeAppFromTunnel. При fallback false список исключений
    // ниже остаётся пустым и конфиг собирается ровно такой же, как без этой
    // настройки.
    final excludeAppFromTunnel = await LocalPrefs.instance
        .getBool(PrefKeys.excludeAppFromTunnel, fallback: true);
    // Имя пакета нужно только в VPN-режиме и только в режиме исключений: при
    // splitTunnelMode == 'include' через туннель идут лишь явно выбранные
    // приложения, и нашего среди них нет.
    final String? selfPackage =
        (!proxyOnly && excludeAppFromTunnel && splitTunnelMode != 'include')
            ? await _resolveSelfPackageName()
            : null;
    // Set, а не List: если пользователь сам отметил наше приложение на экране
    // исключений, дубликат в exclude_package не нужен.
    final excludedPackages = <String>{
      if (splitTunnelMode != 'include') ...selectedPackages,
      if (selfPackage != null) selfPackage,
    }.toList();

    // Служебную блокирующую сессию Kill Switch нужно снять перед обычным
    // подключением — иначе новая сессия конкурирует с ней за системный TUN.
    await _disengageHardKillSwitch();

    // Системное разрешение на VPN обязано быть запрошено до connect() в
    // VPN-режиме (`if (!await client.requestVPNPermission()) return;` по README
    // пакета). Без этого Android получает несогласованный с пользователем
    // VpnService.prepare() и падает нативно, минуя Dart try/catch целиком — со
    // стороны это выглядит как вылет приложения без единого сообщения. В
    // proxy-only режиме системного интерфейса нет и диалог не нужен.
    if (!proxyOnly) {
      final granted = await _client.requestVPNPermission();
      if (!granted) {
        throw TunnelException(
          'Нужно разрешение на VPN-подключение — без него Android не даст поднять туннель. '
          'Нажми "Подключить" ещё раз и разреши в системном диалоге.',
        );
      }
      // Системный диалог VPN-разрешения открывается отдельной Activity поверх
      // нашей, и requestVPNPermission() возвращает true в момент
      // onActivityResult — до того, как наша Activity вернулась в RESUMED и
      // система зафиксировала разрешение у себя. Запуск VpnService сразу в этот
      // момент иногда падает с CONNECT_FAILED. Короткая пауза даёт Activity
      // долистать жизненный цикл.
      await Future.delayed(const Duration(milliseconds: 350));
    }

    final profiles = await _loadProfiles(connectionString);
    final preferred = _matchProfile(profiles, preferredHostName);
    final ordered = preferred != null
        ? [preferred, ...profiles.where((p) => !identical(p, preferred))]
        : profiles;

    // Локация с транспортом, которого ядро не знает, портит не только себя:
    // конфиг проверяется целиком, поэтому одна такая запись в подписке
    // отправила бы в отказ и группу-селектор со всеми остальными серверами
    // (см. _isTransportSupported). Отсеиваем её до сборки конфига.
    final usable = <_ParsedVless>[];
    for (final profile in ordered) {
      if (await _isProfileSupported(profile)) usable.add(profile);
    }
    final skippedCount = ordered.length - usable.length;
    // Состав подписки — в журнал. Без этого при разборе «не работает» неясно
    // главное: какие транспорты раздаёт панель, что из этого ядро умеет и к
    // чему приложение в итоге подключается.
    unawaited(AppLogService.instance.log(
        'Подписка: ${ordered.length} локаций '
        '[${ordered.map((p) => '${p.remark.isEmpty ? p.host : p.remark}:'
            '${p.transportType ?? 'tcp'}/${p.security}').join(', ')}]'
        '${skippedCount > 0 ? '; пропущено ядром: $skippedCount' : ''}'));
    if (usable.isEmpty) {
      throw TunnelException(
        'В подписке нет серверов с транспортом, который поддерживает ядро: '
        'все ${ordered.length} используют XHTTP или другой неизвестный ядру '
        'транспорт. Чтобы такие ключи заработали, нужно ядро с их поддержкой '
        '(см. app/XHTTP_CORE.md) или инбаунд на панели с ws/httpupgrade.',
      );
    }

    Object? lastFailure;
    for (final profile in usable) {
      try {
        // Остальные локации подписки идут в тот же конфиг отдельными outbound'ами
        // под группой-селектором — это и позволяет менять страну без разрыва (см.
        // построение `outbounds` в _buildSingBoxConfig и switchPreferredHost).
        // Порядок здесь и порядок тегов out-N обязаны совпадать.
        final alternates = (_selectorSupported && !proxyOnly)
            ? usable.where((e) => !identical(e, profile)).toList()
            : const <_ParsedVless>[];
        var config = _buildSingBoxConfig(
          profile,
          dnsProtection: dnsProtection,
          blockAds: blockAds,
          dpiBypass: dpiBypass,
          selectedPackages: selectedPackages,
          splitTunnelMode: splitTunnelMode,
          extraExcludedPackages:
              selfPackage != null ? <String>[selfPackage] : const <String>[],
          proxyOnly: proxyOnly,
          dnsProvider: dnsProvider,
          customDns: customDns,
          bypassLan: bypassLan,
          muxEnabled: muxEnabled,
          muxProtocol: muxProtocol,
          fakeIpDns: fakeIpDns,
          ipv6Enabled: ipv6Enabled,
          tlsFragmentSupported: tlsFragmentSupported,
          unifiedDelaySupported: unifiedDelaySupported,
          alternates: alternates,
        );
        // Если сборка ядра не переваривает группу-селектор, конфиг отвергается
        // здесь, до попытки поднять туннель: пересобираем его с одним outbound'ом
        // и больше селектор в этом запуске не предлагаем.
        var sessionOrder = <_ParsedVless>[profile, ...alternates];
        try {
          await _client.checkConfig(config);
        } catch (e) {
          if (alternates.isEmpty) rethrow;
          _selectorSupported = false;
          sessionOrder = const <_ParsedVless>[];
          config = _buildSingBoxConfig(
            profile,
            dnsProtection: dnsProtection,
            blockAds: blockAds,
            dpiBypass: dpiBypass,
            selectedPackages: selectedPackages,
            splitTunnelMode: splitTunnelMode,
            extraExcludedPackages:
                selfPackage != null ? <String>[selfPackage] : const <String>[],
            proxyOnly: proxyOnly,
            dnsProvider: dnsProvider,
            customDns: customDns,
            bypassLan: bypassLan,
            muxEnabled: muxEnabled,
            muxProtocol: muxProtocol,
            fakeIpDns: fakeIpDns,
            ipv6Enabled: ipv6Enabled,
            tlsFragmentSupported: tlsFragmentSupported,
            unifiedDelaySupported: unifiedDelaySupported,
          );
          await _client.checkConfig(config);
        }

        // Конфиг, который реально уходит в ядро, пишем в журнал приложения с
        // замазанными секретами. Это единственный способ понять со стороны
        // пользователя, чем собранный нами конфиг отличается от рабочего в
        // другом клиенте: логи ядра говорят, что соединение не встало, но не
        // говорят, с какими параметрами его пытались поднять.
        unawaited(AppLogService.instance.log('Конфиг ядра: ${_maskSecrets(config)}'));

        Future<void> startSession() => _client.connect(SessionOptions(
              config: config,
              networkMode: proxyOnly ? NetworkMode.proxy : NetworkMode.vpn,
              // На Android split-tunnel задаётся не только в JSON sing-box, но и на
              // VpnService.Builder до establish(): именно нативный allow/disallow-список
              // решает, попадёт ли UID в VPN-сеть. Без perAppProxy VpnService захватывал
              // все UID, включая отмеченные на экране исключений.
              //
              // В режиме исключений передаётся `excludedPackages` — выбранное
              // пользователем плюс, если включена настройка, пакет самого приложения. В
              // режиме 'include' — ровно то, что выбрал пользователь. Когда обоих
              // списков нет, передаётся null.
              perAppProxy: !proxyOnly &&
                      (splitTunnelMode == 'include'
                          ? selectedPackages.isNotEmpty
                          : excludedPackages.isNotEmpty)
                  ? PerAppProxyOptions(
                      mode: splitTunnelMode == 'include'
                          ? PerAppProxyMode.include
                          : PerAppProxyMode.exclude,
                      packages: splitTunnelMode == 'include'
                          ? selectedPackages
                          : excludedPackages,
                    )
                  : null,
              notification: NotificationConfig(
                title: 'VPN подключён',
                channelName: 'VPNOnline — подключение',
                showTrafficStats: true,
                showStopButton: true,
                stopButtonLabel: 'Отключить',
              ),
            ));

        try {
          await startSession();
        } on PlatformException catch (e) {
          // CONNECT_FAILED нативный слой отдаёт, когда Android ещё не успел
          // освободить или поднять VpnService — типичная гонка между остановкой
          // предыдущей сессии (или самим диалогом разрешения) и стартом новой, а не
          // проблема конкретного ключа. Считая это "сервер не подошёл", цикл
          // воспроизводил ту же гонку на каждом из серверов подряд, и выглядело это
          // как "не работает вообще ничего" при полностью рабочих ключах. Поэтому
          // именно для этого кода ждём освобождения сервиса и пробуем тот же профиль
          // ещё раз, прежде чем переходить к следующему.
          if (e.code != 'CONNECT_FAILED') rethrow;
          await _settleAfterDisconnect();
          await startSession();
        }

        final reallyConnected = await _waitForConnected(Duration(seconds: 12));
        if (!reallyConnected) {
          await _settleAfterDisconnect();
          lastFailure =
              'VPN не подключился за 12 сек (ядра sing-box требуют время для инициализации туннеля)';
          continue;
        }

        // Переход serviceStateStream в connected означает только, что поднялся
        // нативный VpnService и Android принял туннель. Пакеты при этом могут не
        // доходить до VLESS-сервера: провайдер режет конкретный сервер, узел лёг,
        // ядро подвисло на резолве в IPv6. Android показывает "подключено", а
        // трафик остаётся на нуле.
        //
        // Поэтому после подъёма интерфейса делаем короткий HTTP HEAD-запрос
        // через локальный инбаунд ядра — он обязан пройти тем же VLESS-каналом
        // (см. _verifyInternetReachable).
        //
        // Не прошёл — идём к следующему серверу в списке. Кроме последнего:
        // если не подтвердилась ни одна локация, причина может быть и не в
        // сервере (оба проверочных адреса заблокированы на его стороне,
        // например). Оставлять пользователя без связи из-за собственной
        // проверки нельзя — принимаем последнюю поднявшуюся сессию и честно
        // пишем в журнал, что связь не подтверждена.
        final internetReachable =
            await _verifyInternetReachable(proxyOnly: proxyOnly);
        final isLastCandidate = identical(profile, usable.last);
        if (!internetReachable && !isLastCandidate) {
          await _settleAfterDisconnect();
          lastFailure =
              'Туннель поднялся, но интернет через него не идёт (сервер "${profile.remark}" не отвечает) — пробуем следующий';
          unawaited(AppLogService.instance.log(
              'Локация "${profile.remark}": туннель поднят, но проверка связи не прошла',
              level: AppLogLevel.warning));
          continue;
        }
        if (!internetReachable) {
          lastError.value =
              'Туннель поднят, но проверка связи через него не прошла — '
              'если сайты не открываются, смени локацию.';
          unawaited(AppLogService.instance.log(
              'Ни одна локация не подтвердила связь; оставлена последняя — "${profile.remark}"',
              level: AppLogLevel.error));
        }

        final connectedName = profile.remark.isNotEmpty
            ? profile.remark
            : (preferredHostName ?? 'VPNOnline');
        connectedServerName.value = connectedName;
        localProxyAddress.value =
            proxyOnly ? '127.0.0.1:$_proxyPort (SOCKS5 и HTTP)' : null;

        _sessionOutboundOrder = sessionOrder;
        // Порядок outbound'ов известен только здесь: тикер, запущенный событием
        // "connected" чуть раньше, не мог знать, есть ли группа.
        _restartLatencyProbe(true);
        _lastConnectionString = connectionString;
        _lastPreferredHostName = preferredHostName;
        // Сохраняем маршрут сессии на диск (см. _persistSessionRoute()) именно
        // здесь: сохранять имеет смысл только то подключение, которое реально
        // поднялось и прошло проверку связности.
        _persistSessionRoute();
        _userInitiatedDisconnect = false;
        killSwitchBlocking.value = false;
        return connectedName;
      } catch (e) {
        lastFailure = e;
        await _settleAfterDisconnect();
        continue;
      }
    }
    throw TunnelException(
      'Не удалось подключиться ни к одному серверу (${usable.length} исп.'
      '${skippedCount > 0 ? ', ещё $skippedCount пропущено — ядро не поддерживает их транспорт' : ''}'
      '): $lastFailure',
    );
  }

  /// Настоящая проверка одной локации подписки: поднимает временную сессию
  /// sing-box в proxy-режиме (не запрашивает VPN-разрешение, не трогает
  /// системный TUN) с конфигом именно этой локации, делает через неё
  /// реальный HTTP-запрос и сразу гасит сессию. Единственный способ
  /// достоверно отличить рабочий VLESS/Reality-сервер от узла с выключенным
  /// инбаундом: обычный TCP/TLS-пинг этого показать не может (см.
  /// `_measureLivePing` в servers_screen.dart).
  ///
  /// Использует тот же единственный нативный клиент, что и боевое
  /// подключение, поэтому никогда не запускается, пока туннель поднят или
  /// поднимается (проверка isConnected/isBusy ниже — последний рубеж, сам
  /// вызывающий код в servers_screen.dart тоже это контролирует).
  ///
  /// На время тестовой сессии временно отписываемся от serviceStateStream,
  /// trafficStatsStream и faultStream и подписываемся заново уже после её
  /// гашения: иначе служебные события проверки долетели бы до публичных
  /// status/lastError, и пользователь на секунду увидел бы, что VPN сам
  /// подключился или отключился.
  Future<RealCheckResult> realCheckProfile(
      String connectionString, String hostName) async {
    if (isConnected || isBusy || _probeInProgress) {
      return const RealCheckResult(
          ok: false,
          error: 'Сейчас активен другой туннель или уже идёт проверка.');
    }
    await _ensureInitialized();

    _ParsedVless? profile;
    try {
      final profiles = await _loadProfiles(connectionString);
      profile = _matchProfile(profiles, hostName);
    } catch (e) {
      return RealCheckResult(ok: false, error: 'Подписка не распознана: $e');
    }
    if (profile == null) {
      return const RealCheckResult(
          ok: false, error: 'Локация не найдена в подписке.');
    }
    // Транспорт, которого ядро не знает, отсекаем здесь: иначе проверка
    // упиралась бы в отказ ядра на этапе разбора конфига и сообщала
    // «конфигурация отклонена» вместо внятной причины.
    if (!await _isProfileSupported(profile)) {
      return RealCheckResult(
        ok: false,
        error: 'Транспорт ${profile.transportType ?? "?"} не поддерживается '
            'установленным ядром',
      );
    }

    // proxyOnly обязательно true: только он добавляет в конфиг локальный
    // inbound на 127.0.0.1:$_proxyPort, без которого
    // _verifyInternetReachable(proxyOnly: true) стучался бы в порт, который
    // никто не слушает, и проверка проваливалась бы даже для рабочего сервера.
    //
    // Mux здесь выключен намеренно. Он окупается, когда через одно
    // VLESS/Reality-соединение идёт много запросов подряд; здесь же ровно один
    // HEAD-запрос на только что поднятой и сразу гасимой сессии — Mux добавит
    // лишнее рукопожатие и целый RTT, ничего не дав взамен. На боевое
    // подключение это не влияет: там значение берётся из LocalPrefs.
    final config = _buildSingBoxConfig(
      profile,
      dnsProtection: false,
      blockAds: false,
      dpiBypass: false,
      selectedPackages: const [],
      proxyOnly: true,
      muxEnabled: false,
      // Число из этой проверки попадает на карточку локации рядом с числом,
      // полученным через живой туннель. Считаться они обязаны одинаково,
      // иначе один и тот же сервер показывал бы 60 мс при включённом VPN и
      // 300 мс при выключенном.
      unifiedDelaySupported: await _coreSupportsUnifiedDelay(),
    );

    _probeInProgress = true;
    await _stateSub?.cancel();
    await _statsSub?.cancel();
    await _faultSub?.cancel();
    await _coreLogSub?.cancel();
    _stateSub = null;
    _statsSub = null;
    _faultSub = null;
    _coreLogSub = null;

    // Секундомер стартует только после того, как сессия реально поднята, прямо
    // перед единственным запросом-пробником. Запущенный раньше, он включал бы
    // в замер холодный старт ядра для этой временной сессии — валидацию
    // конфига, VLESS/Reality-рукопожатие, ожидание serviceStateStream: стабильно
    // сотни миллисекунд, а под нагрузкой и больше секунды сверх настоящей
    // сетевой задержки.
    try {
      try {
        await _client.checkConfig(config);
      } catch (e) {
        return RealCheckResult(
            ok: false, error: 'Конфигурация отклонена ядром: $e');
      }

      bool upped = false;
      final upCompleter = Completer<void>();
      final probeSub = _client.serviceStateStream.listen((state) {
        if (!upCompleter.isCompleted &&
            _mapServiceState(state) == TunnelConnState.connected) {
          upCompleter.complete();
        }
      });

      try {
        await _client.connect(SessionOptions(
          config: config,
          networkMode: NetworkMode.proxy,
          notification: const NotificationConfig(
            title: 'Проверка сервера VPNOnline',
            showTrafficStats: false,
            showStopButton: false,
          ),
        ));
      } catch (e) {
        await probeSub.cancel();
        return RealCheckResult(
            ok: false, error: 'Ядро sing-box не запустилось: $e');
      }

      try {
        await upCompleter.future.timeout(const Duration(seconds: 8));
        upped = true;
      } on TimeoutException {
        upped = false;
      } finally {
        await probeSub.cancel();
      }

      if (!upped) {
        return const RealCheckResult(
            ok: false, error: 'Таймаут запуска ядра sing-box');
      }

      // Сначала выясняем, проходит ли трафик вообще: адреса перебираются, и
      // первый из них может стоить целого таймаута. Это не замер задержки —
      // время здесь не учитывается.
      final probe = await _reachableProbeUrl(proxyOnly: true);
      if (probe == null) {
        return const RealCheckResult(
            ok: false, error: 'VLESS-сервис не отвечает на запрос');
      }
      // Задержку спрашиваем у ядра: оно не включает в неё дозвон до сервера,
      // поэтому число сопоставимо с тем, что показывают другие клиенты. Свой
      // замер оставлен запасным — он честный, но завышенный на рукопожатие.
      final first = await _measureGroupDelayMs();
      final second = await _measureGroupDelayMs();
      int? best;
      for (final value in [first, second]) {
        if (value == null) continue;
        if (best == null || value < best) best = value;
      }
      final latency = best ?? await _measureWarmDelayMs(probe);
      return RealCheckResult(ok: true, latencyMs: latency);
    } finally {
      try {
        await _disconnectNative();
      } catch (_) {}
      // Та же пауза, что и в _settleAfterDisconnect() ниже — даём
      // нативному сервису реально освободиться, прежде чем следующая
      // проверка или обычное подключение попробуют стартовать заново.
      await Future.delayed(const Duration(milliseconds: 350));
      // Восстанавливаем обычные подписки на события основного клиента —
      // ровно как делает _ensureInitialized() при первом запуске.
      _stateSub = _client.serviceStateStream.listen(_applyServiceState);
      _statsSub = _client.trafficStatsStream.listen(_applyTrafficStats);
      _faultSub = _client.faultStream.listen((error) {
        lastError.value = error.toString();
      });
      _probeInProgress = false;
    }
  }

  /// Проверка сразу всех локаций подписки за один подъём ядра.
  ///
  /// Так это делает Hiddify и так это обязано работать здесь: одна временная
  /// сессия, в которой все серверы подписки лежат отдельными outbound'ами
  /// внутри группы `latency`, и один URLTest по всей группе. Ядро опрашивает
  /// участников параллельно и отдаёт по каждому честное время запроса через
  /// его собственный VLESS-канал.
  ///
  /// Чем это лучше прежнего обхода по одной локации ([realCheckProfile]):
  ///  * число — это задержка канала, а не время «поднять сессию, сходить
  ///    HTTP-запросом, погасить сессию». Именно оно и превращалось на экране в
  ///    «работает · 5006 мс» у полностью живого сервера;
  ///  * весь список проверяется за секунды, а не за «несколько секунд на
  ///    локацию», и ядро поднимается один раз, а не N;
  ///  * пока идёт проверка, нет промежутков между сессиями, в которые
  ///    следующая локация получала отказ «сейчас активен другой туннель».
  ///
  /// Ключи результата — remark'и из подписки. Сопоставление их с именами
  /// локаций на экране — забота вызывающего.
  Future<Map<String, RealCheckResult>> realCheckAllProfiles(
      String connectionString) async {
    if (isConnected || isBusy || _probeInProgress) {
      return const <String, RealCheckResult>{};
    }
    await _ensureInitialized();

    List<_ParsedVless> profiles;
    try {
      profiles = await _loadProfiles(connectionString);
    } catch (e) {
      return const <String, RealCheckResult>{};
    }

    // Локация с транспортом, которого ядро не знает, отправила бы в отказ весь
    // конфиг целиком — отсеиваем её до сборки, но в результат кладём внятную
    // причину, а не «нет ответа».
    final usable = <_ParsedVless>[];
    final results = <String, RealCheckResult>{};
    for (final profile in profiles) {
      if (await _isProfileSupported(profile)) {
        usable.add(profile);
      } else if (profile.remark.isNotEmpty) {
        results[profile.remark] = RealCheckResult(
          ok: false,
          error: 'Транспорт ${profile.transportType ?? "?"} не поддерживается '
              'установленным ядром',
        );
      }
    }
    if (usable.isEmpty) return results;

    final config = _buildSingBoxConfig(
      usable.first,
      dnsProtection: false,
      blockAds: false,
      dpiBypass: false,
      selectedPackages: const [],
      proxyOnly: true,
      muxEnabled: false,
      unifiedDelaySupported: await _coreSupportsUnifiedDelay(),
      alternates: usable.skip(1).toList(),
    );

    _probeInProgress = true;
    await _stateSub?.cancel();
    await _statsSub?.cancel();
    await _faultSub?.cancel();
    await _coreLogSub?.cancel();
    _stateSub = null;
    _statsSub = null;
    _faultSub = null;
    _coreLogSub = null;

    try {
      try {
        await _client.checkConfig(config);
      } catch (e) {
        for (final profile in usable) {
          if (profile.remark.isEmpty) continue;
          results[profile.remark] =
              RealCheckResult(ok: false, error: 'Конфигурация отклонена ядром: $e');
        }
        return results;
      }

      final upCompleter = Completer<void>();
      final probeSub = _client.serviceStateStream.listen((state) {
        if (!upCompleter.isCompleted &&
            _mapServiceState(state) == TunnelConnState.connected) {
          upCompleter.complete();
        }
      });
      var upped = false;
      try {
        await _client.connect(SessionOptions(
          config: config,
          networkMode: NetworkMode.proxy,
          notification: const NotificationConfig(
            title: 'Проверка серверов VPNOnline',
            showTrafficStats: false,
            showStopButton: false,
          ),
        ));
        await upCompleter.future.timeout(const Duration(seconds: 10));
        upped = true;
      } catch (_) {
        upped = false;
      } finally {
        await probeSub.cancel();
      }

      if (!upped) {
        for (final profile in usable) {
          if (profile.remark.isEmpty) continue;
          results[profile.remark] = const RealCheckResult(
              ok: false, error: 'Ядро sing-box не запустилось');
        }
        return results;
      }

      // Два прогона и минимум из них — ровно та же арифметика, что у замера
      // через боевой туннель, иначе одна и та же локация давала бы разные
      // числа при включённом и выключенном VPN.
      final first = await _collectGroupDelays(usable);
      final second = await _collectGroupDelays(usable);
      final best = <String, int>{...first};
      second.forEach((remark, delay) {
        final known = best[remark];
        if (known == null || delay < known) best[remark] = delay;
      });

      for (final profile in usable) {
        if (profile.remark.isEmpty) continue;
        final delay = best[profile.remark];
        results[profile.remark] = delay != null
            ? RealCheckResult(ok: true, latencyMs: delay)
            : const RealCheckResult(
                ok: false, error: 'VLESS-сервис не отвечает на запрос');
      }
      unawaited(AppLogService.instance.log(
          'Проверка всех локаций: '
          '${results.entries.map((e) => '${e.key} — '
              '${e.value.ok ? '${e.value.latencyMs} мс' : e.value.error}').join('; ')}'));
      return results;
    } finally {
      try {
        await _disconnectNative();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 350));
      _stateSub = _client.serviceStateStream.listen(_applyServiceState);
      _statsSub = _client.trafficStatsStream.listen(_applyTrafficStats);
      _faultSub = _client.faultStream.listen((error) {
        lastError.value = error.toString();
      });
      _probeInProgress = false;
    }
  }

  /// Останавливает текущую сессию и ждёт, пока сервис реально перейдёт в
  /// disconnected (не дольше 1.5 сек), прежде чем возвращать управление.
  /// Остановка VpnService на Android асинхронна: если следующая попытка
  /// подключения стартует раньше, чем ОС освободила предыдущую сессию,
  /// нативный старт падает с PlatformException(CONNECT_FAILED) даже при
  /// полностью рабочем конфиге. Небольшая пауза после подтверждённого
  /// disconnected — запас на то, что событие плагина не всегда означает
  /// полное освобождение системных ресурсов (TUN, foreground-уведомление).
  Future<void> _settleAfterDisconnect() async {
    try {
      await _disconnectNative();
    } catch (_) {}
    if (status.value?.state != TunnelConnState.disconnected) {
      final completer = Completer<void>();
      VoidCallback? listener;
      final timer = Timer(const Duration(milliseconds: 1500), () {
        if (!completer.isCompleted) completer.complete();
      });
      listener = () {
        if (status.value?.state == TunnelConnState.disconnected &&
            !completer.isCompleted) {
          completer.complete();
        }
      };
      status.addListener(listener);
      try {
        await completer.future;
      } finally {
        timer.cancel();
        status.removeListener(listener);
      }
    }
    await Future.delayed(const Duration(milliseconds: 350));
  }

  static const _proxyPort = 2080;

  /// Группа, по которой ядро меряет задержку. В маршрутизации не участвует.
  static const _latencyGroupTag = 'latency';

  /// Адрес проверки — тот же, что в настройках Hiddify. Обычный HTTP: лишнее
  /// TLS-рукопожатие поверх туннеля добавило бы к замеру целый круговой путь.
  static const _latencyTestUrl = 'http://cp.cloudflare.com/';

  /// Значение задержки, которым libbox помечает провалившуюся проверку
  /// outbound'а (0xFFFF). Всё, что не меньше, — не замер, а отказ.
  static const int _urlTestFailedDelayMs = 65535;

  /// Прячет в тексте конфига то, что даёт доступ к серверу: uuid ключа,
  /// публичный ключ и short id Reality. Всё остальное — адреса, порты,
  /// транспорт, флаги TLS — остаётся, иначе журнал бесполезен для разбора.
  static String _maskSecrets(String config) {
    var masked = config;
    for (final field in ['uuid', 'public_key', 'short_id', 'password']) {
      masked = masked.replaceAllMapped(
        RegExp('"$field"\\s*:\\s*"([^"]*)"'),
        (m) {
          final value = m.group(1) ?? '';
          final tail = value.length > 4 ? value.substring(value.length - 4) : '';
          return '"$field":"…$tail"';
        },
      );
    }
    return masked;
  }

  /// Блок `transport` для XHTTP.
  ///
  /// Схема повторяет hiddify-sing-box (`option.V2RayXHTTPOptions`), а он, в
  /// свою очередь, повторяет Xray: поля идут в camelCase (`xPaddingBytes`,
  /// `scMaxEachPostBytes`, `downloadSettings`), а не в snake_case, как в
  /// остальном конфиге sing-box. Значения из параметра `extra` ссылки
  /// переносятся как есть — ядро само отбросит то, чего не знает; host и path
  /// берутся из ссылки, только если в extra их нет.
  static Map<String, dynamic> _buildXhttpTransport(_ParsedVless p) {
    final transport = <String, dynamic>{'type': 'xhttp'};
    final extra = p.xhttpExtra;
    if (extra != null) {
      for (final entry in extra.entries) {
        if (entry.key == 'downloadSettings' || entry.value == null) continue;
        transport[entry.key] = entry.value;
      }
    }

    // Режимов у XHTTP четыре: auto, packet-up, stream-up, stream-one. Поле
    // обязательное — без него ядро отвергает конфиг ("xhttp: mode is not
    // set"), поэтому при отсутствии в ссылке ставим auto, как это делает
    // Hiddify (ray2sing: getOneOfN(decoded, "auto", "mode")).
    final mode = (p.xhttpMode ?? (extra?['mode'] as String?) ?? '').trim();
    transport['mode'] = mode.isNotEmpty ? mode : 'auto';

    final host = (transport['host'] as String?)?.trim() ?? '';
    if (host.isEmpty) {
      if (p.transportHost != null && p.transportHost!.isNotEmpty) {
        transport['host'] = p.transportHost;
      } else {
        transport.remove('host');
      }
    }

    final path = (transport['path'] as String?)?.trim() ?? '';
    if (path.isEmpty) {
      transport['path'] =
          (p.transportPath == null || p.transportPath!.isEmpty) ? '/' : p.transportPath;
    }

    final download = extra?['downloadSettings'];
    if (download is Map<String, dynamic>) {
      final converted = _buildXhttpDownload(download, transport);
      if (converted != null) transport['downloadSettings'] = converted;
    }
    return transport;
  }

  /// `downloadSettings` в XHTTP описывает отдельный канал для скачивания:
  /// свой адрес, порт и TLS. Xray хранит его в собственном формате
  /// (`address`/`port`/`security`/`tlsSettings`/`realitySettings`), а ядру
  /// нужны `server`/`server_port` и блок `tls` как у обычного outbound'а —
  /// переводим одно в другое, остальные поля XHTTP переносим как есть.
  static Map<String, dynamic>? _buildXhttpDownload(
      Map<String, dynamic> download, Map<String, dynamic> upload) {
    const converted = {
      'address',
      'port',
      'security',
      'tlsSettings',
      'realitySettings',
      'network',
      'downloadSettings',
    };
    final result = <String, dynamic>{};
    for (final entry in download.entries) {
      if (converted.contains(entry.key) || entry.value == null) continue;
      result[entry.key] = entry.value;
    }
    if (((result['path'] as String?) ?? '').trim().isEmpty) {
      final uploadPath = upload['path'];
      if (uploadPath is String && uploadPath.isNotEmpty) result['path'] = uploadPath;
    }

    final server = (download['address'] as String?)?.trim();
    if (server != null && server.isNotEmpty) result['server'] = server;
    final port = (download['port'] as num?)?.toInt();
    if (port != null && port > 0) result['server_port'] = port;

    final security = (download['security'] as String?)?.toLowerCase();
    final reality = download['realitySettings'];
    final tlsSettings = download['tlsSettings'];
    if (security == 'reality' && reality is Map<String, dynamic>) {
      final publicKey = reality['publicKey'] ?? reality['public_key'];
      // reality без публичного ключа ядро не примет — тот же случай, что и в
      // _ParsedVless.tryParse: лучше отдать канал без TLS-блока, чем конфиг,
      // который не пройдёт проверку.
      if (publicKey is String && publicKey.isNotEmpty) {
        final shortId = reality['shortId'] ?? reality['short_id'];
        final serverName = reality['serverName'] ?? reality['server_name'];
        final fingerprint = reality['fingerprint'];
        result['tls'] = <String, dynamic>{
          'enabled': true,
          if (serverName is String && serverName.isNotEmpty)
            'server_name': serverName,
          'utls': {
            'enabled': true,
            'fingerprint':
                (fingerprint is String && fingerprint.isNotEmpty) ? fingerprint : 'chrome',
          },
          'reality': {
            'enabled': true,
            'public_key': publicKey,
            if (shortId is String && shortId.isNotEmpty) 'short_id': shortId,
          },
        };
      }
    } else if (security == 'tls' && tlsSettings is Map<String, dynamic>) {
      final serverName = tlsSettings['serverName'] ?? tlsSettings['server_name'];
      final alpn = tlsSettings['alpn'];
      final fingerprint = tlsSettings['fingerprint'];
      result['tls'] = <String, dynamic>{
        'enabled': true,
        if (serverName is String && serverName.isNotEmpty) 'server_name': serverName,
        if (alpn is List && alpn.isNotEmpty) 'alpn': alpn,
        if (tlsSettings['allowInsecure'] == true) 'insecure': true,
        if (fingerprint is String && fingerprint.isNotEmpty)
          'utls': {'enabled': true, 'fingerprint': fingerprint},
      };
    }
    return result.isEmpty ? null : result;
  }

  String _buildSingBoxConfig(
    _ParsedVless p, {
    required bool dnsProtection,
    required bool blockAds,
    required bool dpiBypass,
    required List<String> selectedPackages,
    bool proxyOnly = false,
    String dnsProvider = 'cloudflare',
    String? customDns,
    // 'exclude' — selectedPackages идут в обход VPN (старое поведение).
    // 'include' — ТОЛЬКО selectedPackages идут через VPN.
    String splitTunnelMode = 'exclude',
    // Пакеты, исключаемые из туннеля дополнительно к выбранным пользователем
    // на экране split-tunnel. Сегодня это ровно одно значение — пакет самого
    // приложения (PrefKeys.excludeAppFromTunnel).
    List<String> extraExcludedPackages = const <String>[],
    bool bypassLan = false,
    bool muxEnabled = false,
    String muxProtocol = 'h2mux',
    bool fakeIpDns = false,
    bool ipv6Enabled = false,
    // Умеет ли ядро фрагментировать собственное рукопожатие (см.
    // _coreSupportsTlsFragment). От этого зависит, чем включается «Обход DPI».
    bool tlsFragmentSupported = false,
    // Умеет ли ядро «единую задержку» (см. _coreSupportsUnifiedDelay). От
    // этого зависит, какое число показывается пользователю как пинг.
    bool unifiedDelaySupported = false,
    // Остальные локации подписки. Пустой список означает один outbound и
    // никакой группы — см. построение `outbounds` ниже.
    List<_ParsedVless> alternates = const <_ParsedVless>[],
  }) {
    // Сборка одного proxy-outbound вынесена в функцию, чтобы тот же код собрал
    // несколько — по одному на каждую локацию подписки. С единственным
    // outbound'ом смена страны требовала нового конфига и перезапуска ядра, то
    // есть разрыва туннеля.
    Map<String, dynamic> buildProxyOutbound(_ParsedVless p, String outboundTag) {
      final outbound = <String, dynamic>{
        'type': 'vless',
        'tag': outboundTag,
        'server': p.host,
        'server_port': p.port,
        'uuid': p.uuid,
        if (p.flow != null && p.flow!.isNotEmpty) 'flow': p.flow,
        // Как упаковывать UDP внутри VLESS. Панели линейки x-ui поднимают
        // Xray, а он принимает только XUDP; в «родном» формате sing-box такие
        // пакеты сервер молча отбрасывает, и при живом TCP не работают ни
        // QUIC, ни звонки в мессенджерах, ни DNS по UDP через туннель.
        // Hiddify подставляет xudp всегда, когда в ссылке нет packetEncoding
        // (ray2sing/vless.go).
        'packet_encoding': p.packetEncoding ?? 'xudp',
        // «Обход DPI» в том виде, в каком он вообще что-то значит: рвётся на
        // куски наше собственное TLS-рукопожатие к VLESS-серверу — то самое,
        // по которому DPI решает, пропускать соединение или нет. Правило
        // маршрутизации с tls_fragment, которое стояло здесь раньше, рвало
        // рукопожатия уже внутри туннеля: для обхода блокировки бесполезно,
        // потому что снаружи видно только внешнее соединение.
        if (dpiBypass && tlsFragmentSupported)
          'tls_fragment': _tlsFragmentOptions,
        // Mux (PrefKeys.muxEnabled) по умолчанию выключен — как и в Hiddify.
        // Мультиплексор sing-box (smux/yamux/h2mux) понимает только сервер на
        // sing-box; Xray за ним не следует, и обёрнутое соединение рвётся
        // сразу после рукопожатия. Включать стоит, только если точно известно,
        // что на той стороне sing-box.
        //
        // С flow: xtls-rprx-vision несовместим в любом случае: такие потоки
        // сами управляют TCP-соединением на уровне TLS.
        if (muxEnabled && (p.flow == null || p.flow!.isEmpty))
          'multiplex': {
            'enabled': true,
            'protocol': muxProtocol,
            'max_streams': 8,
            'padding': true,
          },
      };

      if (p.security == 'reality' || p.security == 'tls') {
        // uTLS подставляем только там, где он действительно нужен: отпечаток
        // задан в ссылке или это Reality (без маскировки под браузер Reality
        // не работает вовсе). Навязывать «хром» обычному TLS не нужно — часть
        // серверов на нестандартный ClientHello отвечает отказом. Так же
        // поступает Hiddify (ray2sing: fp по умолчанию только для reality).
        final fingerprint = (p.fp != null && p.fp!.isNotEmpty)
            ? p.fp
            : (p.security == 'reality' ? 'chrome' : null);
        final alpn = _alpnForTransport(p.transportType, p.alpn);
        outbound['tls'] = {
          'enabled': true,
          'server_name': p.sni ?? p.host,
          if (p.allowInsecure) 'insecure': true,
          if (alpn != null) 'alpn': alpn,
          if (fingerprint != null)
            'utls': {'enabled': true, 'fingerprint': fingerprint},
          if (p.security == 'reality')
            'reality': {
              'enabled': true,
              'public_key': p.pbk,
              if (p.sid != null && p.sid!.isNotEmpty) 'short_id': p.sid,
            },
        };
      }

      // Маскировка/транспорт (ws, grpc, http) — обязателен для ключей, где
      // сервер ожидает не голый TCP, а конкретный транспортный "конверт".
      // Без этого блока такие ключи (например, экспортированные с
      // http-заголовками из другого клиента) не подключаются: сервер отвергает handshake.
      final transportType = p.transportType ?? 'tcp';
      if (transportType == 'ws') {
        // `ed` в query пути — размер раннего пакета (0-RTT). Xray кладёт его
        // прямо в path (`/ws?ed=2048`), sing-box ждёт отдельных полей
        // max_early_data и early_data_header_name. Оставленный в пути
        // параметр сервер не понимает, и соединение обрывается на апгрейде.
        final ws = _splitEarlyData(p.transportPath);
        outbound['transport'] = {
          'type': 'ws',
          'path': ws.path,
          if (p.transportHost != null && p.transportHost!.isNotEmpty)
            'headers': {'Host': p.transportHost},
          if (ws.maxEarlyData > 0) ...{
            'max_early_data': ws.maxEarlyData,
            'early_data_header_name': 'Sec-WebSocket-Protocol',
          },
        };
      } else if (transportType == 'grpc') {
        outbound['transport'] = {
          'type': 'grpc',
          'service_name': (p.transportPath == null || p.transportPath!.isEmpty)
              ? ''
              : p.transportPath,
          // Те же таймауты, что подставляет Hiddify: без них соединение
          // держится до разрыва на стороне сервера и не переоткрывается.
          'idle_timeout': '15s',
          'ping_timeout': '15s',
          'permit_without_stream': false,
        };
      } else if (transportType == 'http') {
        outbound['transport'] = {
          'type': 'http',
          if (p.transportHost != null && p.transportHost!.isNotEmpty)
            'host': [p.transportHost],
          'path': (p.transportPath == null || p.transportPath!.isEmpty)
              ? '/'
              : p.transportPath,
          // Без TLS транспорт http — это обычная HTTP-маскировка, и запрос
          // должен быть GET. Поверх TLS это уже HTTP/2, там метод не задаётся.
          if (p.security != 'tls' && p.security != 'reality') 'method': 'GET',
        };
      } else if (transportType == 'httpupgrade') {
        // HTTPUpgrade — ближайший к XHTTP транспорт, который это ядро реально
        // умеет. Без этой ветки ключ с `type=httpupgrade` проваливался в "tcp"
        // ниже: блок transport не добавлялся, и сервер отвергал handshake без
        // внятной причины.
        outbound['transport'] = {
          'type': 'httpupgrade',
          if (p.transportHost != null && p.transportHost!.isNotEmpty)
            'headers': {'Host': p.transportHost},
          'path': _splitEarlyData(p.transportPath).path,
        };
      } else if (transportType == 'xhttp') {
        // XHTTP (в старых панелях — splithttp). Апстримный sing-box этого
        // транспорта не знает, его понимает только форк, на котором работает
        // Hiddify (hiddify-sing-box). Профиль доходит сюда, только если ядро
        // подтвердило поддержку — см. _coreSupportsTransport().
        outbound['transport'] = _buildXhttpTransport(p);
      }
      // transportType == 'tcp' (или неизвестный) — без блока "transport",
      // как и раньше: sing-box по умолчанию использует голый TCP.
      return outbound;
    }

    // DNS-блок повторяет схему Hiddify (hiddify-core/v2/config/dns.go):
    // три резолвера с разными задачами.
    //
    //  * dns-remote — всё, что уходит в туннель. Обычный UDP, а не DoT/DoH:
    //    запрос и так идёт внутри VLESS, второй слой TLS ничего не скрывает,
    //    зато добавляет рукопожатие, которое на части сетей не проходит —
    //    снаружи это выглядит как «подключено, а интернета нет».
    //  * dns-direct — прямые соединения и, главное, адрес самого
    //    VLESS-сервера, когда он задан доменом (route.default_domain_resolver
    //    ниже). Через туннель его резолвить нельзя: туннель ещё не поднят.
    //  * dns-local — системный резолвер устройства, им разрешается адрес
    //    самого dns-direct, если тот задан доменом.
    const dnsProviders = {
      'cloudflare': '1.1.1.1',
      'google': '8.8.8.8',
      'adguard': '94.140.14.14',
      'quad9': '9.9.9.9',
    };
    // Провайдер 'custom' — адрес с экрана "Настройки"
    // (PrefKeys.customDnsServer). Если custom выбран, но адрес не указан,
    // откатываемся на Cloudflare, чтобы не отправлять sing-box пустой server.
    final hasCustomDns = dnsProvider == 'custom' &&
        customDns != null &&
        customDns.trim().isNotEmpty;
    final remoteDnsAddress = hasCustomDns
        ? customDns.trim()
        : (dnsProviders[dnsProvider] ?? '1.1.1.1');

    final dnsServers = <Map<String, dynamic>>[
      {
        ..._dnsServerOptions(remoteDnsAddress),
        'tag': 'dns-remote',
        'detour': 'proxy',
        'domain_resolver': 'dns-direct',
      },
      {
        ..._dnsServerOptions('1.1.1.1'),
        'tag': 'dns-direct',
        'domain_resolver': 'dns-local',
      },
      {'type': 'local', 'tag': 'dns-local'},
      // Fake IP (PrefKeys.fakeIpDns): домены резолвятся в адреса из служебных
      // диапазонов мгновенно, без запроса наружу, а настоящий домен ядро
      // подставляет обратно по своей таблице. Таблица обязана переживать
      // перезапуск ядра — см. experimental.cache_file ниже.
      if (fakeIpDns)
        {
          'type': 'fakeip',
          'tag': 'dns-fake',
          'inet4_range': '198.18.0.0/15',
          'inet6_range': 'fc00::/18',
        },
    ];
    final dnsRules = <Map<String, dynamic>>[
      if (fakeIpDns)
        {
          'query_type': ['A', 'AAAA'],
          'action': 'route',
          'server': 'dns-fake',
        },
    ];

    final routeRules = <Map<String, dynamic>>[
      // Порядок правил взят у Hiddify: сначала сниффинг, потом перехват DNS,
      // и только потом всё остальное. В TUN-режиме на вход попадают голые
      // IP-пакеты без домена, и единственный источник поля "domain" для
      // правил ниже — сниффинг SNI из TLS ClientHello.
      {'action': 'sniff'},
      {'protocol': 'dns', 'action': 'hijack-dns'},
      // geoip:'private' здесь использовать нельзя: база GeoIP объявлена
      // устаревшей в sing-box 1.8.0 и удалена в 1.12.0 — отсюда ошибка
      // "geoip database is deprecated" и разрыв соединения на всех серверах.
      // Замена — булево ip_is_private: никакой базы не требует и матчит
      // приватные диапазоны прямо в бинарнике.
      //
      // Под условием bypassLan: выключив "Обход локальной сети", пользователь
      // заворачивает в туннель и LAN-трафик — например, чтобы достучаться до
      // ресурсов в сети самого VPN-сервера.
      if (bypassLan)
        {'ip_is_private': true, 'action': 'route', 'outbound': 'direct'},
      if (blockAds) {'domain_suffix': _adBlockDomains, 'action': 'reject'},
      // Запасной вариант для ядра без фрагментации на outbound'е: правило
      // маршрутизации с булевым tls_fragment. Оно рвёт рукопожатия внутри
      // туннеля, а не наше собственное, и от блокировки по ClientHello не
      // спасает — но и вреда не делает, а на части сетей помогает сайтам,
      // которые режет уже сам провайдер за пределами туннеля.
      if (dpiBypass && !tlsFragmentSupported)
        {
          'network': 'tcp',
          'action': 'route',
          'outbound': 'proxy',
          'tls_fragment': true,
        },
    ];

    // Когда переданы альтернативные локации, в конфиг кладётся по outbound'у
    // на каждую (`out-0`, `out-1`, ...) плюс группа-`selector` с тегом `proxy`.
    // Тег остаётся тем же, на который уже ссылаются route.final, правило
    // tls_fragment и detour у DNS, так что остальной конфиг не меняется.
    //
    // Ядро умеет переключать активный outbound внутри такой группы на лету, не
    // останавливая себя и не трогая TUN (см. switchPreferredHost).
    // `interrupt_exist_connections: false` оставляет существующие соединения на
    // прежнем сервере: скачивание или видео, запущенные до смены, не
    // обрываются.
    //
    // Пустой `alternates` даёт прежний конфиг — один outbound с тегом `proxy`,
    // без группы.
    final useSelector = !proxyOnly && alternates.isNotEmpty;
    final outbounds = <Map<String, dynamic>>[];
    if (!useSelector) {
      outbounds.add(buildProxyOutbound(p, 'proxy'));
    } else {
      final memberTags = <String>['out-0'];
      outbounds.add(buildProxyOutbound(p, 'out-0'));
      for (var i = 0; i < alternates.length; i++) {
        final tag = 'out-${i + 1}';
        memberTags.add(tag);
        outbounds.add(buildProxyOutbound(alternates[i], tag));
      }
      outbounds.add(<String, dynamic>{
        'type': 'selector',
        'tag': 'proxy',
        'outbounds': memberTags,
        'default': 'out-0',
        'interrupt_exist_connections': false,
      });
    }
    // Группа `urltest` существует только ради честного замера задержки — в
    // маршрутизации она не участвует, трафик по-прежнему идёт через `proxy`.
    //
    // Нужна она по двум причинам. Первая: команда urlTest для группы, которая
    // не является urltest-группой, всегда проверяет ядровый адрес по
    // умолчанию — `https://www.gstatic.com/generate_204`, недоступный из
    // России. Отсюда и брались 65535 мс, то есть код отказа. У urltest-группы
    // адрес свой, и мы ставим тот же, что Hiddify.
    //
    // Вторая: ядро при своём замере перезапускает секундомер после дозвона до
    // сервера (см. common/urltest — `if NeedHandshakeForWrite(instance)`), то
    // есть не включает в число TLS/Reality-рукопожатие. Свой замер через
    // локальный HTTP-инбаунд так не умеет: sing-box открывает новое
    // соединение на каждый запрос, и в число попадает полное рукопожатие —
    // отсюда 388 мс там, где на самом деле 75.
    {
      outbounds.add(<String, dynamic>{
        'type': 'urltest',
        'tag': _latencyGroupTag,
        'outbounds':
            useSelector ? ['out-0', for (var i = 0; i < alternates.length; i++) 'out-${i + 1}'] : ['proxy'],
        'url': _latencyTestUrl,
        // Своим расписанием группа почти не пользуется: замер запускает само
        // приложение, когда туннель простаивает. Большой интервал — чтобы
        // ядро не будило радиомодуль лишний раз.
        'interval': '10m',
        'tolerance': 50,
        'idle_timeout': '30m',
      });
    }
    outbounds.add({'type': 'direct', 'tag': 'direct'});

    final inbounds = <Map<String, dynamic>>[];
    if (proxyOnly) {
      inbounds.add({
        'type': 'mixed',
        'tag': 'mixed-in',
        'listen': '127.0.0.1',
        'listen_port': _proxyPort,
      });
    } else {
      // Локальный 'mixed'-инбаунд поднимается и в VPN-режиме, не только при
      // proxyOnly. Без него connectedDelayMs() вынужден мерить задержку сырым
      // Socket.connect() до IP сервера, а Android обязан исключать трафик самого
      // приложения из своего TUN (см. _verifyInternetReachable) — такой сокет
      // физически не проходит через туннель и меряет обычный прямой пинг
      // телефона, отсюда неправдоподобные "2 мс" при поднятом VPN.
      //
      // Это второй, независимый от TUN инбаунд: sing-box спокойно держит
      // несколько сразу. Трафик на 127.0.0.1:$_proxyPort идёт прямо в процесс
      // sing-box в обход TUN, но наружу выходит тем же VLESS-соединением
      // ('outbound': 'proxy'), что и боевой.
      inbounds.add({
        'type': 'mixed',
        'tag': 'mixed-in',
        'listen': '127.0.0.1',
        'listen_port': _proxyPort,
      });
      inbounds.add({
        'type': 'tun',
        'tag': 'tun-in',
        'interface_name': 'vpnonline-tun',
        // 9000, как в Hiddify и по умолчанию в sing-box. TCP внутри TUN
        // терминируется самим ядром, наружу данные уходят отдельным
        // соединением, поэтому большой MTU не приводит к фрагментации, зато
        // снимает лишние проходы по стеку.
        'mtu': 9000,
        // strict_route обязателен на Android: без него не работает 'hijack-dns'
        // ниже (в документации sing-box — "prevents IP address leaks and makes DNS
        // hijacking work on Android").
        'strict_route': true,
        // Стек 'system' на Android заметно капризнее к устройству и прошивке, чем
        // 'mixed': на части устройств (в первую очередь с двумя SIM или несколькими
        // активными интерфейсами) он не поднимает маршруты и при этом не бросает
        // ошибку — трафик молча не идёт, а интерфейс выглядит рабочим. 'mixed'
        // (TCP через системный стек, UDP через gVisor) — рекомендуемый sing-box'ом
        // баланс совместимости и производительности.
        'stack': 'mixed',
        'auto_route': true,
        'endpoint_independent_nat': true,
        // `hijack-dns` на Android требует явный IPv4-адрес TUN, иначе sing-box
        // завершает запуск с "need one more IPv4 address for DNS hijacking". IPv6
        // добавляется вторым адресом, не заменяя обязательный IPv4.
        'address': [
          '172.19.0.1/28',
          if (ipv6Enabled) 'fdfe:dcba:9876::1/126',
        ],
        // Режим split-tunnel (PrefKeys.splitTunnelMode). sing-box не позволяет
        // задать include_package и exclude_package одновременно, поэтому всегда
        // ровно одно поле. В режиме 'include' через туннель идут строго те
        // приложения, которые выбрал пользователь.
        if (selectedPackages.isNotEmpty && splitTunnelMode == 'include')
          'include_package': selectedPackages,
        // В режиме исключений к пользовательскому списку добавляется
        // extraExcludedPackages (пакет самого приложения). При пустом
        // selectedPackages поле в конфиг не попадает вовсе.
        if (splitTunnelMode != 'include' && _excludeList(selectedPackages, extraExcludedPackages).isNotEmpty)
          'exclude_package':
              _excludeList(selectedPackages, extraExcludedPackages),
      });
    }

    final config = <String, dynamic>{
      'log': {'level': 'warn'},
      'dns': {
        'servers': dnsServers,
        if (dnsRules.isNotEmpty) 'rules': dnsRules,
        // 'final' — фолбэк, когда ни одно правило не сработало. Тумблер
        // "Защита от DNS-протечек" решает, куда он ведёт: через туннель
        // (запросы видит только VPN-сервер) или напрямую (быстрее, но имена
        // сайтов видит провайдер).
        'final': dnsProtection ? 'dns-remote' : 'dns-direct',
        // Явная 'strategy' обязательна. Без неё sing-box может резолвить
        // сайты в IPv6 у провайдера, который формально его поддерживает, но
        // реально не маршрутизирует AAAA — частая ситуация у мобильных
        // операторов. TCP SYN на IPv6-адрес уходит в никуда без ошибки,
        // соединение просто висит: те же "подключено, 0 МБ".
        //
        // Когда пользователь осознанно включил IPv6, берём 'prefer_ipv4'
        // вместо жёсткого 'ipv4_only': резолвер по-прежнему предпочитает
        // IPv4, но при отсутствии A-записи честно отдаёт AAAA.
        'strategy': ipv6Enabled ? 'prefer_ipv4' : 'ipv4_only',
        'independent_cache': false,
      },
      'inbounds': inbounds,
      'outbounds': outbounds,
      'route': {
        // На Android сокеты самого ядра защищает VpnService.protect(), и
        // вызывает его ядро только при включённом auto_detect_interface —
        // иначе исходящее соединение уйдёт обратно в TUN и зациклится.
        'auto_detect_interface': true,
        'final': 'proxy',
        // Чем резолвить домены, к которым подключается само ядро — прежде
        // всего адрес VLESS-сервера. Без этого поля резолв идёт общим путём,
        // то есть через dns-remote с `detour: proxy`: чтобы поднять туннель,
        // нужно зарезолвить домен, а резолвер ходит через тот же ещё не
        // поднятый туннель. На сервере, заданном IP, это незаметно, а на
        // домене подключение висит до таймаута.
        'default_domain_resolver': {'server': 'dns-direct'},
        'rules': routeRules,
      },
      // Файл состояния ядра. Без него таблица Fake IP живёт только в памяти
      // процесса: после перезапуска ядра адреса 198.18.x.x, уже закэшированные
      // браузером и мессенджерами, перестают разворачиваться обратно в домены,
      // и соединения рвутся с "missing fakeip record" — снаружи это выглядит
      // как ERR_CONNECTION_RESET на каждом сайте.
      'experimental': {
        'cache_file': {
          'enabled': true,
          if (fakeIpDns) 'store_fakeip': true,
        },
        // Счётчики «принято/отдано» ядро ведёт внутри Clash API: без этого
        // блока оно вообще не считает трафик и отдаёт нули, отчего на главном
        // экране при живом туннеле вечно висело «0 MB».
        //
        // `external_controller` намеренно пустой: тогда ядро заводит счётчики,
        // но не открывает управляющий порт. Открытый порт здесь не нужен, а
        // при перезапуске сессии он ещё и занят предыдущей — ядро падало бы
        // на старте.
        'clash_api': {'external_controller': ''},
        // «Единая задержка» — то, из-за чего Hiddify на тех же серверах
        // показывает 40-80 мс, а не 200-400. Ядро прогоняет проверку дважды по
        // одному и тому же уже поднятому соединению и отдаёт время второго
        // запроса: без дозвона до сервера и без VLESS/Reality-рукопожатия,
        // только чистый круговой путь. Включается там, где опция есть (форк
        // hiddify-sing-box); на штатном ядре поля в конфиге просто нет, и
        // задержка считается по-старому — см. _coreSupportsUnifiedDelay.
        if (unifiedDelaySupported) 'unified_delay': {'enabled': true},
      },
    };

    return jsonEncode(config);
  }

  /// Конфиг служебной блокирующей сессии строгого Kill Switch — для тестов:
  /// если ядро его не примет, режим просто не включится, и заметить это без
  /// реального устройства нечем.
  @visibleForTesting
  String buildBlockAllConfigForTest() => _buildBlockAllConfig();

  /// Собирает конфиг по готовой `vless://`-ссылке — для тестов и отладки:
  /// сам сборщик приватный и принимает уже разобранный профиль.
  @visibleForTesting
  String buildConfigFromUri(
    String vlessUri, {
    bool proxyOnly = false,
    bool muxEnabled = false,
    bool blockAds = false,
    bool dpiBypass = false,
    bool fakeIpDns = false,
    bool bypassLan = false,
    bool ipv6Enabled = false,
    bool tlsFragmentSupported = false,
    bool unifiedDelaySupported = false,
    bool dnsProtection = true,
    String dnsProvider = 'cloudflare',
    String? customDns,
    String muxProtocol = 'smux',
    String splitTunnelMode = 'exclude',
    List<String> selectedPackages = const <String>[],
    List<String> extraExcludedPackages = const <String>[],
    List<String> alternateUris = const <String>[],
  }) {
    final profile = _ParsedVless.tryParse(vlessUri);
    if (profile == null) {
      throw TunnelException('Ссылка не распознана: $vlessUri');
    }
    final alternates = <_ParsedVless>[];
    for (final uri in alternateUris) {
      final parsed = _ParsedVless.tryParse(uri);
      if (parsed != null) alternates.add(parsed);
    }
    return _buildSingBoxConfig(
      profile,
      dnsProtection: dnsProtection,
      blockAds: blockAds,
      dpiBypass: dpiBypass,
      selectedPackages: selectedPackages,
      splitTunnelMode: splitTunnelMode,
      extraExcludedPackages: extraExcludedPackages,
      proxyOnly: proxyOnly,
      dnsProvider: dnsProvider,
      customDns: customDns,
      bypassLan: bypassLan,
      muxEnabled: muxEnabled,
      muxProtocol: muxProtocol,
      fakeIpDns: fakeIpDns,
      ipv6Enabled: ipv6Enabled,
      tlsFragmentSupported: tlsFragmentSupported,
      unifiedDelaySupported: unifiedDelaySupported,
      alternates: alternates,
    );
  }

  /// Объединяет пользовательские исключения split-tunnel с служебными
  /// (пакет самого приложения) без дубликатов и с сохранением порядка.
  static List<String> _excludeList(
      List<String> userSelected, List<String> extra) {
    if (extra.isEmpty) return userSelected;
    return <String>{...userSelected, ...extra}.toList();
  }

  static const _adBlockDomains = [
    'doubleclick.net',
    'googlesyndication.com',
    'googleadservices.com',
    'google-analytics.com',
    'admob.com',
    'connect.facebook.net',
    'ads.mail.ru',
    'an.yandex.ru',
    'mc.yandex.ru',
    'top-fwz1.mail.ru',
    'amplitude.com',
    'appsflyer.com',
    'adjust.com',
  ];

  Future<List<_ParsedVless>> _loadProfiles(String connectionString,
      {bool forceRefresh = false}) async {
    final source = connectionString.trim();
    if (source.isEmpty) {
      throw TunnelException(
          'Не разместили ссылку на конфигурацию VLESS Reality.');
    }

    if (!forceRefresh &&
        _cachedProfiles != null &&
        _cachedSource == source &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheTtl) {
      return _cachedProfiles!;
    }

    String body;
    if (source.startsWith('vless://')) {
      body = source;
    } else {
      try {
        // Заголовки как у обычного подписочного клиента: панели (3x-ui, Marzban)
        // часто отдают разное содержимое в зависимости от User-Agent — например,
        // пустой ответ или HTML-страницу логина вместо подписки. С дефолтным
        // агентом Dart часть панелей не распознаёт клиента как подписочный.
        final res = await http.get(
          Uri.parse(source),
          headers: const {
            'User-Agent': 'VPNonLine/1.0 (sing-box-client; compatible)',
            'Accept': 'text/plain, application/json;q=0.9, */*;q=0.8',
          },
        ).timeout(Duration(seconds: 12));
        if (res.statusCode >= 400) {
          throw TunnelException(
              'Подписка недоступна (${res.statusCode}). Попробуйте позднее.');
        }
        body = res.body;
      } on TunnelException {
        rethrow;
      } catch (e) {
        throw TunnelException(
            'Не удалось загрузить конфигурацию подписки. Проверьте ссылку или интернет.');
      }
    }

    final profiles = _parseSubscriptionBody(body);
    if (profiles.isEmpty) {
      throw TunnelException(
          'Конфигурация не содержит рабочих серверов VLESS+Reality.');
    }

    _cachedSource = source;
    _cachedProfiles = profiles;
    _cachedAt = DateTime.now();
    return profiles;
  }

  List<_ParsedVless> _parseSubscriptionBody(String body) {
    String text = body.trim();

    // Некоторые панели отдают не base64-список vless://-ссылок, а готовый
    // JSON-конфиг sing-box: полный объект с "outbounds" либо просто массив
    // outbound'ов. Пробуем распарсить его до того, как трактовать текст как
    // список ссылок.
    if (text.startsWith('{') || text.startsWith('[')) {
      final fromJson = _parseSingboxJsonOutbounds(text);
      if (fromJson.isNotEmpty) return fromJson;
    }

    if (!text.contains('vless://')) {
      try {
        final normalized = text.replaceAll('-', '+').replaceAll('_', '/');
        final padded = normalized.padRight(
            normalized.length + (4 - normalized.length % 4) % 4, '=');
        final decoded = utf8.decode(base64.decode(padded));
        if (decoded.contains('vless://')) text = decoded;
      } catch (_) {}
    }

    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.startsWith('vless://'))
        .toList();

    final result = <_ParsedVless>[];
    for (final line in lines) {
      final parsed = _ParsedVless.tryParse(line);
      if (parsed != null) result.add(parsed);
    }
    return result;
  }

  /// Достаёт vless-профили из JSON-конфига sing-box — из `{"outbounds":[...]}`
  /// или из голого массива outbound'ов. Молча пропускает outbound'ы других
  /// типов (direct/block/urltest) и vless-записи без полей, необходимых для
  /// подключения (те же проверки, что в `_ParsedVless.tryParse`). Ошибки
  /// парсинга наружу не бросает: вызывающий `_parseSubscriptionBody` в этом
  /// случае идёт обычным путём через vless://-ссылки и base64.
  List<_ParsedVless> _parseSingboxJsonOutbounds(String text) {
    try {
      final decoded = jsonDecode(text);
      final List<dynamic> outbounds;
      if (decoded is Map<String, dynamic> && decoded['outbounds'] is List) {
        outbounds = decoded['outbounds'] as List;
      } else if (decoded is List) {
        outbounds = decoded;
      } else {
        return const [];
      }

      final result = <_ParsedVless>[];
      for (final item in outbounds) {
        if (item is! Map<String, dynamic>) continue;
        if ((item['type'] as String?)?.toLowerCase() != 'vless') continue;

        final uuid = item['uuid'] as String?;
        final host = item['server'] as String?;
        final port = (item['server_port'] as num?)?.toInt();
        if (uuid == null ||
            uuid.isEmpty ||
            host == null ||
            host.isEmpty ||
            port == null ||
            port == 0) {
          continue;
        }

        final tls = item['tls'] as Map<String, dynamic>?;
        final tlsEnabled = tls?['enabled'] == true;
        final reality = tls?['reality'] as Map<String, dynamic>?;
        final realityEnabled = reality?['enabled'] == true;
        final utls = tls?['utls'] as Map<String, dynamic>?;

        final transport = item['transport'] as Map<String, dynamic>?;
        String? transportHost;
        String? transportPath;
        String? xhttpMode;
        if (transport != null) {
          final headers = transport['headers'] as Map<String, dynamic>?;
          final headerHost = headers?['Host'] ?? headers?['host'];
          final transportHostList = transport['host'];
          transportHost = headerHost as String? ??
              (transportHostList is List && transportHostList.isNotEmpty
                  ? transportHostList.first as String?
                  : null);
          transportPath = transport['path'] as String? ??
              transport['service_name'] as String?;
          final mode = transport['mode'];
          if (mode is String && mode.trim().isNotEmpty) xhttpMode = mode.trim();
        }

        // security=reality без public_key нативное ядро не примет — та же
        // защита, что и в _ParsedVless.tryParse ниже для vless://-ссылок.
        final security =
            realityEnabled ? 'reality' : (tlsEnabled ? 'tls' : 'none');
        final pbk = reality?['public_key'] as String?;
        if (security == 'reality' && (pbk == null || pbk.isEmpty)) continue;

        final alpnList = tls?['alpn'];

        result.add(_ParsedVless(
          uuid: uuid,
          host: host,
          port: port,
          security: security,
          pbk: pbk,
          fp: utls?['fingerprint'] as String?,
          sni: tls?['server_name'] as String?,
          sid: reality?['short_id'] as String?,
          flow: item['flow'] as String?,
          alpn: (alpnList is List && alpnList.isNotEmpty)
              ? alpnList.join(',')
              : null,
          // splithttp — прежнее имя XHTTP; приводим к одному написанию, как
          // это делает _ParsedVless.tryParse для vless://-ссылок.
          transportType: _normalizeTransportType(
              (transport?['type'] as String?) ?? 'tcp'),
          xhttpMode: xhttpMode,
          transportHost: transportHost,
          transportPath: transportPath,
          packetEncoding: item['packet_encoding'] as String?,
          allowInsecure: tls?['insecure'] == true,
          remark: (item['tag'] as String?) ?? host,
        ));
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  Future<bool> _waitForConnected(Duration timeout) async {
    if (status.value?.state == TunnelConnState.connected) return true;
    final completer = Completer<bool>();
    VoidCallback? listener;

    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(false);
    });

    listener = () {
      // Проверка isCompleted обязательна: слушатель снимается только в finally,
      // после того как `await completer.future` вернёт управление, и в это окно
      // вполне может прилететь ещё одно изменение статуса. Второй complete()
      // бросает "Bad state: Future already completed" прямо из слушателя
      // ValueNotifier, где его никто не ловит.
      if (completer.isCompleted) return;
      if (status.value?.state == TunnelConnState.connected) {
        completer.complete(true);
      } else if (status.value?.state == TunnelConnState.disconnected) {
        completer.complete(false);
      }
    };

    status.addListener(listener);
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      status.removeListener(listener);
    }
  }

  /// Проверяет, что пакеты действительно доходят до интернета через только
  /// что поднятый туннель. Возвращает true, только если удалённый сервер
  /// реально ответил за отведённое время.
  /// Служебные адреса для проверки связи. Обычный HTTP, а не HTTPS: лишнее
  /// TLS-рукопожатие поверх уже зашифрованного VLESS добавило бы к замеру
  /// целый круговой RTT. На безопасность это не влияет — туннель шифрует всё,
  /// что через него идёт. Тот же первый адрес использует Hiddify.
  static const _probeUrls = [
    'http://cp.cloudflare.com/generate_204',
    'http://connectivitycheck.gstatic.com/generate_204',
  ];

  /// Клиент, все запросы которого идут в локальный `mixed`-инбаунд ядра
  /// (127.0.0.1:$_proxyPort). Инбаунд поднимается всегда — и в VPN-режиме
  /// тоже, см. _buildSingBoxConfig. Это соединение процесса с самим собой по
  /// петле: оно не подчиняется системной маршрутизации, не попадает в TUN и
  /// потому не спотыкается о правило Android «трафик самого VPN-приложения в
  /// свой же туннель не заворачивается». Наружу оно выходит тем же
  /// VLESS-соединением, что и весь остальной трафик.
  static IOClient _throughTunnelClient() => IOClient(
      HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$_proxyPort;');

  /// Первый из [_probeUrls], который реально ответил через туннель, либо null.
  ///
  /// Раньше в VPN-режиме проверки не было вовсе: код ждал 1.2 секунды и верил
  /// событию «интерфейс поднят». Интерфейс поднимается и при полностью
  /// нерабочем сервере, поэтому приложение показывало «ПОДКЛЮЧЕНО» с нулевым
  /// трафиком и никогда не переходило к следующей локации подписки.
  Future<Uri?> _reachableProbeUrl({required bool proxyOnly}) async {
    // В VPN-режиме окно шире: там к моменту проверки ядро ещё поднимает
    // маршруты и первые соединения идут медленнее.
    final timeout = Duration(seconds: proxyOnly ? 8 : 12);
    // Адреса проверяются одновременно, а не по очереди: последовательный
    // перебор означал, что один недоступный адрес стоит целого таймаута, и
    // проверка честного сервера растягивалась на десяток секунд. Побеждает
    // первый ответивший.
    final completer = Completer<Uri?>();
    var pending = _probeUrls.length;
    for (final probe in _probeUrls) {
      final uri = Uri.parse(probe);
      final client = _throughTunnelClient();
      unawaited(client
          .head(uri)
          .timeout(timeout)
          .then((response) {
            if (response.statusCode > 0 && !completer.isCompleted) {
              completer.complete(uri);
            }
          })
          .catchError((_) {})
          .whenComplete(() {
            client.close();
            pending--;
            if (pending == 0 && !completer.isCompleted) {
              completer.complete(null);
            }
          }));
    }
    return completer.future;
  }

  Future<bool> _verifyInternetReachable({required bool proxyOnly}) async =>
      await _reachableProbeUrl(proxyOnly: proxyOnly) != null;

  /// Задержка через туннель в миллисекундах — то же число, что показывает
  /// Hiddify.
  ///
  /// Меряется не первый запрос, а последующие: первый оплачивает
  /// VLESS/Reality-рукопожатие и TCP-соединение до сервера, и это стабильно
  /// в разы больше настоящей задержки (отсюда и брались «650 мс» там, где на
  /// самом деле 75). Соединение переиспользуется — HttpClient держит его
  /// живым, — поэтому второй и третий запросы это чистый круговой путь
  /// «телефон → сервер → сайт → обратно». Из них берётся минимум: он меньше
  /// всех подвержен случайной задержке в сети.
  Future<int?> _measureWarmDelayMs(Uri probe,
      {int samples = 3,
      Duration timeout = const Duration(seconds: 6)}) async {
    final client = _throughTunnelClient();
    try {
      // Прогрев: рукопожатие и установка соединения, время не учитываем.
      try {
        await client.head(probe).timeout(timeout);
      } catch (_) {
        return null;
      }
      int? best;
      for (var i = 0; i < samples; i++) {
        final sw = Stopwatch()..start();
        try {
          await client.head(probe).timeout(timeout);
        } catch (_) {
          continue;
        }
        sw.stop();
        final ms = sw.elapsedMilliseconds;
        if (best == null || ms < best) best = ms;
      }
      return best;
    } finally {
      client.close();
    }
  }

  Future<void> disconnect() async {
    // Сначала честно пробуем инициализироваться. Тихий выход по
    // `if (!_initialized) return;` означал бы, что кнопка "Отключить" не делает
    // ничего: если при холодном старте _ensureInitialized() отвалился (канал не
    // готов, плагин не ответил), флаг остаётся false, а foreground VpnService
    // продолжает работать — значок VPN в шторке есть, выключить его из
    // приложения нельзя. `_disconnectNative()` ниже и так обёрнут в try/catch с
    // таймаутом, а finally в любом случае опубликует "отключено".
    if (!_initialized) {
      try {
        await _ensureInitialized();
      } catch (_) {
        // Инициализация не удалась — всё равно доходим до конца метода,
        // чтобы сбросить состояние в UI.
      }
    }
    _userInitiatedDisconnect = true;
    _autoReconnectAttempt = 0;
    killSwitchBlocking.value = false;
    _restartDurationTicker(false);
    // Соединение для замера задержки прогрето под текущий сеанс туннеля: при
    // отключении его нужно закрыть, иначе следующее подключение (возможно, к
    // другому серверу) первое время переиспользовало бы канал к уже
    // неактуальному proxy-сеансу.
    _closeDelayProbeClient();
    // Если активна служебная блокирующая сессия строгого Kill Switch — снимаем
    // именно её. _disengageHardKillSwitch сама проверяет флаг и ничего не
    // делает, если сессии нет.
    if (_hardKillSwitchEngaged) {
      // try/catch не даёт ни одному пути disconnect() вылететь наружу
      // необработанным: исключение отсюда ушло бы прямо в
      // connect_screen.dart::_toggleConnection() и навсегда заблокировало кнопку
      // "Отключить".
      try {
        await _disengageHardKillSwitch();
      } catch (e) {
        lastError.value = 'Отключение не удалось: $e';
      }
      connectedServerName.value = null;
      localProxyAddress.value = null;
      // Обнуляем строго здесь, а не в начале метода, чтобы не было окна, где
      // туннеля для switchPreferredHost() формально уже нет, а status ещё
      // "connected".
      _sessionOutboundOrder = const <_ParsedVless>[];
      _lastConnectionString = null;
      _lastPreferredHostName = null;
      _connectStartedAt = null;
      // Явное действие пользователя — стираем сразу, без паузы из
      // _schedulePersistedStartWipe().
      _cancelPersistedStartWipe();
      _persistConnectStart(null);
      _clearPersistedSessionRoute();
      // Публичный status в этой ветке нужно выставить вручную: событие
      // "disconnected" от служебной блокирующей сессии проглатывается guard'ом в
      // _applyServiceState(), пока `_hardKillSwitchEngaged == true`, а к моменту
      // снятия флага событие уже прошло — экран после "Отключить" при активной
      // строгой блокировке остался бы в "ПОДКЛЮЧЕНО".
      status.value = const TunnelStatus(
        state: TunnelConnState.disconnected,
        duration: 0,
        download: 0,
        upload: 0,
        downloadTotalBytes: 0,
        uploadTotalBytes: 0,
      );
      return;
    }
    try {
      await _disconnectNative();
    } catch (e) {
      lastError.value = 'Отключение не удалось: $e';
    } finally {
      connectedServerName.value = null;
      localProxyAddress.value = null;
      // `_lastConnectionString` обнуляется ровно в той же точке, что и публичный
      // статус. Обнуляя его в первой строке disconnect(), мы получали окно, где
      // `isConnected` ещё true (status меняется только здесь, после await), а
      // строки подписки уже нет: на Windows этот await не мгновенный —
      // TerminateProcess, ожидание exitCode до 2 секунд и резервный taskkill.
      // Попав в это окно, смена сервера уходила в switchPreferredHost() и
      // получала "Нет активного туннеля" на экране, показывающем "ПОДКЛЮЧЕНО".
      //
      // При смене сервера этот disconnect — середина операции, а не её конец:
      // строка подписки нужна следующим же действием, чтобы подняться на другой
      // стране, а при неудаче — чтобы вернуться на прежнюю. Обнулив её здесь, мы
      // лишили бы себя отката, а Kill Switch остался бы без данных для
      // переподключения.
      if (!_switchInProgress) {
        _sessionOutboundOrder = const <_ParsedVless>[];
        _lastConnectionString = null;
        _lastPreferredHostName = null;
        _connectStartedAt = null;
        // Сессия завершена по воле пользователя — стираем и сохранённое на диске,
        // иначе следующий холодный старт восстановит отметку времени и маршрут
        // несуществующей сессии. Без паузы: намерение однозначно.
        _cancelPersistedStartWipe();
        _persistConnectStart(null);
        _clearPersistedSessionRoute();
      }
      // Этот `status.value` пишется напрямую, минуя _applyServiceState(), —
      // значит подмена состояния при смене сервера, сделанная там, сюда не
      // доходит. Публикуем "подключение" и сохраняем накопленные счётчики:
      // сессия для пользователя продолжается.
      if (_switchInProgress) {
        final carried = status.value;
        status.value = TunnelStatus(
          state: TunnelConnState.connecting,
          duration: carried?.duration ?? 0,
          download: 0,
          upload: 0,
          downloadTotalBytes: _downloadTotalBytes,
          uploadTotalBytes: _uploadTotalBytes,
        );
        return;
      }
      _restartDurationTicker(false);
      status.value = const TunnelStatus(
        state: TunnelConnState.disconnected,
        duration: 0,
        download: 0,
        upload: 0,
        downloadTotalBytes: 0,
        uploadTotalBytes: 0,
      );
    }
  }

  Future<void> openSystemVpnSettingsHint() async {
    await AppSettings.openAppSettings(type: AppSettingsType.vpn);
  }

  /// Проверка ключа или подписки без подключения — кнопка "Проверить ключ"
  /// на экране "Мои ключи". Скачивает и разбирает подписку тем же кодом, что
  /// и connect() (`_loadProfiles`/`_parseSubscriptionBody`: base64, голые
  /// vless://-ссылки, JSON-конфиг sing-box), и возвращает, сколько рабочих
  /// серверов нашлось и под какими именами — не поднимая туннель.
  Future<SubscriptionCheckResult> checkSubscription(
      String connectionString) async {
    try {
      final profiles =
          await _loadProfiles(connectionString, forceRefresh: true);
      String nameOf(_ParsedVless p) => p.remark.isNotEmpty ? p.remark : p.host;
      // Локации с транспортом, которого ядро не знает, в список рабочих не
      // попадают: подключиться к ним всё равно не получится, и показывать их
      // зелёной галочкой было бы обманом.
      final supported = <String>[];
      final unsupported = <String>[];
      for (final p in profiles) {
        if (await _isProfileSupported(p)) {
          supported.add(nameOf(p));
        } else {
          unsupported.add('${nameOf(p)} (${p.transportType})');
        }
      }
      return SubscriptionCheckResult(
        ok: true,
        serverNames: supported,
        unsupportedServerNames: unsupported,
      );
    } on TunnelException catch (e) {
      return SubscriptionCheckResult(ok: false, error: e.message);
    } catch (e) {
      return SubscriptionCheckResult(
          ok: false, error: 'Не удалось проверить ключ: $e');
    }
  }

  /// Задержка через туннель: секундомер вокруг запроса-пробника, идущего
  /// через локальный SOCKS/HTTP-инбаунд ядра на 127.0.0.1:$_proxyPort (тот же
  /// принцип, что в `_verifyInternetReachable(proxyOnly: true)`). Такой запрос
  /// уходит не в TUN, а прямо в процесс sing-box и оттуда наружу через
  /// реальное VLESS-соединение, поэтому время ответа отражает задержку самого
  /// туннеля. Сырой Socket.connect() до IP сервера мерил бы прямой пинг
  /// телефона мимо VLESS: Android исключает трафик приложения из своего TUN
  /// (см. `_verifyInternetReachable`).
  ///
  /// Работает в обоих режимах — локальный порт поднимается и в VPN-режиме, и
  /// в proxy-only (см. _buildSingBoxConfig).
  ///
  /// HttpClient для замера один на всё время жизни соединения (лениво
  /// создаётся в `_delayProbeClient`). Новый клиент на каждый тик оплачивал
  /// бы полный холодный путь: TCP до локального инбаунда, TCP+TLS ядра с
  /// VLESS-сервером и ещё одно клиентское TLS поверх туннеля — фактически
  /// два последовательных рукопожатия каждые 15 секунд. С keep-alive полную
  /// цену платит только первый замер после подключения.
  ///
  /// Закрывается и обнуляется в disconnect()/dispose(), иначе после смены
  /// сервера продолжал бы держать соединение к неактуальному proxy-сеансу.
  HttpClient? _delayProbeClient;

  HttpClient _ensureDelayProbeClient() {
    return _delayProbeClient ??= HttpClient()
      ..idleTimeout = const Duration(seconds: 30)
      ..findProxy = (_) => 'PROXY 127.0.0.1:$_proxyPort;';
  }

  void _closeDelayProbeClient() {
    _delayProbeClient?.close(force: true);
    _delayProbeClient = null;
  }

  Future<int?> connectedDelayMs() async {
    if (!isConnected) return null;

    // generate_204 рассчитан на обычный HTTP — см. комментарий у первого
    // использования этого эндпоинта в _verifyInternetReachable(); лишний
    // TLS-хендшейк поверх туннеля завышает показания.
    final probeUri = Uri.parse('http://cp.cloudflare.com/generate_204');
    final client = IOClient(_ensureDelayProbeClient());
    final stopwatch = Stopwatch()..start();
    try {
      final response =
          await client.head(probeUri).timeout(const Duration(seconds: 5));
      stopwatch.stop();
      if (response.statusCode <= 0) return null;
      return stopwatch.elapsedMilliseconds.clamp(1, 9999);
    } catch (_) {
      // Прогретое соединение могло протухнуть (сервер закрыл keep-alive, сменился
      // маршрут) — на следующий тик заведём новый клиент, а не будем биться в
      // мёртвое соединение.
      _closeDelayProbeClient();
      return null;
    }
  }

  Future<void> dispose() async {
    _restartDurationTicker(false);
    _cancelPersistedStartWipe();
    _closeDelayProbeClient();
    latencyByRemark.dispose();
    await _stateSub?.cancel();
    await _statsSub?.cancel();
    await _faultSub?.cancel();
    await _coreLogSub?.cancel();
    _stateSub = null;
    _statsSub = null;
    _faultSub = null;
    _coreLogSub = null;
    // Подписки сняты — значит клиент больше не инициализирован в том смысле, в
    // каком это понимает `_ensureInitialized()`. Без сброса полей повторный
    // вызов после dispose() увидел бы `_initialized == true` и не подписался бы
    // заново: туннель работал бы вслепую, без единого события состояния.
    _initialized = false;
    _initializing = null;
  }
}

/// Результат `TunnelService.checkSubscription()`. Списки заполнены только
/// когда `ok == true`: `serverNames` — локации, к которым ядро реально может
/// подключиться, `unsupportedServerNames` — те, чей транспорт оно не знает
/// (сегодня это XHTTP), с указанием транспорта в скобках.
class SubscriptionCheckResult {
  SubscriptionCheckResult({
    required this.ok,
    this.serverNames = const [],
    this.unsupportedServerNames = const [],
    this.error,
  });
  final bool ok;
  final List<String> serverNames;
  final List<String> unsupportedServerNames;
  final String? error;
  int get serverCount => serverNames.length;
}

/// Результат `TunnelService.realCheckProfile()`. `latencyMs` заполнен,
/// только когда `ok == true`, и включает полное время реального
/// VLESS/Reality-рукопожатия и проверочного HTTP-запроса — с обычным
/// `_livePing` на ServersScreen эти цифры напрямую не сравнимы.
class RealCheckResult {
  const RealCheckResult({required this.ok, this.latencyMs, this.error});
  final bool ok;
  final int? latencyMs;
  final String? error;
}

enum TunnelConnState { disconnected, connecting, connected, disconnecting }

class TunnelStatus {
  const TunnelStatus({
    required this.state,
    required this.duration,
    required this.download,
    required this.upload,
    this.downloadTotalBytes = 0,
    this.uploadTotalBytes = 0,
  });

  final TunnelConnState state;
  final int duration;
  final num download;
  final num upload;
  final int downloadTotalBytes;
  final int uploadTotalBytes;
}

class _ParsedVless {
  _ParsedVless({
    required this.uuid,
    required this.host,
    required this.port,
    required this.security,
    this.pbk,
    this.fp,
    this.sni,
    this.sid,
    this.flow,
    this.spx,
    this.alpn,
    this.transportType,
    this.xhttpMode,
    this.xhttpExtra,
    this.transportHost,
    this.transportPath,
    this.packetEncoding,
    this.allowInsecure = false,
    required this.remark,
  });

  final String uuid;
  final String host;
  final int port;
  final String security; // reality | tls | none
  final String? pbk; // Публичный ключ для Reality
  final String? fp; // TLS-отпечаток
  final String? sni; // Server Name Indication
  final String? sid; // Short ID для Reality
  final String? flow; // Тип потока (xtls-rprx-vision и т.д.)
  final String? spx; // SpiderX (путь для Reality)
  final String? alpn; // ALPN, через запятую
  final String?
      transportType; // tcp | ws | grpc | http | httpupgrade | xhttp
  /// Режим XHTTP из параметра `mode` ссылки. null — не задан.
  final String? xhttpMode;

  /// Содержимое параметра `extra` из XHTTP-ссылки — тот же JSON, что Xray
  /// кладёт в `streamSettings.xhttpSettings.extra`: заголовки, параметры
  /// паддинга и режима, а также `downloadSettings` для раздельного канала
  /// скачивания. null, если параметра нет или он не разобрался.
  final Map<String, dynamic>? xhttpExtra;
  final String? transportHost; // Host-заголовок для ws/http-маскировки
  final String? transportPath; // path для ws / service_name-путь для grpc

  /// Упаковка UDP внутри VLESS из параметра `packetEncoding`. null — не
  /// задано, тогда подставляется `xudp` (так же поступает Hiddify).
  final String? packetEncoding;

  /// `allowInsecure`/`insecure` из ссылки — не проверять сертификат сервера.
  /// Встречается у ключей с самоподписанным сертификатом.
  final bool allowInsecure;
  final String remark; // Имя сервера

  /// «Да» в понимании панелей — и `1`, и `true`.
  static bool _isTruthy(String? value) {
    final v = value?.trim().toLowerCase();
    return v == '1' || v == 'true';
  }

  static _ParsedVless? tryParse(String line) {
    try {
      final uri = Uri.parse(line);
      if (uri.scheme != 'vless') return null;

      final uuid = uri.userInfo;
      final host = uri.host;
      final port = uri.port;
      if (uuid.isEmpty || host.isEmpty || port == 0) return null;

      final q = uri.queryParameters;
      // Uri.decodeComponent бросает FormatException, если в имени сервера после
      // # встречается одиночный "%", не начинающий валидную %XX-последовательность
      // — так бывает в подписках, где имя не было корректно percent-encoded.
      // Декодируем безопасно: не получилось — берём фрагмент как есть.
      String remark = host;
      if (uri.fragment.isNotEmpty) {
        try {
          remark = Uri.decodeComponent(uri.fragment);
        } catch (_) {
          remark = uri.fragment;
        }
      }

      // Сеть Xray-совместимые клиенты кладут в `type` (в ссылках, пришедших из
      // vmess-конфигов, — в `net`), а вид маскировки поверх голого TCP — в
      // `headerType`.
      final rawType = (q['type'] ?? q['net'] ?? 'tcp');
      var normalizedTransport = TunnelService._normalizeTransportType(rawType);
      final headerType =
          (q['headerType'] ?? q['headertype'] ?? '').trim().toLowerCase();
      // `type=tcp&headerType=http` — это HTTP-маскировка поверх TCP; в
      // sing-box ей соответствует транспорт `http`. Без этой ветки блок
      // transport не добавлялся вовсе, и сервер отвергал рукопожатие.
      if (normalizedTransport == 'tcp' && headerType == 'http') {
        normalizedTransport = 'http';
      }
      // Режим XHTTP: auto | packet-up | stream-up | stream-one, в ссылке лежит в
      // параметре `mode`. Пустое значение оставляем пустым — ядро подставит своё
      // умолчание само.
      final xhttpMode = (q['mode'] ?? '').trim();
      // `extra` — JSON-объект в формате Xray. В ссылке он обычно
      // percent-encoded, Uri.queryParameters это уже раскодировал.
      Map<String, dynamic>? xhttpExtra;
      final rawExtra = q['extra'];
      if (rawExtra != null && rawExtra.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(rawExtra);
          if (decoded is Map<String, dynamic>) xhttpExtra = decoded;
        } catch (_) {
          // Битый JSON в extra не повод терять весь профиль: подключимся по
          // host/path из самой ссылки.
        }
      }

      // security=reality без поля pbk (публичный ключ) в конфиг отдавать нельзя:
      // получив reality-блок без ключа, нативное ядро падает на уровне Kotlin/JNI,
      // минуя Dart-исключения — со стороны это выглядит как вылет приложения без
      // ошибки в интерфейсе. Такой профиль просто не парсится, и connect()
      // переходит к следующему серверу.
      final security = (q['security'] ?? 'none').toLowerCase();
      final pbkValue = q['pbk'];
      if (security == 'reality' && (pbkValue == null || pbkValue.isEmpty))
        return null;

      return _ParsedVless(
        uuid: uuid,
        host: host,
        port: port,
        security: security,
        pbk: pbkValue,
        fp: q['fp'],
        sni: q['sni'],
        sid: q['sid'],
        flow: q['flow'],
        spx: q['spx'],
        alpn: q['alpn'],
        transportType: normalizedTransport,
        xhttpMode: xhttpMode.isEmpty ? null : xhttpMode,
        xhttpExtra: xhttpExtra,
        transportHost: q['host'],
        transportPath: q['path'] ?? q['serviceName'],
        packetEncoding: (q['packetEncoding'] ?? q['packetencoding'])?.trim(),
        allowInsecure: _isTruthy(q['allowInsecure']) ||
            _isTruthy(q['allowinsecure']) ||
            _isTruthy(q['insecure']),
        remark: remark,
      );
    } catch (_) {
      return null;
    }
  }
}

class TunnelException implements Exception {
  TunnelException(this.message);
  final String message;
  @override
  String toString() => message;
}
/// Путь ws/httpupgrade, из которого вынесен параметр ранних данных.
class _WsPath {
  const _WsPath(this.path, this.maxEarlyData);
  final String path;
  final int maxEarlyData;
}
