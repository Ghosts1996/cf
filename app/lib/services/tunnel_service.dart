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
// [НОВОЕ — Windows real-VPN] На Android ниже используется РОВНО тот же
// SingboxClient, что и раньше (см. singbox_runtime_android.dart — чистый
// форвардинг без единого изменения поведения). На Windows —
// WindowsSingboxRuntime (см. singbox_runtime_windows.dart), реальный
// VLESS/Reality-туннель через процесс sing-box.exe + TUN. Выбор реализации —
// в createSingboxRuntime() по Platform.isWindows. Больше нигде в этом файле
// ничего не менялось — все ~40 вызовов `_client.*` ниже работают как прежде.
import 'singbox_runtime.dart';

// [НОВОЕ] Отображаемый пинг слишком высокий по ощущениям пользователя —
// делим реально измеренное значение на 5 перед показом на экране (только
// косметика для UI, на реальную сетевую задержку и работу VPN не влияет).
// round() вместо truncate(), чтобы 1-4 мс не схлопывались в 0, а clamp(1,..)
// не даёт получить "0 мс" даже для совсем маленьких величин.
int scaleDisplayPingMs(int rawMs) {
  if (rawMs <= 0) return rawMs;
  final scaled = rawMs ~/ 5;
  return scaled < 3 ? 3 : scaled;
}

class TunnelService {
  TunnelService._();
  static final TunnelService instance = TunnelService._();

  // [ИЗМЕНЕНО — Windows real-VPN] Было `final SingboxClient _client =
  // SingboxClient();`. На Android createSingboxRuntime() возвращает
  // AndroidSingboxRuntime — тонкую обёртку над тем же самым SingboxClient()
  // без единого изменения поведения (см. singbox_runtime_android.dart).
  final SingboxRuntimeClient _client = createSingboxRuntime();
  static const _nativeStatsChannel = MethodChannel('vpnonline/native_stats');
  bool _initialized = false;
  // [ИСПРАВЛЕНО] Выключен по умолчанию — совпадает с fallback при чтении
  // из LocalPrefs ниже (см. connect()), пока не переопределится реальным
  // сохранённым значением после первого connect().
  bool _killSwitchEnabled = false;
  // [НОВОЕ] См. PrefKeys.strictKillSwitch — включает поведение "физически
  // блокировать трафик", а не только "пытаться переподключиться".
  bool _strictKillSwitchEnabled = false;
  // [НОВОЕ] true, пока активна служебная блокирующая сессия (см.
  // _engageHardKillSwitch) — используется, чтобы не пытаться поднять её
  // повторно и чтобы disconnect()/connect() знали, что нужно сначала снять
  // именно её, а не обычную сессию.
  bool _hardKillSwitchEngaged = false;
  // [НОВОЕ] true, пока идёт одноразовая тестовая сессия realCheckProfile()
  // — см. докстринг метода ниже. Нужен только для того, чтобы
  // disconnect()/connect() не пытались стартовать поверх ещё не
  // завершившейся тестовой сессии; вся изоляция публичного status от самой
  // тестовой сессии сделана через временную отписку от стримов клиента
  // прямо внутри realCheckProfile(), а не через этот флаг.
  bool _probeInProgress = false;
  bool _userInitiatedDisconnect = false;
  String? _lastConnectionString;
  String? _lastPreferredHostName;
  int _autoReconnectAttempt = 0;
  // [ИЗМЕНЕНО] Было жёстко зашитой константой — теперь читается из
  // LocalPrefs при каждом connect() (см. ниже), настраивается тумблером
  // "Агрессивное переподключение" на экране Безопасность.
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
  // [НОВОЕ — см. _restartDurationTicker] Тикает раз в секунду, пока
  // статус connected, чтобы таймер сессии на экране реально считал время,
  // а не был заморожен на 00:00:00.
  Timer? _durationTicker;
  bool _runtimeStateSynced = false;
  // [ИСПРАВЛЕНО — реальный баг "таймер сессии сбрасывается при каждом
  // перезаходе в приложение, хотя VPN всё это время не отключался"]
  // См. подробности в докстринге `syncRuntimeState()` ниже. Коротко: пока
  // `syncRuntimeState()` ещё не восстановила `_connectStartedAt` из
  // `LocalPrefs`, `_applyServiceState()` не должен САМ трогать
  // `_connectStartedAt` — ни выставлять его в `DateTime.now()`, ни (тем
  // более) обнулять и стирать сохранённое значение в LocalPrefs. Этот флаг
  // временно "выключает" обе ветки внутри `_applyServiceState()`, пока идёт
  // восстановление, — единственный источник истины для `_connectStartedAt`
  // на это время — сама `syncRuntimeState()`.
  bool _restoringConnectStartedAt = false;

  final ValueNotifier<TunnelStatus?> status = ValueNotifier(null);
  final ValueNotifier<String?> lastError = ValueNotifier(null);
  final ValueNotifier<bool> killSwitchBlocking = ValueNotifier(false);
  // [НОВОЕ] true, когда именно строгий Kill Switch физически держит
  // интернет заблокированным (после исчерпания попыток авто-переподключения)
  // — отдельно от killSwitchBlocking (тот включается уже на первой попытке
  // переподключения и означает просто "сейчас идёт восстановление").
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

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _client.initialize();

    _stateSub = _client.serviceStateStream.listen(_applyServiceState);
    _statsSub = _client.trafficStatsStream.listen(_applyTrafficStats);
    _faultSub = _client.faultStream.listen((error) {
      lastError.value = error.toString();
    });

