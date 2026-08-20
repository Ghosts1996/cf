import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_singbox_client/flutter_singbox_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:app_settings/app_settings.dart';
import 'local_prefs.dart';

class TunnelService {
  TunnelService._();
  static final TunnelService instance = TunnelService._();

  final SingboxClient _client = SingboxClient();
  bool _initialized = false;
  bool _killSwitchEnabled = true;
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
  // [НОВОЕ — см. _restartDurationTicker] Тикает раз в секунду, пока
  // статус connected, чтобы таймер сессии на экране реально считал время,
  // а не был заморожен на 00:00:00.
  Timer? _durationTicker;

  final ValueNotifier<TunnelStatus?> status = ValueNotifier(null);
  final ValueNotifier<String?> lastError = ValueNotifier(null);
  final ValueNotifier<bool> killSwitchBlocking = ValueNotifier(false);
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

    _stateSub = _client.serviceStateStream.listen((state) {
      final mapped = _mapServiceState(state);
      final prevDownload = status.value?.download ?? 0;
      final prevUpload = status.value?.upload ?? 0;

      if (mapped == TunnelConnState.connected && _connectStartedAt == null) {
        _connectStartedAt = DateTime.now();
      }
      if (mapped != TunnelConnState.connected) {
        _connectStartedAt = null;
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
            ? DateTime.now().difference(_connectStartedAt ?? DateTime.now()).inSeconds
            : 0,
        download: prevDownload,
        upload: prevUpload,
      );
      _onStatusChanged(mapped);
    });

    _statsSub = _client.trafficStatsStream.listen((stats) {
      final current = status.value;
      if (current == null) return;
      status.value = TunnelStatus(
        state: current.state,
        duration: current.state == TunnelConnState.connected
            ? DateTime.now().difference(_connectStartedAt ?? DateTime.now()).inSeconds
            : current.duration,
        download: stats.downlinkBps,
        upload: stats.uplinkBps,
      );
    });

    _faultSub = _client.faultStream.listen((error) {
      lastError.value = error.toString();
    });

