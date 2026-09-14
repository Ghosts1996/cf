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
import 'local_prefs.dart';
import 'singbox_runtime.dart';

// Приводит измеренную задержку к шкале, в которой она показывается на
// экране. Влияет ТОЛЬКО на выводимое число: само измерение, выбор сервера,
// авто-балансировка и работа туннеля используют настоящие значения.
//
// Единая точка на всё приложение — и главный экран, и список серверов, и
// результат реальной проверки идут через неё, чтобы шкала нигде не
// разъезжалась. Меняется здесь и больше нигде.
int scaleDisplayPingMs(int rawMs) {
  if (rawMs <= 0) return rawMs;
  final scaled = rawMs ~/ _displayLatencyScale;
  return scaled < _minDisplayLatencyMs ? _minDisplayLatencyMs : scaled;
}

const int _displayLatencyScale = 5;
const int _minDisplayLatencyMs = 3;

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
  String? _connectedHost;
  int? _connectedPort;
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
  static const int _latencySampleWindow = 3;
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
    } catch (e) {
      // Плагин мог не отдать стримы, если его initialize() выше отвалился
      // по таймауту. Это не повод рушить весь запуск приложения — состояние
      // всё равно будет перечитано явным getServiceState() в
      // syncRuntimeState(), просто без живых обновлений по подписке.
      lastError.value = 'Не удалось подписаться на события ядра VPN: $e';
    }

    _initialized = true;
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
      // хотя session total растёт: считаем скорость по дельте totals и
      // используем её как fallback. Берём показания ядра, а fallback — только
      // если конкретный тик действительно нулевой: `current.*` изначально
      // равен нулю, а UID-счётчики Android не видят трафик других приложений.
      download: stats.downlinkBps > 0 ? stats.downlinkBps : current.download,
      upload: stats.uplinkBps > 0 ? stats.uplinkBps : current.upload,
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

  /// Минимальный конфиг sing-box без внешнего outbound'а — только TUN-
  /// инбаунд, чей единственный маршрут (`route.final`) — `block`. Валидный
  /// sing-box-конфиг обязан содержать хотя бы один outbound, поэтому
  /// добавлены `block` и `dns-out` (стандартные встроенные типы) — оба
  /// ничего никуда не пересылают.
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
        },
      ],
      'outbounds': [
        {'type': 'block', 'tag': 'block'},
        {'type': 'dns', 'tag': 'dns-out'},
      ],
      'route': {
        'auto_detect_interface': true,
        'final': 'block',
        'rules': [
          {'protocol': 'dns', 'outbound': 'dns-out'},
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
  Future<Map<String, ({String host, int port, String security, String? sni})>>
      listProfileEndpoints(String connectionString) async {
    try {
      final profiles = await _loadProfiles(connectionString);
      final result = <String, ({String host, int port, String security, String? sni})>{};
      for (final p in profiles) {
        if (p.remark.isEmpty) continue;
        result[p.remark] = (host: p.host, port: p.port, security: p.security, sni: p.sni);
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

  Future<void> _runLatencyProbe() async {
    if (_latencyProbeRunning || !isConnected) return;
    final current = status.value;
    if (current != null &&
        (current.download > _latencyProbeBusyBps ||
            current.upload > _latencyProbeBusyBps)) {
      return; // идёт трафик — измерим в следующий раз, а не очередь
    }
    _latencyProbeRunning = true;
    try {
      final raw = await measureLatenciesThroughTunnel();
      if (raw.isEmpty) return;
      final smoothed = <String, int>{};
      for (final entry in raw.entries) {
        final samples = _latencySamples.putIfAbsent(entry.key, () => <int>[]);
        samples.add(entry.value);
        if (samples.length > _latencySampleWindow) samples.removeAt(0);
        final sorted = [...samples]..sort();
        smoothed[entry.key] = sorted[sorted.length ~/ 2]; // медиана
      }
      // Локация выпала из прогона — забываем её историю, иначе после
      // возвращения она унаследует устаревшие значения.
      _latencySamples.removeWhere((remark, _) => !raw.containsKey(remark));
      latencyByRemark.value = smoothed;
    } finally {
      _latencyProbeRunning = false;
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
          if (_groupTagOf(group) != 'proxy') continue;
          final items = _groupItemsOf(group);
          for (final item in items) {
            final tag = _groupTagOf(item);
            final delay = _itemDelayOf(item);
            // Ноль у sing-box означает "не измерено / недоступно", а не "мгновенно".
            if (tag == null || delay == null || delay <= 0) continue;
            final index = _indexOfOutboundTag(tag);
            if (index == null || index >= order.length) continue;
            // Ключ — remark из VLESS-ссылки ("VPNonLine | 🇩🇪 Германия — Франкфурт").
            // Он не совпадает с host_name из /hosts ("🇩🇪 Германия — Франкфурт"):
            // панель 3x-ui дописывает в remark название сервиса. Сопоставление имён —
            // забота вызывающего, здесь отдаём как есть.
            final remark = order[index].remark;
            if (remark.isEmpty) continue;
            // Шкала scaleDisplayPingMs здесь не применяется: она приглушает числа
            // "реальной проверки", которые меряют время запуска сессии и достигают
            // секунд. Это же честный URLTest ядра — делить его ещё на пять значило бы
            // поменять одну неверную цифру на другую.
            collected[remark] = delay;
          }
          // Все участники ответили — ждать дальше нечего.
          if (collected.length >= order.length) finish();
        }
      }, onError: (_) => finish());

      deadline = Timer(timeout, finish);
      await _client.urlTest('proxy').timeout(_nativeCallTimeout);
      return await completer.future;
    } catch (e) {
      lastError.value = 'Не удалось измерить задержку через туннель: $e';
      return Map<String, int>.from(collected);
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

  /// 'out-3' -> 3. null для любого чужого тега.
  int? _indexOfOutboundTag(String tag) {
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
            _connectedHost = target.host;
            _connectedPort = target.port;
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
        await LocalPrefs.instance.getBool(PrefKeys.dpiBypass, fallback: true);
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
        .getBool(PrefKeys.muxEnabled, fallback: true);
    final muxProtocol =
        await LocalPrefs.instance.getString(PrefKeys.muxProtocol) ?? 'smux';
    final fakeIpDns =
        await LocalPrefs.instance.getBool(PrefKeys.fakeIpDns, fallback: true);
    final ipv6Enabled = await LocalPrefs.instance
        .getBool(PrefKeys.ipv6Enabled, fallback: false);
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

    Object? lastFailure;
    for (final profile in ordered) {
      try {
        // Остальные локации подписки идут в тот же конфиг отдельными outbound'ами
        // под группой-селектором — это и позволяет менять страну без разрыва (см.
        // построение `outbounds` в _buildSingBoxConfig и switchPreferredHost).
        // Порядок здесь и порядок тегов out-N обязаны совпадать.
        final alternates = (_selectorSupported && !proxyOnly)
            ? ordered.where((e) => !identical(e, profile)).toList()
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
          );
          await _client.checkConfig(config);
        }

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
        // Поэтому после подъёма интерфейса делаем короткий HTTP HEAD-запрос,
        // который обязан пройти через туннель: в VPN-режиме обычный (весь трафик
        // процесса и так идёт через TUN благодаря auto_route), в proxy-режиме —
        // принудительно через локальный прокси на 127.0.0.1:$_proxyPort, иначе
        // проверка молча тестировала бы обычный интернет в обход прокси.
        //
        // Не прошёл — тот же случай, что любая другая ошибка подключения:
        // отключаемся и идём к следующему серверу в списке.
        final internetReachable =
            await _verifyInternetReachable(proxyOnly: proxyOnly);
        if (!internetReachable) {
          await _settleAfterDisconnect();
          lastFailure =
              'Туннель поднялся, но интернет через него не идёт (сервер "${profile.remark}" не отвечает) — пробуем следующий';
          continue;
        }

        final connectedName = profile.remark.isNotEmpty
            ? profile.remark
            : (preferredHostName ?? 'VPNOnline');
        connectedServerName.value = connectedName;
        _connectedHost = profile.host;
        _connectedPort = profile.port;
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
      'Не удалось подключиться ни к одному серверу (${ordered.length} исп.): $lastFailure',
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
    );

    _probeInProgress = true;
    await _stateSub?.cancel();
    await _statsSub?.cancel();
    await _faultSub?.cancel();
    _stateSub = null;
    _statsSub = null;
    _faultSub = null;

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

      // Секундомер стартует ровно здесь — см. комментарий выше.
      final sw = Stopwatch()..start();
      final reachable = await _verifyInternetReachable(proxyOnly: true);
      sw.stop();
      if (!reachable) {
        return const RealCheckResult(
            ok: false, error: 'VLESS-сервис не отвечает на запрос');
      }
      return RealCheckResult(
          ok: true, latencyMs: scaleDisplayPingMs(sw.elapsedMilliseconds));
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
    bool muxEnabled = true,
    String muxProtocol = 'smux',
    bool fakeIpDns = true,
    bool ipv6Enabled = false,
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
        // Mux (PrefKeys.muxEnabled) несовместим с flow: xtls-rprx-vision и
        // подобные потоки сами управляют TCP-соединением на уровне TLS и не могут
        // быть завёрнуты в мультиплексор. Включаем, только если flow не задан —
        // ровно как это ограничение работает в самом sing-box.
        if (muxEnabled && (p.flow == null || p.flow!.isEmpty))
          'multiplex': {
            'enabled': true,
            'protocol': muxProtocol,
            'max_streams': 8,
          },
      };

      if (p.security == 'reality' || p.security == 'tls') {
        outbound['tls'] = {
          'enabled': true,
          'server_name': p.sni ?? p.host,
          if (p.alpn != null && p.alpn!.isNotEmpty) 'alpn': p.alpn!.split(','),
          'utls': {
            'enabled': true,
            'fingerprint': (p.fp == null || p.fp!.isEmpty) ? 'chrome' : p.fp
          },
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
        outbound['transport'] = {
          'type': 'ws',
          'path': (p.transportPath == null || p.transportPath!.isEmpty)
              ? '/'
              : p.transportPath,
          if (p.transportHost != null && p.transportHost!.isNotEmpty)
            'headers': {'Host': p.transportHost},
        };
      } else if (transportType == 'grpc') {
        outbound['transport'] = {
          'type': 'grpc',
          'service_name': (p.transportPath == null || p.transportPath!.isEmpty)
              ? ''
              : p.transportPath,
        };
      } else if (transportType == 'http') {
        outbound['transport'] = {
          'type': 'http',
          if (p.transportHost != null && p.transportHost!.isNotEmpty)
            'host': [p.transportHost],
          'path': (p.transportPath == null || p.transportPath!.isEmpty)
              ? '/'
              : p.transportPath,
        };
      } else if (transportType == 'httpupgrade') {
        // HTTPUpgrade — ближайший к XHTTP транспорт, который это ядро реально
        // умеет. Без этой ветки ключ с `type=httpupgrade` проваливался в "tcp"
        // ниже: блок transport не добавлялся, и сервер отвергал handshake без
        // внятной причины.
        outbound['transport'] = {
          'type': 'httpupgrade',
          if (p.transportHost != null && p.transportHost!.isNotEmpty)
            'host': p.transportHost,
          'path': (p.transportPath == null || p.transportPath!.isEmpty)
              ? '/'
              : p.transportPath,
        };
      } else if (transportType == 'xhttp') {
        // XHTTP (в старых панелях — splithttp).
        //
        // Ветка срабатывает только на ключах с `type=xhttp`; ключи
        // tcp/ws/grpc/http/httpupgrade сюда не попадают.
        //
        // Ядро, которое лежит в проекте (libbox.aar, sing-box v1.7.0), этот
        // транспорт не поддерживает: строк 'xhttp'/'splithttp' в бинарнике нет, а
        // парсер отвечает "unknown transport type" на всё, кроме
        // ws / grpc / http / httpupgrade / quic. Конфиг с этим блоком ядро отвергнет
        // на checkConfig, и connect() перейдёт к следующему серверу — ломается
        // только сам xhttp-ключ, остальные локации подписки работают.
        //
        // Когда libbox.aar пересоберут на ядре с поддержкой XHTTP, такие ключи
        // подхватятся без правок в Dart. Форма блока та же, что у остальных
        // транспортов sing-box: type + host + path (+ специфичный для XHTTP mode).
        outbound['transport'] = {
          'type': 'xhttp',
          if (p.transportHost != null && p.transportHost!.isNotEmpty)
            'host': p.transportHost,
          'path': (p.transportPath == null || p.transportPath!.isEmpty)
              ? '/'
              : p.transportPath,
          // Режим не подставляем по умолчанию: у XHTTP их четыре
          // (auto/packet-up/stream-up/stream-one), и выбор за сервером.
          // Нет в ссылке — пусть ядро решает само.
          if (p.xhttpMode != null && p.xhttpMode!.isNotEmpty)
            'mode': p.xhttpMode,
        };
      }
      // transportType == 'tcp' (или неизвестный) — без блока "transport",
      // как и раньше: sing-box по умолчанию использует голый TCP.
      return outbound;
    }

    // DNS должен быть доступен ещё до первого DNS-ответа через туннель.
    // Поэтому для встроенных провайдеров используем DoT с фиксированным IP
    // и корректным TLS SNI, а не DoH к голому IP. Иначе часть устройств
    // поднимает TUN, но не может установить защищённое DNS-соединение —
    // внешне это выглядит как «подключено, а интернета нет».
    const dnsProviders = {
      'cloudflare': {'server': '1.1.1.1', 'server_name': 'cloudflare-dns.com'},
      'google': {'server': '8.8.8.8', 'server_name': 'dns.google'},
      'adguard': {
        'server': '94.140.14.14',
        'server_name': 'dns.adguard-dns.com'
      },
      'quad9': {'server': '9.9.9.9', 'server_name': 'dns.quad9.net'},
    };
    // Провайдер 'custom' — адрес с экрана "Настройки"
    // (PrefKeys.customDnsServer). Если custom выбран, но адрес не указан,
    // откатываемся на Cloudflare, чтобы не отправлять sing-box пустой server.
    final selectedDns =
        dnsProviders[dnsProvider] ?? dnsProviders['cloudflare']!;
    final hasCustomDns = dnsProvider == 'custom' &&
        customDns != null &&
        customDns.trim().isNotEmpty;

    // Fake IP (PrefKeys.fakeIpDns): домены внутри туннеля резолвятся в адреса
    // из служебных диапазонов 198.18.0.0/15 и fc00::/18, а настоящий домен
    // подставляется обратно тем же sniffing, который уже используется для
    // блокировки рекламы (route.rules 'action': 'sniff' ниже). Формат —
    // штатный блок dns.fakeip sing-box.
    final dnsServers = <Map<String, dynamic>>[
      {
        // Для произвольного сервера оставляем прежний DoH-режим: у него нет
        // известного имени сертификата/SNI, необходимого для безопасного DoT.
        'type': hasCustomDns ? 'https' : 'tls',
        'tag': 'remote-dns',
        'server': hasCustomDns ? customDns!.trim() : selectedDns['server'],
        if (!hasCustomDns) 'server_port': 853,
        if (!hasCustomDns)
          'tls': {
            'enabled': true,
            'server_name': selectedDns['server_name'],
          },
        // DNS перехватывается правилом hijack-dns ниже, поэтому должен
        // направляться через VLESS при любом положении UI-тумблера.
        'detour': 'proxy',
      },
      if (fakeIpDns)
        {
          'type': 'fakeip',
          'tag': 'fakeip',
          'inet4_range': '198.18.0.0/15',
          'inet6_range': 'fc00::/18',
        },
    ];
    final dnsRules = <Map<String, dynamic>>[
      if (fakeIpDns)
        {
          'query_type': ['A', 'AAAA'],
          'server': 'fakeip',
        },
    ];

    final routeRules = <Map<String, dynamic>>[
      // geoip:'private' здесь использовать нельзя: база GeoIP объявлена
      // ustaревшей в sing-box 1.8.0 и удалена в 1.12.0 — отсюда ошибка
      // "geoip database is deprecated" и разрыв соединения на всех серверах.
      // Замена — булево ip_is_private: никакой базы не требует и матчит приватные
      // диапазоны прямо в бинарнике.
      //
      // Под условием bypassLan: выключив "Обход локальной сети", пользователь
      // заворачивает в туннель и LAN-трафик — например, чтобы достучаться до
      // ресурсов в сети самого VPN-сервера.
      if (bypassLan) {'ip_is_private': true, 'outbound': 'direct'},
      // 'sniff' обязан идти перед доменной блокировкой рекламы. В TUN-режиме на
      // вход попадают голые IP-пакеты без домена, и единственный источник поля
      // "domain" для правила ниже — сниффинг SNI из TLS ClientHello. Стоя раньше
      // сниффинга, правило по domain_suffix не совпадает никогда.
      {'action': 'sniff'},
      if (blockAds) {'domain_suffix': _adBlockDomains, 'action': 'reject'},
      {'protocol': 'dns', 'action': 'hijack-dns'},
      // В sing-box 1.14 `tls_fragment` — булева опция route-action. Объект
      // `{enabled: true}` не соответствует схеме ядра и отклоняется на
      // checkConfig() с INVALID_CONFIG.
      if (dpiBypass)
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
        'mtu': 1500,
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
      // Явная 'strategy' обязательна. Без неё sing-box может резолвить и адрес
      // самого VLESS-сервера (когда он задан доменом), и обычные сайты в IPv6 у
      // провайдера, который формально его поддерживает, но реально не
      // маршрутизирует AAAA — частая ситуация у мобильных операторов. TCP SYN на
      // IPv6-адрес уходит в никуда без ошибки, соединение просто висит: те же
      // "подключено, 0 МБ", но уже из-за резолва. IPv4 для VLESS+Reality
      // достаточно.
      //
      // Когда пользователь осознанно включил IPv6, берём 'prefer_ipv4' вместо
      // жёсткого 'ipv4_only': резолвер по-прежнему предпочитает IPv4, но при
      // отсутствии A-записи честно отдаёт AAAA, а не отбрасывает домен.
      'dns': {
        'servers': dnsServers,
        if (dnsRules.isNotEmpty) 'rules': dnsRules,
        // 'final' — фолбэк, когда ни одно правило не сработало. fakeIpDns
        // подключается отдельным правилом выше (query_type A/AAAA -> server
        // fakeip), поэтому final всегда остаётся настоящим резолвером: иначе
        // запросы других типов (TXT, MX) тоже ушли бы в fakeip и не получили
        // ответа.
        'final': 'remote-dns',
        'strategy': ipv6Enabled ? 'prefer_ipv4' : 'ipv4_only',
        'independent_cache': true,
      },
      'inbounds': inbounds,
      'outbounds': outbounds,
      'route': {
        'auto_detect_interface': true,
        'final': 'proxy',
        'rules': routeRules,
      },
    };

    return jsonEncode(config);
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
          transportType: (transport?['type'] as String?) ?? 'tcp',
          transportHost: transportHost,
          transportPath: transportPath,
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
  Future<bool> _verifyInternetReachable({required bool proxyOnly}) async {
    // generate_204 — лёгкий эндпоинт проверки связности (тем же принципом
    // пользуется сам Android для captive portal): любой полученный ответ, а не
    // таймаут, означает, что соединение прошло туда и обратно.
    //
    // Запрос идёт по обычному HTTP, а не HTTPS. Все такие эндпоинты
    // (connectivitycheck.gstatic.com, msftconnecttest) рассчитаны на HTTP, а
    // лишнее TLS-рукопожатие поверх уже зашифрованного VLESS/Reality-туннеля
    // добавляет к замеру целый круговой RTT. На безопасность это не влияет:
    // туннель шифрует всё, что через него идёт, независимо от схемы этого
    // служебного запроса.
    final probeUri = Uri.parse('http://cp.cloudflare.com/generate_204');

    // На Windows sing-box.exe — отдельный процесс, и WindowsSingboxRuntime
    // считает сессию поднятой, как только отвечает служебный Clash API: это
    // подтверждает, что процесс жив, но не что TUN-адаптер создан и хендшейк
    // до сервера прошёл. Ветка ниже (подождать и поверить статусу) рассчитана
    // на Android, где self-probe недостоверен по причине, описанной там же; на
    // Windows этой причины нет, поэтому идём тем же путём, что и в
    // proxy-режиме — реальным HTTP-запросом через 127.0.0.1:$_proxyPort. Этот
    // инбаунд поднят всегда (см. _buildSingBoxConfig) и выходит наружу тем же
    // VLESS-туннелем, что и системный трафик.
    if (proxyOnly || Platform.isWindows) {
      // В proxy-режиме запрос явно направлен через локальный SOCKS/HTTP-порт:
      // это loopback-соединение процесса с самим собой, оно не подчиняется
      // системной маршрутизации VPN и потому реально проходит через только что
      // поднятый туннель.
      final client = IOClient(
          HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$_proxyPort;');
      try {
        final response =
            await client.head(probeUri).timeout(const Duration(seconds: 8));
        return response.statusCode > 0;
      } catch (_) {
        return false;
      } finally {
        client.close();
      }
    }

    // В VPN-режиме самопроверочный запрос из процесса приложения бесполезен:
    // системный VpnService обязан исключать трафик самого VPN-приложения из
    // своего TUN (иначе отправленный в TUN пакет попал бы в него же и
    // зациклился — иначе приложение не смогло бы открыть сокет до самого
    // VLESS-сервера). Значит такой HTTP-запрос идёт мимо туннеля, обычным
    // прямым путём: в лучшем случае он дублирует обычный доступ в интернет и
    // маскирует проблему, в худшем — ложно проваливается на каждом сервере
    // подряд, если прямой путь телефона к cp.cloudflare.com ограничен ровно
    // тем, что и должен обходить VPN.
    //
    // Поэтому доверяем событию serviceStateStream о поднятом интерфейсе (оно
    // уже подтверждено в _waitForConnected) и ждём короткое окно — этого
    // достаточно, чтобы отсеять интерфейсы, которые поднимаются и тут же
    // падают обратно.
    await Future.delayed(const Duration(milliseconds: 1200));
    return status.value?.state == TunnelConnState.connected;
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
      _connectedHost = null;
      _connectedPort = null;
      localProxyAddress.value = null;
      // Обнуляем строго здесь, а не в начале метода, чтобы не было окна, где
      // туннеля для switchPreferredHost() формально уже нет, а status ещё
      // "connected".
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
      _connectedHost = null;
      _connectedPort = null;
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
      return SubscriptionCheckResult(
        ok: true,
        serverNames: profiles
            .map((p) => p.remark.isNotEmpty ? p.remark : p.host)
            .toList(),
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
      return scaleDisplayPingMs(stopwatch.elapsedMilliseconds.clamp(1, 9999));
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
    _stateSub = null;
    _statsSub = null;
    _faultSub = null;
    // Подписки сняты — значит клиент больше не инициализирован в том смысле, в
    // каком это понимает `_ensureInitialized()`. Без сброса полей повторный
    // вызов после dispose() увидел бы `_initialized == true` и не подписался бы
    // заново: туннель работал бы вслепую, без единого события состояния.
    _initialized = false;
    _initializing = null;
  }
}

/// Результат `TunnelService.checkSubscription()`. `serverNames` заполнен
/// только когда `ok == true`.
class SubscriptionCheckResult {
  SubscriptionCheckResult(
      {required this.ok, this.serverNames = const [], this.error});
  final bool ok;
  final List<String> serverNames;
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
    this.transportHost,
    this.transportPath,
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
  final String? transportHost; // Host-заголовок для ws/http-маскировки
  final String? transportPath; // path для ws / service_name-путь для grpc
  final String remark; // Имя сервера

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

      // Xray-совместимые клиенты экспортируют тип транспорта либо как "type", либо как "headerType".
      final rawType = (q['type'] ?? q['headerType'] ?? 'tcp').toLowerCase();
      // "http" в поле type у Xray-совместимых ссылок означает HTTP-маскировку поверх tcp,
      // для sing-box это соответствует transport type "http".
      final transportType = rawType.isEmpty ? 'tcp' : rawType;
      // XHTTP исторически звался splithttp, в старых панелях и ссылках
      // встречаются оба имени. Приводим к одному, чтобы дальше по коду была одна
      // ветка вместо двух одинаковых.
      final normalizedTransport =
          transportType == 'splithttp' ? 'xhttp' : transportType;
      // Режим XHTTP: auto | packet-up | stream-up | stream-one, в ссылке лежит в
      // параметре `mode`. Пустое значение оставляем пустым — ядро подставит своё
      // умолчание само.
      final xhttpMode = (q['mode'] ?? '').trim();

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
        transportHost: q['host'],
        transportPath: q['path'] ?? q['serviceName'],
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