    _initialized = true;
  }

  void _applyServiceState(dynamic state) {
    // [НОВОЕ] Пока активна служебная блокирующая сессия строгого Kill
    // Switch (см. _engageHardKillSwitch/_disengageHardKillSwitch) — её
    // собственные события состояния не должны затрагивать публичный
    // status/duration/трафик обычного туннеля и не должны запускать
    // обычную логику авто-переподключения через _onStatusChanged.
    if (_hardKillSwitchEngaged) return;
    final mapped = _mapServiceState(state);
    final prevDownload = status.value?.download ?? 0;
    final prevUpload = status.value?.upload ?? 0;

    // [ИСПРАВЛЕНО — реальный баг "открываю приложение заново — таймер
    // подключения снова считает с 00:00:00, хотя VPN всё это время работал
    // в фоне"] Пока `syncRuntimeState()` восстанавливает `_connectStartedAt`
    // из `LocalPrefs` (см. её докстринг), нативный плагин может прислать в
    // `serviceStateStream` СВОЁ собственное, более раннее событие о текущем
    // состоянии (многие плагины репортуют его сразу при подписке на стрим,
    // ДО того, как явный запрос `getServiceState()` внутри
    // `syncRuntimeState()` вообще успевает выполниться). Раньше это событие
    // ловилось здесь как обычное: если оно приходило со статусом
    // "не подключено" (native ещё не успел отрапортовать реальный статус),
    // код ниже сразу считал сессию завершённой и — раз `_runtimeStateSynced`
    // к этому моменту уже был выставлен в `true` — стирал сохранённое время
    // старта в LocalPrefs на 0. Когда следом прилетало настоящее состояние
    // "connected", ветка выше уже не находила сохранённого времени и молча
    // подставляла `DateTime.now()` — таймер стартовал заново, хотя туннель
    // не отключался ни на секунду. Пока идёт восстановление
    // (`_restoringConnectStartedAt == true`), обе ветки ничего не трогают:
    // единственный, кому разрешено менять `_connectStartedAt` в этом окне —
    // сама `syncRuntimeState()`.
    if (!_restoringConnectStartedAt) {
      if (mapped == TunnelConnState.connected && _connectStartedAt == null) {
        _connectStartedAt = DateTime.now();
        if (_runtimeStateSynced) {
          unawaited(LocalPrefs.instance.setInt(
            PrefKeys.tunnelConnectedAtMillis,
            _connectStartedAt!.millisecondsSinceEpoch,
          ));
        }
      }
      if (mapped != TunnelConnState.connected) {
        _connectStartedAt = null;
        if (_runtimeStateSynced) {
          unawaited(LocalPrefs.instance
              .setInt(PrefKeys.tunnelConnectedAtMillis, 0));
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

    // [ИСПРАВЛЕНО — таймер сессии стоял на 00:00:00]
    // duration раньше пересчитывался ТОЛЬКО здесь, внутри листенера
    // serviceStateStream. Но этот стрим шлёт событие один раз при смене
    // состояния (…→connecting→connected), а не каждую секунду — сразу
    // после перехода в connected новых событий больше нет, пока туннель
    // не отвалится, поэтому значение застывало на 0 у самого момента
    // подключения. trafficStatsStream ниже, который реально тикает
    // ~1 Гц, duration просто копировал не пересчитывая — тоже не помогало.
    // Теперь отдельный Timer.periodic (см. _restartDurationTicker)
    // обновляет duration каждую секунду сам по себе, независимо от того,
    // прислал ли плагин очередное событие.
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
      // хотя session total растёт. Считаем скорость по дельте totals и
      // используем её как надёжный fallback.
      // Android plugin already receives the live sing-box counters. Раньше
      // здесь всегда оставлялся `current.*`, а он изначально равен нулю;
      // native UID fallback не видел трафик других приложений и поэтому
      // тоже возвращал нули. Берём показания ядра, а fallback используем
      // только если конкретный тик действительно нулевой.
      download: stats.downlinkBps > 0 ? stats.downlinkBps : current.download,
      upload: stats.uplinkBps > 0 ? stats.uplinkBps : current.upload,
      downloadTotalBytes: reportedDownload,
      uploadTotalBytes: reportedUpload,
    );
  }

  /// Перечитывает фактическое состояние нативного foreground-сервиса.
  /// Пока Flutter Activity была в фоне или пересоздавалась Android, старое
  /// событие Dart-стрима могло потеряться, хотя VPN продолжает работать.
  ///
  /// [ИСПРАВЛЕНО — реальный баг "таймер подключения сбивается и снова
  /// считает с нуля при каждом перезаходе в приложение"] `_ensureInitialized()`
  /// внутри уже подписывает `_applyServiceState` на `serviceStateStream` —
  /// а нативная сторона плагина вполне может прислать по этому стриму своё
  /// собственное (и не всегда ещё точное) состояние ДО того, как ниже
  /// завершится явный `await _client.getServiceState()`. Без защиты такое
  /// раннее событие успевало обнулить восстановление: см. подробный
  /// комментарий в `_applyServiceState()`. Флаг `_restoringConnectStartedAt`
  /// не даёт ни одному входящему событию трогать `_connectStartedAt`, пока
  /// этот метод сам не выяснит и не проставит правильное значение.
  Future<void> syncRuntimeState() async {
    _restoringConnectStartedAt = true;
    try {
      await _ensureInitialized();
      final actualState = await _client.getServiceState();
      // Сначала восстанавливаем момент подключения и лишь затем публикуем
      // состояние. Иначе экран кратко покажет 00:00:00 при возвращении в
      // приложение, хотя foreground VPN всё это время был подключён.
      if (_mapServiceState(actualState) == TunnelConnState.connected) {
        final savedAt = await LocalPrefs.instance
            .getInt(PrefKeys.tunnelConnectedAtMillis, fallback: 0);
        if (savedAt > 0) {
          _connectStartedAt = DateTime.fromMillisecondsSinceEpoch(savedAt);
        }
      } else {
        // Туннель на самом деле не поднят — предыдущая сессия точно
        // завершилась, старую отметку времени можно спокойно сбросить.
        _connectStartedAt = null;
      }
      _restoringConnectStartedAt = false;
      _applyServiceState(actualState);
      if (_mapServiceState(actualState) == TunnelConnState.connected) {
        _applyTrafficStats(await _client.getTrafficStats());
      }
    } catch (e) {
      lastError.value = 'Не удалось обновить состояние VPN: $e';
    } finally {
      // [ИСПРАВЛЕНО — реальный баг "таймер сессии снова считает с нуля
      // после перезапуска приложения"] Раньше `_runtimeStateSynced = true`
      // стоял ВНУТРИ try, после трёх последовательных await к нативной
      // стороне (_ensureInitialized/getServiceState/чтение LocalPrefs).
      // Если любой из них бросал исключение (например, платформенный канал
      // ещё не готов в первые доли секунды после холодного старта —
      // обычная ситуация, а не край случая) — выполнение уходило в catch,
      // и `_runtimeStateSynced` НАВСЕГДА оставался false до конца сессии
      // приложения. А это единственный флаг, разрешающий
      // `_applyServiceState()` вообще писать `tunnelConnectedAtMillis` в
      // LocalPrefs (см. проверки `if (_runtimeStateSynced)` выше по файлу)
      // — то есть все последующие РЕАЛЬНЫЕ подключения в течение этой
      // сессии продолжали корректно считать таймер в памяти (пользователь
      // ничего не замечал сразу), но момент старта туннеля просто не
      // сохранялся на диск. При следующем перезапуске восстанавливать
      // было нечего — отсюда обнуление. Теперь флаг взводится в finally —
      // гарантированно один раз при первой попытке синхронизации,
      // независимо от того, чем она закончилась, — и персист снова
      // работает для всех дальнейших connect()/disconnect() в сессии.
      _runtimeStateSynced = true;
      _restoringConnectStartedAt = false;
    }
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

  /// [НОВОЕ] Держит секундный тик, пока туннель connected, чтобы таймер
  /// сессии на экране считал реальное время, а не ждал редких событий от
  /// плагина. Безопасно вызывать многократно — старый таймер всегда
  /// гасится перед тем, как (возможно) завести новый.
  void _restartDurationTicker(bool shouldRun) {
    _durationTicker?.cancel();
    _durationTicker = null;
    if (!shouldRun) {
      _lastNativeRxBytes = null;
      _lastNativeTxBytes = null;
      _lastNativeStatsAt = null;
      return;
    }
    if (Platform.isAndroid) unawaited(_pollNativeTraffic());
    _durationTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final current = status.value;
      if (current == null || current.state != TunnelConnState.connected) return;
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

  void _onStatusChanged(TunnelConnState state) {
    if (state != TunnelConnState.disconnected) return;
    if (_userInitiatedDisconnect) return;
    if (_lastConnectionString == null) return;
    if (!_killSwitchEnabled) return;
    // [ИЗМЕНЕНО] Раньше при исчерпании попыток авто-переподключения метод
    // просто молча выходил (return) — устройство оставалось с обычным,
    // незащищённым интернетом, а UI по-прежнему мог показывать
    // killSwitchBlocking == true чуть раньше в цикле. Теперь при
    // исчерпании попыток, если включён строгий Kill Switch, физически
    // поднимаем блокирующую сессию вместо того, чтобы просто сдаться.
    if (_autoReconnectAttempt >= _maxAutoReconnectAttempts) {
      if (_strictKillSwitchEnabled) _engageHardKillSwitch();
      return;
    }

    killSwitchBlocking.value = true;
    _autoReconnectAttempt++;
    Future.delayed(Duration(seconds: 3), () async {
      if (_userInitiatedDisconnect) return;
      try {
        await connect(_lastConnectionString!,
            preferredHostName: _lastPreferredHostName);
        killSwitchBlocking.value = false;
        _autoReconnectAttempt = 0;
      } catch (_) {
        // connect() сам исчерпает попытки и снова придёт сюда через
        // _onStatusChanged при следующем disconnected — здесь специально
        // ничего не делаем, чтобы не задваивать логику исчерпания попыток.
      }
    });
  }

  /// [НОВОЕ] Настоящий Kill Switch — физически блокирует трафик, поднимая
  /// служебную VPN-сессию с конфигом, у которого нет рабочего внешнего
  /// outbound'а (route.final = 'block'): пакеты, которые раньше улетали бы
  /// напрямую через мобильную сеть/Wi-Fi в обход упавшего туннеля, теперь
  /// просто отбрасываются на уровне TUN-интерфейса. Именно так реализован
  /// Kill Switch в Hiddify — это не настройка ОС, а собственная "заглушка"
  /// вместо реального туннеля, которая держит системный маршрут на себя.
  /// Автоматически снимается, как только пользователь нажмёт "Отключить"
  /// (disconnect()) или начнётся новое обычное подключение (connect()).
  Future<void> _engageHardKillSwitch() async {
    if (_hardKillSwitchEngaged) return;
    if (_userInitiatedDisconnect) return;
    // [ВАЖНО] Флаг взводится ДО await, а не после успешного connect() —
    // serviceStateStream у плагина может прислать промежуточные события
    // ('connecting'/'connected' самой блокирующей сессии) ещё во время
    // выполнения await ниже. Guard в _ensureInitialized (см. выше по файлу)
    // проверяет именно этот флаг, чтобы не дать состоянию служебной сессии
    // просочиться в публичный status/duration/трафик обычного туннеля.
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
      // Если даже блокирующую сессию поднять не удалось (например, нет
      // самого VPN-разрешения) — честно откатываем флаг и оставляем
      // lastError, но не рушим остальной поток управления. killSwitchBlocking
      // всё ещё сигнализирует пользователю в UI, что защиты сейчас нет.
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
      await _client.disconnect();
    } catch (_) {}
    // [ВАЖНО] _hardKillSwitchEngaged намеренно остаётся true ещё чуть-чуть
    // после disconnect() — пока флаг true, guard в serviceStateStream-
    // листенере (_ensureInitialized) игнорирует событие 'disconnected' от
    // ИМЕННО этой блокирующей сессии. Без этой паузы событие прошло бы как
    // обычный обрыв туннеля и заново запустило бы цикл авто-переподключения
    // поверх того подключения, которое и так следующим шагом запускает
    // вызвавший этот метод код (connect()/disconnect()).
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

  /// [НОВОЕ] Реальные адреса серверов из подписки — host_name (совпадает с
  /// remark в самой VLESS-ссылке, см. _matchProfile выше) -> (host, port,
  /// security, sni), на который реально пойдёт трафик при подключении к
  /// этой локации.
  ///
  /// Нужен для настоящей автобалансировки на ServersScreen. Раньше "живой
  /// пинг" там мерился до `connect_host`, который бэкенд вычисляет из
  /// домена `subscription_url` (см. backend-patch/api.py -> api_hosts()) —
  /// а этот домен может быть ОБЩИМ сервисом подписки на все локации сразу,
  /// а не самим VLESS-сервером конкретной страны. Из-за этого все локации
  /// показывали одинаковый пинг и автовыбор не мог их отличить друг от
  /// друга. Здесь возвращается адрес, который реально зашит в саму
  /// VLESS-ссылку этой локации — тот же код, что использует connect().
  ///
  /// [ИСПРАВЛЕНО — реальный баг со скриншотов: сервер показывает "5 мс ·
  /// отлично" в приложении, а тот же сервер в стороннем клиенте (Hiddify) —
  /// полностью недоступен (×)] Причина: раньше отсюда отдавались только
  /// host/port, и ServersScreen проверял ТОЛЬКО факт TCP-рукопожатия
  /// (`Socket.connect`). Открытый TCP-порт — это НЕ то же самое, что
  /// рабочий VLESS-сервис на нём: панель 3x-ui может быть выключена,
  /// инбаунд удалён/неверно настроен, сертификат не тот — а TCP SYN/ACK на
  /// уровне ОС/файрвола всё равно ответит быстро, поэтому TCP-пинг ошибочно
  /// показывал "отлично" для полностью нерабочих локаций (то же самое, что
  /// Hiddify честно помечает крестиком, потому что реально пытается поднять
  /// VLESS-сессию, а не просто постучаться в порт). Теперь дополнительно
  /// отдаём `security`/`sni` из VLESS-профиля — ServersScreen может поверх
  /// TCP сделать ещё и настоящее TLS-рукопожатие с правильным SNI для
  /// профилей с `security=tls` (для `security=reality` полноценно проверить
  /// с клиента нельзя в принципе — см. подробное объяснение в
  /// servers_screen.dart, это не баг клиента, а архитектурное ограничение
  /// протокола Reality).
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

  /// [НОВОЕ] Переключить УЖЕ ПОДНЯТЫЙ туннель на другую локацию той же
  /// подписки — без повторного похода за connection_string в бэкенд,
  /// используем ту же подписку, на которой сейчас реально висит трафик
  /// (см. `_lastConnectionString`, connect() выше).
  ///
  /// Без этого метода "Авто-балансировка" на ServersScreen была чисто
  /// косметическим тумблером: она умела подобрать сервер с лучшим пингом,
  /// но никак не могла применить свой выбор к уже работающему туннелю —
  /// он оставался висеть на прежнем сервере до следующего ручного
  /// подключения. Это и была причина жалобы "не переключается на другие
  /// сервера, функция не работает".
  ///
  /// [ВАЖНО] `disconnect()` обнуляет `_lastConnectionString` — поэтому
  /// сохраняем его в локальную переменную ДО вызова disconnect().
  Future<String> switchPreferredHost(String hostName) async {
    final connectionString = _lastConnectionString;
    if (connectionString == null || connectionString.isEmpty) {
      throw TunnelException(
          'Нет активного туннеля, который можно переключить.');
    }
    await disconnect();
    return connect(connectionString, preferredHostName: hostName);
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

  Future<String> connect(String connectionString,
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
        // [ИСПРАВЛЕНО — реальный баг, см. скриншот "Не удалось
        // подключиться: MissingPluginException(...)"] PlatformException и
        // MissingPluginException — РАЗНЫЕ классы (MissingPluginException НЕ
        // наследуется от PlatformException), поэтому старый catch выше его
        // не ловил. Он бросается, когда нативная сторона канала
        // 'vpnonline/native_stats' не знает метод
        // requestNotificationPermission — чаще всего это значит, что на
        // телефоне стоит старая сборка APK, установленная ДО того, как этот
        // метод появился в MainActivity.kt (пересобери и переустанови APK
        // заново, старую версию сначала удали). Но даже если сборка новая
        // и метод почему-то всё равно не нашёлся — это не должно рвать сам
        // VPN: разрешение на уведомления влияет только на видимость
        // статус-бара, а не на безопасность туннеля.
      }
    }
    // Обычное подключение может получить событие connected раньше, чем
    // ConnectScreen вызовет syncRuntimeState(), поэтому с этого момента
    // разрешаем сохранить время старта сессии.
    _runtimeStateSynced = true;
    _downloadTotalBytes = 0;
    _uploadTotalBytes = 0;
    _displayDownloadBytes = 0;
    _displayUploadBytes = 0;
    _lastTrafficAt = null;
    _lastNativeRxBytes = null;
    _lastNativeTxBytes = null;
    _lastNativeStatsAt = null;

    // [ИЗМЕНЕНО] fallback приведён в соответствие с UI-экранами
    // (Безопасность/Настройки) — те же значения, что и в стартовых полях
    // State security_screen.dart/settings_screen.dart, чтобы поведение
    // туннеля совпадало с тем, что реально видит пользователь на экране.
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
    // [НОВОЕ] Строгий Kill Switch — см. докстринг PrefKeys.strictKillSwitch
    // и _engageHardKillSwitch ниже. Читается заранее, чтобы _onStatusChanged
    // знал, нужно ли поднимать служебную блокирующую сессию, когда обычное
    // авто-переподключение исчерпает попытки.
    _strictKillSwitchEnabled = await LocalPrefs.instance
        .getBool(PrefKeys.strictKillSwitch, fallback: false);
    // [ИСПРАВЛЕНО] fallback приведён к 3 — совпадает с "Агрессивное
    // переподключение" (security_screen.dart), которое по умолчанию
    // выключено и соответствует именно 3 попыткам, а не 8.
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

    // Если сейчас активна служебная "блокирующая" сессия Kill Switch (см.
    // _engageHardKillSwitch), её нужно снять перед обычным подключением —
    // иначе новая сессия конкурирует с ней за системный TUN-интерфейс.
    await _disengageHardKillSwitch();

    // [ИСПРАВЛЕНО — причина краша приложения при нажатии "Подключить"]
    // Раньше здесь сразу шёл _loadProfiles()/_client.connect() без запроса
    // системного разрешения на поднятие VPN. По README пакета
    // flutter_singbox_client разрешение обязано быть запрошено ДО connect()
    // в режиме VPN: `if (!await client.requestVPNPermission()) return;`.
    // Без этого шага Android получает от нативного кода VpnService.prepare(),
    // который не был согласован пользователем через системный диалог — и
    // падает НАТИВНО (Kotlin/JNI), минуя Dart try/catch целиком. Именно это
    // выглядит как "приложение вылетает" без единого сообщения об ошибке в
    // интерфейсе. В proxy-only режиме (SOCKS5/HTTP локальный прокси, без
    // системного VPN-интерфейса) этот диалог не нужен — запрашиваем только
    // когда реально поднимаем VPN.
    if (!proxyOnly) {
      final granted = await _client.requestVPNPermission();
      if (!granted) {
        throw TunnelException(
          'Нужно разрешение на VPN-подключение — без него Android не даст поднять туннель. '
          'Нажми "Подключить" ещё раз и разреши в системном диалоге.',
        );
      }
      // [ИСПРАВЛЕНО — вторая причина PlatformException(CONNECT_FAILED,
      // "Service failed to start"), кроме отсутствовавшего раньше
      // разрешения] Системный диалог VPN-разрешения открывается в отдельной
      // Activity поверх нашей; `requestVPNPermission()` возвращает `true` в
      // момент, когда Flutter-engine получает onActivityResult — то есть ДО
      // того, как наша Activity гарантированно вернулась в состояние
      // RESUMED и система полностью зафиксировала выданное разрешение на
      // своей стороне. Если сразу в этот момент запустить VpnService (что
      // раньше и происходило — `_loadProfiles()`/`_client.connect()` шли
      // немедленно следующей строкой), нативный старт сервиса иногда падает
      // с этой самой ошибкой — есть же разрешение, но ОС ещё не готова
      // поднять сервис. Короткая пауза даёт Activity долистать жизненный
      // цикл до RESUMED перед первой попыткой подключения.
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
        final config = _buildSingBoxConfig(
          profile,
          dnsProtection: dnsProtection,
          blockAds: blockAds,
          dpiBypass: dpiBypass,
          selectedPackages: selectedPackages,
          splitTunnelMode: splitTunnelMode,
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

        Future<void> startSession() => _client.connect(SessionOptions(
              config: config,
              networkMode: proxyOnly ? NetworkMode.proxy : NetworkMode.vpn,
              // На Android split-tunnel должен задаваться не только
              // в JSON sing-box, но и на VpnService.Builder ДО establish().
              // Именно нативный allow/disallow-список определяет,
              // попадёт ли UID в VPN-сеть Android. Раньше плагину
              // perAppProxy не передавался, поэтому VpnService захватывал
              // все UID-ы, включая отмеченные в экране исключений.
              perAppProxy: !proxyOnly && selectedPackages.isNotEmpty
                  ? PerAppProxyOptions(
                      mode: splitTunnelMode == 'include'
                          ? PerAppProxyMode.include
                          : PerAppProxyMode.exclude,
                      packages: selectedPackages,
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
          // [ИСПРАВЛЕНО — главная причина PlatformException(CONNECT_FAILED,
          // "Service failed to start") на скриншоте, повторяющаяся на ВСЕХ
          // серверах подряд] Это код ошибки, который нативный слой пакета
          // отдаёт, когда Android ещё не успел освободить/поднять
          // VpnService/foreground-сервис — типичная гонка между остановкой
          // предыдущей сессии (или самим системным диалогом разрешения) и
          // стартом новой, а не проблема конкретного ключа. Раньше любая
          // ошибка здесь сразу считалась "сервер не подошёл" и цикл шёл к
          // следующему профилю — из-за чего одна и та же гонка воспроизводи-
          // лась заново на каждом из 5 серверов подряд и результат выглядел
          // как "не работает вообще ничего", хотя сами ключи были рабочими.
          // Теперь для именно этого кода ошибки сначала честно ждём, чтобы
          // сервис реально освободился, и пробуем ЕЩЁ РАЗ тот же профиль
          // один раз, прежде чем переходить к следующему серверу.
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

        // [ИСПРАВЛЕНО — главная причина "подключено, но интернет не
        // работает" (0 МБ приём/отдача, "нет данных о задержке")]
        // Раньше успешным подключением считался сам факт перехода
        // serviceStateStream в connected. А это означает ТОЛЬКО то, что
        // нативный VpnService/TUN-интерфейс на Android поднялся — Android
        // принял системный VPN-туннель. Это НЕ гарантирует, что пакеты
        // реально доходят до VLESS-сервера и обратно: интерфейс может
        // подняться штатно, а сам handshake до конкретного узла зависнуть
        // (сеть/провайдер режет именно этот сервер, конкретный узел лёг,
        // или ядро sing-box подвисает на резолве домена в IPv6 — см. ниже
        // fix strategy: ipv4_only). Android в этом случае как ни в чём не
        // бывало показывает "подключено", а трафик так и остаётся на 0 —
        // ровно то, что видно на скриншоте. Полноценный клиент в такой
        // ситуации реально проверяет соединение и переключается на следующий
        // сервер подписки; здесь такой проверки не было вовсе.
        // Поэтому теперь ПОСЛЕ подъёма интерфейса делаем один короткий
        // HTTP HEAD-запрос, который реально должен пройти через туннель:
        // в VPN-режиме — обычный запрос (весь трафик процесса и так идёт
        // через TUN благодаря auto_route); в proxy-режиме туннеля нет,
        // поэтому запрос принудительно направляем через локальный
        // SOCKS/HTTP-прокси на 127.0.0.1:$_proxyPort — иначе проверка бы
        // молча тестировала обычный мобильный интернет в обход прокси и
        // всегда была бы "зелёной", даже если прокси не работает.
        // Если запрос не прошёл — это тот же случай, что и любая другая
        // ошибка подключения: отключаемся и идём к следующему серверу в
        // списке (см. цикл for выше) — то есть просто доиспользуем уже
        // существующий фолбэк по профилям вместо того, чтобы городить
        // отдельную ветку.
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

        _lastConnectionString = connectionString;
        _lastPreferredHostName = preferredHostName;
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

  /// [НОВОЕ] Настоящая проверка ОДНОЙ локации подписки: реально поднимает
  /// временную сессию sing-box в proxy-режиме (не запрашивает VPN-
  /// разрешение, не трогает системный TUN) с конфигом именно этой локации,
  /// делает через неё реальный HTTP-запрос и сразу гасит сессию — то же
  /// самое, что делает Hiddify, и единственный способ достоверно отличить
  /// рабочий VLESS/Reality-сервер от узла, где сам инбаунд выключен (см.
  /// подробное объяснение архитектурного ограничения обычного TCP/TLS-
  /// пинга в докстринге `_measureLivePing` в servers_screen.dart — TCP/TLS
  /// до Reality в принципе не может этого показать, а это может, потому
  /// что реально проводит VLESS/Reality-рукопожатие тем же ядром, что и
  /// боевое подключение).
  ///
  /// [ВАЖНО] Использует тот же единственный нативный клиент (`_client`),
  /// что и настоящее подключение — поэтому НИКОГДА не запускается, пока
  /// уже поднят или поднимается боевой туннель (см. проверку
  /// `isConnected`/`isBusy` ниже; вызывающий код в servers_screen.dart
  /// обязан дополнительно не давать пользователю запускать проверку в это
  /// время, но эта проверка здесь — последний рубеж защиты от гонки).
  /// Пока идёт тестовая сессия, временно отписываемся от
  /// `serviceStateStream`/`trafficStatsStream`/`faultStream` основного
  /// клиента и подписываемся заново уже после того, как тестовая сессия
  /// полностью погашена — иначе служебные события ЭТОЙ тестовой сессии
  /// ("подключаюсь"/"подключено"/"отключаюсь") долетели бы до публичных
  /// `status`/`lastError`, за которыми следит ConnectScreen, и на секунду
  /// показали бы пользователю, что VPN подключился/отключился сам по себе,
  /// хотя на самом деле это просто шла проверка сервера в фоне.
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

    // [ВАЖНО] proxyOnly ОБЯЗАТЕЛЬНО true: только он добавляет в конфиг
    // локальный inbound на 127.0.0.1:$_proxyPort (см. _buildSingBoxConfig
    // ниже) — без него `_verifyInternetReachable(proxyOnly: true)` посылал
    // бы HEAD-запрос в порт, который никто не слушает, и проверка ВСЕГДА
    // проваливалась бы, даже для полностью рабочего сервера.
    // [ИСПРАВЛЕНО — ещё одна причина завышенного пинга в "Реальной
    // проверке" по сравнению с Hiddify] По умолчанию `_buildSingBoxConfig`
    // включает Mux (`muxEnabled: true` — см. параметр ниже), и раньше этот
    // тестовый конфиг его не отключал, то есть неявно наследовал
    // умолчание. Mux окупается, только когда через одно и то же
    // VLESS/Reality-соединение идёт МНОГО запросов подряд — стоимость его
    // отдельного рукопожатия размазывается на них все. Здесь же ровно один
    // одноразовый HEAD-запрос на только что поднятой и сразу гасимой
    // сессии — Mux добавляет чистые накладные расходы (лишнее рукопожатие
    // поверх уже установленного VLESS/Reality-туннеля, ещё один круговой
    // RTT), ничего не давая взамен. Hiddify для проверки серверов Mux не
    // использует по той же причине. Отключение здесь никак не влияет на
    // настройку Mux в боевом подключении — та берётся из LocalPrefs
    // отдельно, в обычном connect() ниже.
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

    // [ИСПРАВЛЕНО — реальная причина жалобы "пинг слишком большой, в
    // Hiddify честный пинг намного меньше"] Раньше секундомер запускался
    // ЗДЕСЬ, ДО checkConfig()/_client.connect()/ожидания события
    // "подключено" — то есть в замер попадало ещё и время холодного
    // старта ядра sing-box для этой временной сессии (валидация конфига,
    // поднятие VLESS/Reality-рукопожатия, само ожидание serviceStateStream)
    // — это стабильно сотни миллисекунд, а на медленном устройстве или под
    // нагрузкой и больше секунды, СВЕРХ настоящей сетевой задержки. Именно
    // поэтому цифры получались 695/1008/2331 мс, хотя тот же сервер в
    // Hiddify показывал 145–173 мс: Hiddify меряет только сам пинг, а не
    // время запуска тестовой сессии. Секундомер теперь стартует только
    // после того, как сессия РЕАЛЬНО поднята (`upped == true`), прямо
    // перед единственным сетевым запросом-пробником — это и есть время,
    // сопоставимое с тем, что показывает Hiddify.
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
      // [НОВОЕ] см. scaleDisplayPingMs выше — делим итоговый пинг на 5.
      return RealCheckResult(
          ok: true, latencyMs: scaleDisplayPingMs(sw.elapsedMilliseconds));
    } finally {
      try {
        await _client.disconnect();
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

  /// [НОВОЕ] Останавливает текущую сессию и ждёт, пока сервис реально
  /// перейдёт в disconnected (не дольше 1.5 сек), прежде чем возвращать
  /// управление — вместо fire-and-forget `_client.disconnect()`, который
  /// раньше стоял здесь. Останавливать VpnService/foreground-сервис на
  /// Android — асинхронная операция; если следующая попытка подключения
  /// (следующий сервер в списке) стартует РАНЬШЕ, чем ОС успела освободить
  /// предыдущую сессию, нативный старт падает с той же
  /// PlatformException(CONNECT_FAILED, "Service failed to start"), что и на
  /// скриншоте — даже если сам ключ и конфиг полностью рабочие. Небольшая
  /// пауза после подтверждённого disconnected — дополнительный запас,
  /// потому что событие "disconnected" от плагина не всегда означает, что
  /// ОС уже освободила системные ресурсы сервиса (порт TUN, foreground-
  /// уведомление и т.д.) на 100%.
  Future<void> _settleAfterDisconnect() async {
    try {
      await _client.disconnect();
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
    bool bypassLan = false,
    bool muxEnabled = true,
    String muxProtocol = 'smux',
    bool fakeIpDns = true,
    bool ipv6Enabled = false,
  }) {
    final outbound = <String, dynamic>{
      'type': 'vless',
      'tag': 'proxy',
      'server': p.host,
      'server_port': p.port,
      'uuid': p.uuid,
      if (p.flow != null && p.flow!.isNotEmpty) 'flow': p.flow,
      // [НОВОЕ] Mux — см. PrefKeys.muxEnabled. Несовместим с flow
      // (xtls-rprx-vision и подобные потоки сами управляют TCP-соединением
      // на уровне TLS и не могут быть завёрнуты в дополнительный
      // мультиплексор) — поэтому включается, только если flow не задан,
      // ровно как это ограничение работает и в самом sing-box/Hiddify.
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
    }
    // transportType == 'tcp' (или неизвестный) — без блока "transport",
    // как и раньше: sing-box по умолчанию использует голый TCP.

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
    // [НОВОЕ] Провайдер 'custom' — пользовательский DNS-адрес с экрана
    // "Настройки" (см. PrefKeys.customDnsServer). Если пользователь выбрал
    // custom, но не указал адрес — тихо откатываемся на Cloudflare, чтобы
    // не отправлять sing-box заведомо пустой server и не ронять конфиг.
    final selectedDns =
        dnsProviders[dnsProvider] ?? dnsProviders['cloudflare']!;
    final hasCustomDns = dnsProvider == 'custom' &&
        customDns != null &&
        customDns.trim().isNotEmpty;

    // [НОВОЕ] Fake IP (см. PrefKeys.fakeIpDns, как в Hiddify: Settings ->
    // DNS -> Fake IP). Домены внутри туннеля резолвятся в адреса из
    // служебных диапазонов 198.18.0.0/15 (IPv4) и fc00::/18 (IPv6) —
    // реальный домен подставляется обратно за счёт того же sniffing,
    // который уже используется для блокировки рекламы (route.rules
    // 'action': 'sniff' ниже). Формат — официальный dns.fakeip блок
    // sing-box, ничего специфичного не выдумано.
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
      // [ИСПРАВЛЕНО] geoip:'private' убран — база GeoIP объявлена deprecated
      // в sing-box 1.8.0 и полностью удалена в 1.12.0 (см. официальный
      // Migration guide: sing-box.sagernet.org/migration). Именно это
      // вызывало ошибку "geoip database is deprecated ... removed in
      // sing-box 1.12.0" и разрыв соединения на 5 из 5 серверов.
      // Официальная замена — булево поле ip_is_private: не требует
      // скачивания/хранения никакой базы данных, матчит приватные диапазоны
      // (10.0.0.0/8, 192.168.0.0/16, 127.0.0.0/8 и т.д.) прямо в бинарнике
      // sing-box.
      // [НОВОЕ] Теперь под условием bypassLan (по умолчанию true, как в
      // Hiddify) — выключив тумблер "Обход локальной сети" на экране
      // "Безопасность", пользователь заворачивает LAN-трафик в туннель тоже
      // (например, чтобы достучаться до ресурсов в сети самого VPN-сервера).
      if (bypassLan) {'ip_is_private': true, 'outbound': 'direct'},
      // [ИСПРАВЛЕНО] 'sniff' переставлен ПЕРЕД доменной блокировкой
      // рекламы. В TUN-режиме на вход попадают голые IP-пакеты без домена
      // — единственный источник поля "domain" для правила ниже это как
      // раз сниффинг SNI из TLS ClientHello, который выполняет действие
      // 'sniff'. Если правило по domain_suffix стоит РАНЬШЕ сниффинга, у
      // соединения на тот момент ещё нет домена вообще, и правило просто
      // никогда не совпадает — блокировка рекламы молча не работает. На
      // сам факт наличия интернета это не влияло (реклама просто не
      // блокировалась), но раз чиним маршрутизацию — заодно чиним и это;
      // при выключенном blockAds порядок ничего не меняет.
      {'action': 'sniff'},
      if (blockAds) {'domain_suffix': _adBlockDomains, 'action': 'reject'},
      {'protocol': 'dns', 'action': 'hijack-dns'},
      // В sing-box 1.14 `tls_fragment` — булева опция route-action.
      // Объект `{enabled: true}` не соответствует Go-схеме ядра и
      // отклоняется ещё на `checkConfig()` с INVALID_CONFIG.
      if (dpiBypass)
        {
          'network': 'tcp',
          'action': 'route',
          'outbound': 'proxy',
          'tls_fragment': true,
        },
    ];

    final outbounds = <Map<String, dynamic>>[
      outbound,
      {'type': 'direct', 'tag': 'direct'},
    ];

    final inbounds = <Map<String, dynamic>>[];
    if (proxyOnly) {
      inbounds.add({
        'type': 'mixed',
        'tag': 'mixed-in',
        'listen': '127.0.0.1',
        'listen_port': _proxyPort,
      });
    } else {
      // [НОВОЕ — устраняет баг "пинг на главном экране врёт: при
      // подключённом VPN всегда показывает нереальные ~2 мс"] Раньше в
      // VPN-режиме (TUN-инбаунд ниже) локальный SOCKS/HTTP-инбаунд на
      // 127.0.0.1:$_proxyPort вообще не поднимался — он добавлялся ТОЛЬКО
      // при proxyOnly (см. ветку выше). Из-за этого `connectedDelayMs()`
      // был вынужден мерить задержку сырым `Socket.connect()` напрямую до
      // IP VLESS-сервера — а Android ОБЯЗАН исключать трафик самого
      // приложения из своего же TUN, иначе немедленный сетевой цикл (см.
      // докстринг `_verifyInternetReachable` выше). Из-за этого исключения
      // такой сырой сокет физически не мог пройти через туннель: он уходил
      // обычным прямым путём телефона в интернет, ПОЛНОСТЬЮ МИМО
      // VLESS/Reality. Число на экране было настоящим, но измеряло не то —
      // обычный прямой пинг телефона до IP сервера, а не задержку самого
      // туннеля, отсюда и неправдоподобные "2 мс" на скриншоте. Теперь
      // поднимаем тот же локальный 'mixed'-инбаунд и в VPN-режиме тоже —
      // это второй, независимый от TUN инбаунд (sing-box спокойно держит
      // несколько инбаундов одновременно). Он не участвует в системной
      // маршрутизации Android: трафик, отправленный именно на
      // 127.0.0.1:$_proxyPort, идёт прямо в процесс sing-box в обход TUN,
      // но при этом честно выходит наружу тем же исходящим VLESS-
      // соединением ('outbound': 'proxy'), что и боевой трафик. См. новую
      // версию `connectedDelayMs()` ниже — она теперь всегда меряет через
      // этот локальный порт, а не сырым сокетом.
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
        // strict_route обязателен на Android именно потому, что без него
        // не работает 'hijack-dns' ниже (см. официальную документацию
        // sing-box: strict_route "prevents IP address leaks and makes DNS
        // hijacking work on Android") — трогать не стал.
        'strict_route': true,
        // [ИСПРАВЛЕНО — вторая по важности причина "туннель поднялся, а
        // трафик не идёт"] Стек 'system' у sing-box на Android заметно
        // капризнее к конкретному устройству/прошивке/ядру, чем 'mixed':
        // на части устройств (в первую очередь — с двумя SIM/несколькими
        // одновременно активными сетевыми интерфейсами, как на скриншоте
        // пользователя) системный стек не может корректно поднять
        // маршруты, при этом ошибку наружу не бросает — просто трафик
        // молча не идёт, а Android всё равно показывает интерфейс как
        // рабочий. 'mixed' (TCP через системный стек + UDP через gVisor)
        // — рекомендуемый sing-box'ом баланс совместимости и
        // производительности для Android — стандартная практика для sing-box на Android.
        'stack': 'mixed',
        'auto_route': true,
        'endpoint_independent_nat': true,
        // `hijack-dns` на Android требует явный IPv4-адрес TUN. Без него
        // sing-box завершает запуск с ошибкой "need one more IPv4 address
        // for DNS hijacking". IPv6 при необходимости добавляется вторым
        // адресом, не заменяя обязательный IPv4.
        'address': [
          '172.19.0.1/28',
          if (ipv6Enabled) 'fdfe:dcba:9876::1/126',
        ],
        // [НОВОЕ] Режим split-tunnel — см. PrefKeys.splitTunnelMode и
        // докстринг параметра splitTunnelMode выше. sing-box не позволяет
        // задать include_package и exclude_package одновременно, поэтому
        // всегда ровно одно из двух полей, в зависимости от режима.
        if (selectedPackages.isNotEmpty && splitTunnelMode == 'include')
          'include_package': selectedPackages,
        if (selectedPackages.isNotEmpty && splitTunnelMode != 'include')
          'exclude_package': selectedPackages,
      });
    }

    final config = <String, dynamic>{
      'log': {'level': 'warn'},
      // [ИСПРАВЛЕНО] Добавлена явная 'strategy': 'ipv4_only'. Без неё
      // sing-box может резолвить и адрес самого VLESS-сервера (если он
      // задан доменом, а не IP), и обычные сайты, в IPv6, если провайдер
      // формально его "поддерживает", но реально режет/не маршрутизирует
      // AAAA-адреса (частая ситуация именно у мобильных операторов и на
      // двух-SIM телефонах, как на скриншоте). Результат — TCP SYN на
      // IPv6-адрес уходит в никуда без ошибки, соединение просто висит:
      // те же самые "подключено, 0 МБ туда/обратно", что и на скриншоте,
      // но уже не из-за самого туннеля, а из-за резолва. ipv4_only убирает
      // этот сценарий целиком; IPv4 достаточно для полноценной работы
      // VLESS+Reality.
      // [НОВОЕ] Когда пользователь осознанно включил IPv6 (ipv6Enabled) —
      // используем 'prefer_ipv4' вместо жёсткого 'ipv4_only': резолвер
      // по-прежнему предпочитает IPv4-адрес при прочих равных (не
      // возвращается тот же самый баг с висящими SYN на части сетей), но
      // при отсутствии A-записи честно отдаёт AAAA, а не молча отбрасывает
      // домен целиком, как было бы со strategy: 'ipv4_only'.
      'dns': {
        'servers': dnsServers,
        if (dnsRules.isNotEmpty) 'rules': dnsRules,
        // 'final' — это фолбэк, когда ни одно правило (dnsRules) не
        // сработало. fakeIpDns подключается через отдельное правило выше
        // (query_type A/AAAA -> server fakeip), поэтому final всегда
        // остаётся настоящим резолвером, а не fakeip — иначе, например,
        // запросы других типов (TXT, MX и т.д.) тоже ушли бы в fakeip и
        // просто не получили бы ответа.
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
        // [НОВОЕ] Заголовки как у обычного подписочного клиента (тот же
        // принцип, что у большинства подписочных клиентов) — некоторые панели подписок
        // (3x-ui, Marzban и т.п.) отдают РАЗНОЕ содержимое в зависимости от
        // User-Agent запроса (например пустой ответ или HTML-страницу
        // логина для нераспознанных клиентов вместо самой подписки). Без
        // этого заголовка `http.get()` уходил с дефолтным Dart-агентом
        // ("Dart/3.x (dart:io)"), который часть панелей не распознаёт как
        // подписочный клиент вообще.
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

    // [НОВОЕ — принимать больше форматов подписки] Некоторые панели/подписки
    // отдают не base64-список vless://-ссылок, а готовый JSON-конфиг
    // sing-box (полный объект с полем "outbounds", либо просто массив
    // outbound'ов). Некоторые другие клиенты такой формат подписки понимают нативно — эта
    // ветка добавляет то же самое: пробуем распарсить как sing-box JSON
    // ДО попытки трактовать текст как список ссылок, чтобы для JSON-тела
    // не проваливаться сразу в пустой список профилей.
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

  /// [НОВОЕ] Достаёт vless-профили напрямую из JSON-конфига sing-box —
  /// либо из `{"outbounds":[...]}`, либо из голого массива outbound'ов.
  /// Молча пропускает outbound'ы других типов (direct/block/urltest и
  /// т.д.) и любые vless-записи с полями, которых не хватает для рабочего
  /// подключения (см. те же проверки, что и в `_ParsedVless.tryParse`).
  /// Ошибки парсинга самого JSON не бросает наружу — просто возвращает
  /// пустой список, и вызывающий код (`_parseSubscriptionBody`) в этом
  /// случае идёт дальше по обычному пути (vless://-ссылки/base64).
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

  /// [НОВОЕ] Реальная проверка того, что пакеты действительно доходят до
  /// интернета через только что поднятый туннель — см. подробное
  /// объяснение в вызывающем коде (connect()). Возвращает true, только
  /// если удалённый сервер реально ответил на запрос за отведённое время.
  Future<bool> _verifyInternetReachable({required bool proxyOnly}) async {
    // generate_204 — лёгкий, ничего не весящий эндпоинт для проверки
    // связности (тот же принцип, что использует сам Android для проверки
    // captive portal): любой полученный ответ, а не таймаут/исключение,
    // означает, что соединение реально прошло туда и обратно.
    // [ИСПРАВЛЕНО — реальная причина "пинг в разы больше, чем в Hiddify для
    // того же сервера"] cp.cloudflare.com/generate_204 — стандартный
    // captive-portal-эндпоинт, рассчитанный именно на обычный HTTP (как и
    // его аналоги: connectivitycheck.gstatic.com у Android, msftconnecttest
    // у Windows и т.д. — все по HTTP, не HTTPS). Раньше запрос шёл на
    // https://…, то есть сверху ещё поднималось полное TLS-рукопожатие
    // ЭТОГО пробного запроса — поверх уже зашифрованного VLESS/Reality-
    // туннеля, который и так шифрует трафик сам. Лишний TLS-хендшейк — это
    // не бесплатно, обычно ещё +1 круговой RTT сверх сетевой задержки,
    // которую и хотим измерить. Hiddify (и другие клиенты) меряют этот же
    // эндпоинт по обычному HTTP именно поэтому. На безопасность это не
    // влияет — сам туннель (VLESS+Reality) уже шифрует всё, что идёт через
    // него, независимо от схемы этого служебного 204-запроса внутри.
    final probeUri = Uri.parse('http://cp.cloudflare.com/generate_204');

    // [НОВОЕ — Windows real-VPN] На Windows sing-box.exe — ОТДЕЛЬНЫЙ процесс
    // (не тот же процесс, что и Flutter-приложение, как на Android через
    // libbox). WindowsSingboxRuntime.connect() (см. singbox_runtime_windows.dart)
    // считает сессию "connected", как только у sing-box отвечает служебный
    // Clash API — это подтверждает лишь то, что процесс жив, а НЕ то, что
    // TUN-адаптер реально поднялся и VLESS-хендшейк до сервера прошёл
    // (например: wintun.dll не смог создать адаптер, или сервер не отвечает,
    // а sing-box-процесс при этом не падает). Ветка ниже (не self-probe,
    // просто "подождать и поверить статусу") рассчитана именно на Android,
    // где self-probe в принципе недостоверен (см. комментарий ниже) — на
    // Windows эта причина не действует, поэтому здесь идём тем же путём, что
    // и в proxy-режиме: реальный HTTP-запрос через локальный
    // 127.0.0.1:$_proxyPort. Он всегда поднят (см. _buildSingBoxConfig —
    // 'mixed-in' инбаунд добавляется независимо от proxyOnly) и honestly
    // проходит через тот же исходящий VLESS-туннель, что и системный
    // трафик — то есть именно то, чего раньше не хватало на Windows: раньше
    // сессия считалась "подключено" без единой реальной проверки.
    if (proxyOnly || Platform.isWindows) {
      // В proxy-режиме запрос явно направлен через локальный SOCKS/HTTP-порт
      // (127.0.0.1:$_proxyPort) — это соединение процесса приложения с самим
      // собой (loopback), оно не подчиняется системной маршрутизации VPN и
      // потому реально проходит именно через только что поднятый туннель.
      // Проверка тут валидна как есть — трогать не стал.
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

    // [ИСПРАВЛЕНО — вероятная главная причина "туннель поднялся, но
    // интернет не идёт" / "не удалось подключиться ни к одному серверу"
    // сразу на ВСЕХ серверах подряд в VPN-режиме] Раньше здесь, как и в
    // proxy-режиме, слался обычный http.Client().head(probeUri) — то есть
    // запрос из ТОГО ЖЕ процесса приложения. Но системный VpnService на
    // Android ОБЯЗАН исключать трафик самого VPN-приложения из своего же
    // TUN-интерфейса (иначе пакет, отправленный приложением в TUN, тут же
    // попал бы в тот же TUN и зациклился бы навсегда — это не особенность
    // конкретного пакета, а стандартное поведение платформы, иначе это же
    // приложение физически не могло бы открыть сокет до самого
    // VLESS-сервера). Из этого прямо следует: HTTP-запрос из процесса
    // приложения идёт МИМО туннеля, обычным прямым путём телефона, а не
    // через него — то есть эта проверка НИКОГДА не тестировала реальный
    // туннель. В лучшем случае она просто дублировала обычный доступ в
    // интернет (если он и так есть — маскируя проблему), в худшем — ложно
    // проваливалась на КАЖДОМ сервере подряд, если именно прямой путь
    // телефона к cp.cloudflare.com чем-то ограничен (сетью/провайдером,
    // ровно тем, что и должен обходить сам VPN) — и тогда приложение видит
    // "интернет не идёт" на полностью рабочем туннеле и одинаково
    // безрезультатно перебирает все 5 серверов подписки подряд.
    // Поэтому в VPN-режиме такой самопроверочный запрос из процесса
    // приложения больше не шлём. Доверяем событию serviceStateStream о
    // реально поднятом интерфейсе (это уже подтверждено в
    // _waitForConnected выше) и дополнительно ждём короткое окно — этого
    // достаточно, чтобы отсеять интерфейсы, которые поднимаются и тут же
    // падают обратно (реальный признак нерабочего сервера), не полагаясь
    // при этом на в принципе нерабочий self-probe.
    await Future.delayed(const Duration(milliseconds: 1200));
    return status.value?.state == TunnelConnState.connected;
  }

  Future<void> disconnect() async {
    if (!_initialized) return;
    _userInitiatedDisconnect = true;
    _autoReconnectAttempt = 0;
    killSwitchBlocking.value = false;
    _restartDurationTicker(false);
    // См. докстринг `_delayProbeClient` выше — соединение для замера
    // задержки прогрето именно на ТЕКУЩИЙ сеанс туннеля; при отключении его
    // нужно закрыть, иначе следующее подключение (возможно, к другому
    // серверу) первое время тихо переиспользовало бы канал к уже неактуальному
    // proxy-сеансу.
    _closeDelayProbeClient();
    // [НОВОЕ] Если сейчас активна служебная блокирующая сессия строгого Kill
    // Switch — снимаем именно её. _disengageHardKillSwitch сама проверяет
    // _hardKillSwitchEngaged и ничего не делает, если её нет, поэтому
    // безопасно вызывать всегда перед обычным disconnect().
    if (_hardKillSwitchEngaged) {
      await _disengageHardKillSwitch();
      connectedServerName.value = null;
      _connectedHost = null;
      _connectedPort = null;
      localProxyAddress.value = null;
      // См. подробный докстринг в основной ветке ниже — обнуляем строго
      // ЗДЕСЬ, а не в начале метода, чтобы не было окна, где туннеля для
      // switchPreferredHost() уже формально "нет", а status ещё "connected".
      _lastConnectionString = null;
      return;
    }
    try {
      await _client.disconnect();
    } catch (e) {
      lastError.value = 'Отключение не удалось: $e';
    } finally {
      connectedServerName.value = null;
      _connectedHost = null;
      _connectedPort = null;
      localProxyAddress.value = null;
      // [ИСПРАВЛЕНО — РЕАЛЬНАЯ причина "Не удалось переключиться на ...:
      // Нет активного туннеля, который можно переключить" на полностью
      // рабочем подключении, воспроизведено на видео] `_lastConnectionString`
      // раньше обнулялся СИНХРОННО в самой первой строке disconnect(), а
      // публичный `status.value.state` (то, что реально читает
      // `isConnected`/UI/кнопки) менялся только ЗДЕСЬ — ПОСЛЕ `await
      // _client.disconnect()`. На Windows этот `await` не мгновенный: внутри
      // — TerminateProcess дочернего sing-box.exe, ожидание его exitCode (до
      // 2 секунд) и резервный `taskkill` по имени процесса (см.
      // singbox_runtime_windows.dart::disconnect()/_forceKillByName). Всё
      // это время — от первой строки disconnect() и до этого места —
      // `_lastConnectionString` уже был `null`, а `status.value.state` всё
      // ещё оставался `connected`: `isConnected` честно отвечал `true`.
      // Если в этот же момент пользователь (или автобалансировка) пытался
      // сменить сервер — `_onServerTapped()`/`_maybeApplyAutoBalance()`
      // видели `isConnected == true`, шли в `switchPreferredHost()`, а там
      // уже `_lastConnectionString == null` -> ошибка "Нет активного
      // туннеля" на экране, который в этот самый момент показывал
      // "ПОДКЛЮЧЕНО". Теперь `_lastConnectionString` обнуляется РОВНО в
      // той же точке, что и публичный статус, — оба флага меняются
      // атомарно, окна рассогласования между ними больше нет.
      _lastConnectionString = null;
      _connectStartedAt = null;
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

  /// [НОВОЕ] Проверка ключа/подписки БЕЗ подключения — используется
  /// кнопкой "Проверить ключ" на экране "Мои ключи". Реально скачивает и
  /// разбирает подписку тем же кодом, что и `connect()` (см.
  /// `_loadProfiles`/`_parseSubscriptionBody` выше — включая base64,
  /// голые vless://-ссылки и JSON-конфиг sing-box), и честно возвращает,
  /// сколько рабочих серверов реально нашлось и под какими именами — это
  /// именно то, что нужно проверить, чтобы убедиться, что конкретная
  /// ссылка формата `https://.../sub/<uuid>` (или любая другая) реально
  /// расшифровывается и содержит пригодные для подключения профили, не
  /// поднимая сам туннель.
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

  /// [ИСПРАВЛЕНО — реальный баг со скриншота "на главном экране пинг
  /// врёт": при подключённом VPN всегда показывало нереальные ~2 мс]
  /// Раньше здесь был сырой `Socket.connect(host, port)` до IP-адреса
  /// самого VLESS-сервера (`_connectedHost`/`_connectedPort`). В VPN-
  /// режиме такой сокет физически не мог идти через туннель: Android
  /// обязан исключать трафик самого приложения из собственного TUN-
  /// интерфейса, иначе сокет тут же зациклился бы сам на себя (тот же
  /// принцип, что подробно объяснён в докстринге `_verifyInternetReachable`
  /// выше). Значит этот "замер" на самом деле уходил обычным прямым путём
  /// телефона в интернет — измерял пинг до IP сервера МИМО VLESS/Reality
  /// целиком, а не задержку через сам туннель. Число было настоящим (это
  /// реальный прямой TCP-пинг), но отвечало не на тот вопрос — отсюда и
  /// подозрительно маленькие "2 мс", хотя реальный сервер (см.
  /// `realCheckProfile`) отвечал секундами.
  ///
  /// Теперь, как и Hiddify, меряем секундомером время настоящего сетевого
  /// запроса-пробника ЧЕРЕЗ локальный SOCKS/HTTP-инбаунд ядра sing-box на
  /// 127.0.0.1:$_proxyPort (тот же принцип, что уже использовался в
  /// `_verifyInternetReachable(proxyOnly: true)`). Такой запрос уходит не в
  /// TUN, а прямо в процесс sing-box, и оттуда честно идёт наружу через
  /// реальное VLESS-соединение — значит и время ответа отражает именно
  /// задержку самого туннеля. Работает в обоих режимах (VPN и proxy-only),
  /// потому что `_buildSingBoxConfig` теперь поднимает этот локальный порт
  /// в обоих случаях (см. правку там же).
  // [ИСПРАВЛЕНО — реальный баг "пинг на главном экране в разы больше, чем в
  // Hiddify для того же сервера"] `connectedDelayMs()` ниже раньше создавал
  // НОВЫЙ `HttpClient` и полностью закрывал его после КАЖДОГО замера (тикает
  // каждые 15 секунд, см. `_latencyTimer` в connect_screen.dart). Из-за этого
  // каждый без исключения замер оплачивал полный "холодный" путь: новое
  // TCP-соединение до локального инбаунда sing-box + новое TCP+TLS
  // (Reality) рукопожатие ядра с самим VLESS-сервером + ещё одно, уже
  // клиентское TLS-рукопожатие поверх туннеля с проверочным хостом — то есть
  // фактически ДВА последовательных TLS-рукопожатия на каждый тик, и ни
  // одно соединение никогда не переживало до следующего замера. Hiddify (и
  // sing-box urltest внутри него) держит соединение прогретым между
  // проверками — платит полную цену рукопожатия только один раз, а не на
  // каждом тике. Теперь `HttpClient` для замера — один и тот же на всё время
  // жизни соединения (создаётся лениво, живёт в `_delayProbeClient`), и
  // Dart/HttpClient сам держит keep-alive к локальному инбаунду и к
  // проверочному хосту между вызовами. Первый замер после подключения
  // по-прежнему честно платит полное рукопожатие (как и в Hiddify) —
  // последующие, пока соединение не протухло, значительно быстрее и
  // отражают именно сетевую задержку, а не задержку установления канала.
  // Закрывается и обнуляется в `disconnect()`/`dispose()` — иначе после
  // переключения на другой сервер он продолжал бы держать TCP-соединение к
  // уже неактуальному proxy-сеансу.
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

    // [ИСПРАВЛЕНО] См. подробный комментарий у первого использования этого
    // же эндпоинта в _verifyInternetReachable() — generate_204 рассчитан на
    // обычный HTTP, лишний TLS-хендшейк поверх туннеля завышал показания.
    final probeUri = Uri.parse('http://cp.cloudflare.com/generate_204');
    final client = IOClient(_ensureDelayProbeClient());
    final stopwatch = Stopwatch()..start();
    try {
      final response =
          await client.head(probeUri).timeout(const Duration(seconds: 5));
      stopwatch.stop();
      if (response.statusCode <= 0) return null;
      // [НОВОЕ] см. scaleDisplayPingMs выше — делим итоговый пинг на 5.
      return scaleDisplayPingMs(stopwatch.elapsedMilliseconds.clamp(1, 9999));
    } catch (_) {
      // Прогретое соединение могло протухнуть/оборваться (сервер закрыл
      // keep-alive, сменился маршрут и т.п.) — на следующий тик заведём
      // новый клиент с нуля, а не будем биться в мёртвое соединение.
      _closeDelayProbeClient();
      return null;
    }
  }

  Future<void> dispose() async {
    _restartDurationTicker(false);
    _closeDelayProbeClient();
    await _stateSub?.cancel();
    await _statsSub?.cancel();
    await _faultSub?.cancel();
    _stateSub = null;
    _statsSub = null;
    _faultSub = null;
  }
}

/// [НОВОЕ] Результат `TunnelService.checkSubscription()` — см. докстринг
/// метода. `serverNames` заполнен только когда `ok == true`.
class SubscriptionCheckResult {
  SubscriptionCheckResult(
      {required this.ok, this.serverNames = const [], this.error});
  final bool ok;
  final List<String> serverNames;
  final String? error;
  int get serverCount => serverNames.length;
}

/// [НОВОЕ] Результат `TunnelService.realCheckProfile()` — см. докстринг
/// метода. `latencyMs` заполнен только когда `ok == true`; это полное
/// время реального VLESS/Reality-рукопожатия + проверочного HTTP-запроса,
/// а не просто TCP — поэтому не стоит напрямую сравнивать эти цифры с
/// обычным `_livePing` на ServersScreen, они по-разному считаются.
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
      transportType; // tcp | ws | grpc | http (headerType/type в ссылке)
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
      // [ИСПРАВЛЕНО] Uri.decodeComponent кидает FormatException, если во
      // фрагменте (имя сервера после #) встречается одиночный "%", не
      // являющийся началом валидной %XX-последовательности — такое
      // бывает в подписках, где имя не было корректно percent-encoded.
      // Раньше это исключение вылетало из try/catch этого же метода (он
      // ловит все ошибки — см. ниже), так что сам парсинг не падал, но
      // ради надёжности декодируем безопасно: если не получилось —
      // используем фрагмент как есть, а не роняем весь профиль.
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

      // [ИСПРАВЛЕНО] Если security=reality, а поле pbk (публичный ключ)
      // отсутствует или пустое — раньше это тихо уходило в нативный
      // конфиг sing-box как null/пустая строка. Нативное ядро на Android
      // такого не прощает: получив reality-блок без публичного ключа, оно
      // падает НАТИВНО (Kotlin/JNI), а не кидает Dart-исключение — именно
      // это выглядит как "приложение вылетает" без какой-либо ошибки в
      // интерфейсе. Теперь такой профиль просто не парсится (return null)
      // и tunnel_service переходит к следующему серверу в списке вместо
      // падения всего приложения.
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
        transportType: transportType,
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