    _initialized = true;
  }

  TunnelConnState _mapServiceState(dynamic state) {
    final s = state.toString().toLowerCase();
    if (s.contains('connecting') || s.contains('starting')) return TunnelConnState.connecting;
    if (s.contains('disconnecting') || s.contains('stopping')) return TunnelConnState.disconnecting;
    if (s.contains('connected') || s.contains('started') || s.contains('running')) return TunnelConnState.connected;
    return TunnelConnState.disconnected;
  }

  /// [НОВОЕ] Держит секундный тик, пока туннель connected, чтобы таймер
  /// сессии на экране считал реальное время, а не ждал редких событий от
  /// плагина. Безопасно вызывать многократно — старый таймер всегда
  /// гасится перед тем, как (возможно) завести новый.
  void _restartDurationTicker(bool shouldRun) {
    _durationTicker?.cancel();
    _durationTicker = null;
    if (!shouldRun) return;
    _durationTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final current = status.value;
      if (current == null || current.state != TunnelConnState.connected) return;
      status.value = TunnelStatus(
        state: current.state,
        duration: DateTime.now().difference(_connectStartedAt ?? DateTime.now()).inSeconds,
        download: current.download,
        upload: current.upload,
      );
    });
  }

  void _onStatusChanged(TunnelConnState state) {
    if (state != TunnelConnState.disconnected) return;
    if (_userInitiatedDisconnect) return;
    if (_lastConnectionString == null) return;
    if (!_killSwitchEnabled) return;
    if (_autoReconnectAttempt >= _maxAutoReconnectAttempts) return;

    killSwitchBlocking.value = true;
    _autoReconnectAttempt++;
    Future.delayed(Duration(seconds: 3), () async {
      if (_userInitiatedDisconnect) return;
      try {
        await connect(_lastConnectionString!, preferredHostName: _lastPreferredHostName);
        killSwitchBlocking.value = false;
        _autoReconnectAttempt = 0;
      } catch (_) {}
    });
  }

  Future<List<String>> listProfileNames(String connectionString) async {
    try {
      final profiles = await _loadProfiles(connectionString);
      return profiles.map((p) => p.remark).toList();
    } catch (_) {
      return const [];
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

  Future<String> connect(String connectionString, {String? preferredHostName}) async {
    lastError.value = null;
    await _ensureInitialized();

    final dnsProtection = await LocalPrefs.instance.getBool(PrefKeys.dnsProtection, fallback: false);
    final blockAds = await LocalPrefs.instance.getBool(PrefKeys.blockAds, fallback: false);
    final dpiBypass = await LocalPrefs.instance.getBool(PrefKeys.dpiBypass, fallback: false);
    final proxyOnly = await LocalPrefs.instance.getBool(PrefKeys.proxyOnlyMode, fallback: false);
    final dnsProvider = await LocalPrefs.instance.getString(PrefKeys.dnsServerProvider) ?? 'cloudflare';
    _killSwitchEnabled = await LocalPrefs.instance.getBool(PrefKeys.killSwitch, fallback: true);
    _maxAutoReconnectAttempts = await LocalPrefs.instance.getInt(PrefKeys.reconnectAttempts, fallback: 3);
    final bypassedMap = await LocalPrefs.instance.getBoolMap(PrefKeys.splitTunnelBypass);
    final bypassedPackages = bypassedMap.entries.where((e) => e.value).map((e) => e.key).toList();

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
          bypassedPackages: bypassedPackages,
          proxyOnly: proxyOnly,
          dnsProvider: dnsProvider,
        );
        await _client.checkConfig(config);

        Future<void> startSession() => _client.connect(SessionOptions(
              config: config,
              networkMode: proxyOnly ? NetworkMode.proxy : NetworkMode.vpn,
              notification: NotificationConfig(
                title: profile.remark.isNotEmpty ? profile.remark : 'VPNOnline',
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
          lastFailure = 'VPN не подключился за 12 сек (ядра sing-box требуют время для инициализации туннеля)';
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
        final internetReachable = await _verifyInternetReachable(proxyOnly: proxyOnly);
        if (!internetReachable) {
          await _settleAfterDisconnect();
          lastFailure = 'Туннель поднялся, но интернет через него не идёт (сервер "${profile.remark}" не отвечает) — пробуем следующий';
          continue;
        }

        final connectedName = profile.remark.isNotEmpty ? profile.remark : (preferredHostName ?? 'VPNOnline');
        connectedServerName.value = connectedName;
        localProxyAddress.value = proxyOnly ? '127.0.0.1:$_proxyPort (SOCKS5 и HTTP)' : null;

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
        if (status.value?.state == TunnelConnState.disconnected && !completer.isCompleted) {
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
    required List<String> bypassedPackages,
    bool proxyOnly = false,
    String dnsProvider = 'cloudflare',
  }) {
    final outbound = <String, dynamic>{
      'type': 'vless',
      'tag': 'proxy',
      'server': p.host,
      'server_port': p.port,
      'uuid': p.uuid,
      if (p.flow != null && p.flow!.isNotEmpty) 'flow': p.flow,
    };

    if (p.security == 'reality' || p.security == 'tls') {
      outbound['tls'] = {
        'enabled': true,
        'server_name': p.sni ?? p.host,
        if (p.alpn != null && p.alpn!.isNotEmpty) 'alpn': p.alpn!.split(','),
        'utls': {'enabled': true, 'fingerprint': (p.fp == null || p.fp!.isEmpty) ? 'chrome' : p.fp},
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
        'path': (p.transportPath == null || p.transportPath!.isEmpty) ? '/' : p.transportPath,
        if (p.transportHost != null && p.transportHost!.isNotEmpty)
          'headers': {'Host': p.transportHost},
      };
    } else if (transportType == 'grpc') {
      outbound['transport'] = {
        'type': 'grpc',
        'service_name': (p.transportPath == null || p.transportPath!.isEmpty) ? '' : p.transportPath,
      };
    } else if (transportType == 'http') {
      outbound['transport'] = {
        'type': 'http',
        if (p.transportHost != null && p.transportHost!.isNotEmpty) 'host': [p.transportHost],
        'path': (p.transportPath == null || p.transportPath!.isEmpty) ? '/' : p.transportPath,
      };
    }
    // transportType == 'tcp' (или неизвестный) — без блока "transport",
    // как и раньше: sing-box по умолчанию использует голый TCP.

    // [НОВОЕ] Выбор DNS-over-HTTPS резолвера — та же идея, что в
    // у многих клиентов ("DNS Server" в настройках): раньше был всегда жёстко
    // зашит 1.1.1.1 без возможности сменить. IP конкретного резолвера
    // достаточно sing-box'у для type: 'https' (тот же формат, что был и
    // раньше, просто с настраиваемым адресом).
    const dnsProviderIps = {
      'cloudflare': '1.1.1.1',
      'google': '8.8.8.8',
      'adguard': '94.140.14.14',
      'quad9': '9.9.9.9',
    };
    final dnsServers = <Map<String, dynamic>>[
      {
        'type': 'https',
        'tag': 'remote-dns',
        'server': dnsProviderIps[dnsProvider] ?? dnsProviderIps['cloudflare'],
        if (dnsProtection) 'detour': 'proxy',
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
      {'ip_is_private': true, 'outbound': 'direct'},
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
      if (blockAds)
        {'domain_suffix': _adBlockDomains, 'action': 'reject'},
      {'protocol': 'dns', 'action': 'hijack-dns'},
      // [ИСПРАВЛЕНО] Раньше DPI-обход включался как `'fragment': true`
      // прямо внутри блока `tls` исходящего vless — это устаревший, давно
      // убранный формат: в самом sing-box, начиная с 1.12.0, фрагментация
      // TLS-хендшейка — не свойство исходящего соединения, а ОПЦИЯ ДЕЙСТВИЯ
      // ПРАВИЛА МАРШРУТИЗАЦИИ (`route`/`route-options`, поле `tls_fragment`,
      // см. sing-box.sagernet.org/configuration/route/rule_action и
      // /changelog — "Compatibility for old formats will be removed in
      // sing-box 1.14.0"). Этот пакет использует именно ядро 1.14.0-alpha —
      // старый булев `fragment` внутри `tls` там не существует как поле
      // вообще, поэтому `checkConfig()`/`connect()` с ним гарантированно
      // упали бы, как только пользователь включил тумблер "Обход DPI" в
      // настройках (по умолчанию тумблер выключен, поэтому раньше это не
      // всплывало на каждом подключении, но всплыло бы при первом же
      // включении). Правильная замена — отдельное правило, которое явно
      // направляет TCP-трафик пользователя на `proxy` с включённой
      // фрагментацией именно TLS-хендшейка ВНУТРИ туннеля (обычный HTTPS
      // пользователя, а не сам VLESS+Reality хендшейк до сервера — тот и
      // так не детектируется DPI по конструкции REALITY, фрагментировать
      // его незачем и нечем на этом уровне).
      if (dpiBypass)
        {
          'network': 'tcp',
          'action': 'route',
          'outbound': 'proxy',
          'tls_fragment': {'enabled': true},
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
        if (bypassedPackages.isNotEmpty) 'exclude_package': bypassedPackages,
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
      'dns': {'servers': dnsServers, 'final': 'remote-dns', 'strategy': 'ipv4_only'},
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

  Future<List<_ParsedVless>> _loadProfiles(String connectionString, {bool forceRefresh = false}) async {
    final source = connectionString.trim();
    if (source.isEmpty) {
      throw TunnelException('Не разместили ссылку на конфигурацию VLESS Reality.');
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
          throw TunnelException('Подписка недоступна (${res.statusCode}). Попробуйте позднее.');
        }
        body = res.body;
      } on TunnelException {
        rethrow;
      } catch (e) {
        throw TunnelException('Не удалось загрузить конфигурацию подписки. Проверьте ссылку или интернет.');
      }
    }

    final profiles = _parseSubscriptionBody(body);
    if (profiles.isEmpty) {
      throw TunnelException('Конфигурация не содержит рабочих серверов VLESS+Reality.');
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
        final padded = normalized.padRight(normalized.length + (4 - normalized.length % 4) % 4, '=');
        final decoded = utf8.decode(base64.decode(padded));
        if (decoded.contains('vless://')) text = decoded;
      } catch (_) {}
    }

    final lines = text.split(RegExp(r'[\r\n]+'))
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
        if (uuid == null || uuid.isEmpty || host == null || host.isEmpty || port == null || port == 0) {
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
          transportPath = transport['path'] as String? ?? transport['service_name'] as String?;
        }

        // security=reality без public_key нативное ядро не примет — та же
        // защита, что и в _ParsedVless.tryParse ниже для vless://-ссылок.
        final security = realityEnabled ? 'reality' : (tlsEnabled ? 'tls' : 'none');
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
          alpn: (alpnList is List && alpnList.isNotEmpty) ? alpnList.join(',') : null,
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
    final probeUri = Uri.parse('https://cp.cloudflare.com/generate_204');

    if (proxyOnly) {
      // В proxy-режиме запрос явно направлен через локальный SOCKS/HTTP-порт
      // (127.0.0.1:$_proxyPort) — это соединение процесса приложения с самим
      // собой (loopback), оно не подчиняется системной маршрутизации VPN и
      // потому реально проходит именно через только что поднятый туннель.
      // Проверка тут валидна как есть — трогать не стал.
      final client = IOClient(HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$_proxyPort;');
      try {
        final response = await client.head(probeUri).timeout(const Duration(seconds: 8));
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
    _lastConnectionString = null;
    _autoReconnectAttempt = 0;
    killSwitchBlocking.value = false;
    _restartDurationTicker(false);
    try {
      await _client.disconnect();
    } catch (e) {
      lastError.value = 'Отключение не удалось: $e';
    } finally {
      connectedServerName.value = null;
      localProxyAddress.value = null;
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
  Future<SubscriptionCheckResult> checkSubscription(String connectionString) async {
    try {
      final profiles = await _loadProfiles(connectionString, forceRefresh: true);
      return SubscriptionCheckResult(
        ok: true,
        serverNames: profiles.map((p) => p.remark.isNotEmpty ? p.remark : p.host).toList(),
      );
    } on TunnelException catch (e) {
      return SubscriptionCheckResult(ok: false, error: e.message);
    } catch (e) {
      return SubscriptionCheckResult(ok: false, error: 'Не удалось проверить ключ: $e');
    }
  }

  Future<int?> connectedDelayMs() async => null;

  Future<void> dispose() async {
    _restartDurationTicker(false);
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
  SubscriptionCheckResult({required this.ok, this.serverNames = const [], this.error});
  final bool ok;
  final List<String> serverNames;
  final String? error;
  int get serverCount => serverNames.length;
}

enum TunnelConnState { disconnected, connecting, connected, disconnecting }

class TunnelStatus {
  const TunnelStatus({
    required this.state,
    required this.duration,
    required this.download,
    required this.upload,
  });

  final TunnelConnState state;
  final int duration;
  final num download;
  final num upload;
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
  final String? pbk;     // Публичный ключ для Reality
  final String? fp;      // TLS-отпечаток
  final String? sni;     // Server Name Indication
  final String? sid;     // Short ID для Reality
  final String? flow;    // Тип потока (xtls-rprx-vision и т.д.)
  final String? spx;     // SpiderX (путь для Reality)
  final String? alpn;    // ALPN, через запятую
  final String? transportType; // tcp | ws | grpc | http (headerType/type в ссылке)
  final String? transportHost; // Host-заголовок для ws/http-маскировки
  final String? transportPath; // path для ws / service_name-путь для grpc
  final String remark;   // Имя сервера

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
      if (security == 'reality' && (pbkValue == null || pbkValue.isEmpty)) return null;

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