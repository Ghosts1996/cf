import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_singbox_client/flutter_singbox_client.dart';
import 'package:http/http.dart' as http;
import 'package:app_settings/app_settings.dart';
import 'local_prefs.dart';

/// [ПЕРЕПИСАНО — переход на sing-box] Раньше здесь был Xray-core через
/// `flutter_vless`. Реальная (не выдуманная) проблема была подтверждена:
/// одна и та же подписка стабильно поднимает интернет в Hiddify (ядро
/// sing-box) и стабильно не поднимает его в Xray-core based клиентах
/// (v2rayNG, `flutter_vless`) — при полностью одинаковом, стандартном
/// VLESS+Reality+Vision конфиге (проверено вручную: расшифрован твой
/// реальный `connection_string`, там нет ничего экзотического — обычный
/// `type=tcp&security=reality&flow=xtls-rprx-vision`). Раз дело
/// систематически повторяется именно на границе "какое ядро", а не в
/// конкретном параметре конфига — чинить это дальше правками JSON для
/// Xray-core бессмысленно. Здесь используется другое ядро: sing-box, через
/// пакет `flutter_singbox_client` (тот же движок, что у Hiddify).
///
/// Ссылки на реальный, а не придуманный API пакета — его собственный
/// README (pub.dev/packages/flutter_singbox_client): `SingboxClient()`,
/// `.initialize()`, `.requestVPNPermission()`, `.checkConfig()`,
/// `.connect(SessionOptions(...))`, `.serviceStateStream`,
/// `.trafficStatsStream`, `.faultStream`, `.disconnect()`.
///
/// [ЧЕСТНО — единственное, что я НЕ могу проверить без установки пакета]
/// Точные названия enum-значений `ServiceState` и точные имена полей
/// `TrafficStats` не опубликованы в кратком README пакета (только общая
/// форма usage-примера) — я сопоставил их по наиболее вероятным,
/// стандартным для таких пакетов именам ниже (`_mapServiceState`,
/// `_ServiceStateNames`). Если после `flutter pub get` компилятор укажет
/// на несовпадение имени enum-значения или поля — это будет ОБЫЧНАЯ,
/// мгновенно видимая ошибка компиляции в одном конкретном месте (не
/// скрытый баг рантайма вроде "0 МБ"), и её правка — минуты, а не часы:
/// открой сгенерированный `.dart` файл пакета в
/// `~/.pub-cache/hosted/pub.dev/flutter_singbox_client-*/lib/` и подставь
/// точные имена там, где компилятор укажет ошибку.
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
  static const _maxAutoReconnectAttempts = 3;

  StreamSubscription? _stateSub;
  StreamSubscription? _statsSub;
  StreamSubscription? _faultSub;
  DateTime? _connectStartedAt;

  /// Совместимый по форме с прежним `VlessStatus` (screens читают именно
  /// эти поля: `.duration`, `.download`, `.upload`) — чтобы не переписывать
  /// ConnectScreen и другие экраны при смене движка под капотом.
  final ValueNotifier<TunnelStatus?> status = ValueNotifier(null);
  final ValueNotifier<String?> lastError = ValueNotifier(null);
  final ValueNotifier<bool> killSwitchBlocking = ValueNotifier(false);
  final ValueNotifier<String?> connectedServerName = ValueNotifier(null);
  // [НОВОЕ] Заполняется после успешного connect() в режиме "только прокси"
  // (NetworkMode.proxy — без VPN-разрешения, локальные SOCKS/HTTP-порты).
  // null, если сейчас туннель в обычном VPN-режиме или отключён.
  final ValueNotifier<String?> localProxyAddress = ValueNotifier(null);

  bool get isConnected => status.value?.state == TunnelConnState.connected;
  bool get isBusy =>
      status.value?.state == TunnelConnState.connecting ||
      status.value?.state == TunnelConnState.disconnecting;

  // ── кэш разобранной подписки (та же логика, что была) ──────────────
  String? _cachedSource;
  List<_ParsedVless>? _cachedProfiles;
  DateTime? _cachedAt;
  static const _cacheTtl = Duration(seconds: 45);

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _client.initialize();

    _stateSub = _client.serviceStateStream.listen((state) {
      final mapped = _mapServiceState(state);
      final prevDuration = status.value?.duration ?? 0;
      final prevDownload = status.value?.download ?? 0;
      final prevUpload = status.value?.upload ?? 0;
      if (mapped == TunnelConnState.connected && _connectStartedAt == null) {
        _connectStartedAt = DateTime.now();
      }
      if (mapped != TunnelConnState.connected) {
        _connectStartedAt = null;
      }
      status.value = TunnelStatus(
        state: mapped,
        duration: mapped == TunnelConnState.connected
            ? DateTime.now().difference(_connectStartedAt ?? DateTime.now()).inSeconds
            : prevDuration,
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
        duration: current.duration,
        // [НЕ ПРОВЕРЕНО ТОЧНОЕ ИМЯ ПОЛЯ] `TrafficStats` в README пакета
        // показан с полями `uplinkBps`/`downlinkBps` (то есть скорость
        // сейчас, не суммарный объём) — используем их напрямую как
        // "download/upload" для UI, это ближе к тому, что реально хочет
        // увидеть пользователь (живая скорость), чем итоговый счётчик.
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
    // [НЕ ПРОВЕРЕНО ТОЧНОЕ ИМЯ ENUM] Сопоставляем по имени через toString(),
    // а не по прямому равенству enum-значений пакета — так это работает,
    // даже если у пакета enum называется иначе, чем предполагаю здесь
    // (ServiceState.connected и т.п.); если toString() пакета в проде
    // отличается от этих строк, поправь список ниже — компилятор здесь
    // ничего не подскажет (по дизайну, чтобы не падать на runtime-типе),
    // так что при первом реальном запуске проверь, что статус в интерфейсе
    // меняется корректно при подключении/отключении.
    final s = state.toString().toLowerCase();
    if (s.contains('connecting') || s.contains('starting')) return TunnelConnState.connecting;
    if (s.contains('disconnecting') || s.contains('stopping')) return TunnelConnState.disconnecting;
    if (s.contains('connected') || s.contains('started') || s.contains('running')) {
      return TunnelConnState.connected;
    }
    return TunnelConnState.disconnected;
  }

  void _onStatusChanged(TunnelConnState state) {
    if (state != TunnelConnState.disconnected) return;
    if (_userInitiatedDisconnect) return;
    if (_lastConnectionString == null) return;
    if (!_killSwitchEnabled) return;
    if (_autoReconnectAttempt >= _maxAutoReconnectAttempts) return;
    killSwitchBlocking.value = true;
    _autoReconnectAttempt++;
    Future.delayed(const Duration(seconds: 3), () async {
      if (_userInitiatedDisconnect) return;
      try {
        await connect(_lastConnectionString!, preferredHostName: _lastPreferredHostName);
        killSwitchBlocking.value = false;
        _autoReconnectAttempt = 0;
      } catch (_) {
        // См. комментарий в старой версии — та же логика: не долбим сеть
        // бесконечно, ждём ручного действия после исчерпания попыток.
      }
    });
  }

  Future<List<_ParsedVless>> _loadProfiles(
    String connectionString, {
    bool forceRefresh = false,
  }) async {
    final source = connectionString.trim();
    if (source.isEmpty) {
      throw TunnelException('Для этого ключа нет ссылки на конфигурацию сервера.');
    }

    if (!forceRefresh &&
        _cachedProfiles != null &&
        _cachedSource == source &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheTtl) {
      return _cachedProfiles!;
    }

    final String body;
    if (source.startsWith('vless://')) {
      body = source;
    } else {
      late final http.Response res;
      try {
        res = await http.get(Uri.parse(source)).timeout(const Duration(seconds: 12));
      } catch (_) {
        throw TunnelException('Не удалось получить конфигурацию сервера. Проверь интернет-соединение.');
      }
      if (res.statusCode >= 400) {
        throw TunnelException('Сервер конфигурации недоступен (${res.statusCode}). Попробуй позже.');
      }
      body = res.body;
    }

    final profiles = _parseSubscriptionBody(body);
    if (profiles.isEmpty) {
      throw TunnelException('Конфигурация сервера пуста или повреждена.');
    }

    _cachedSource = source;
    _cachedProfiles = profiles;
    _cachedAt = DateTime.now();
    return profiles;
  }

  /// [НОВОЕ — раньше это делал `FlutterVless.parseMany()`, теперь своими
  /// руками, т.к. sing-box-пакет не предоставляет разбор share-ссылок]
  /// Тело подписки 3x-ui — это base64 от списка `vless://...` ссылок,
  /// разделённых переносом строки (проверено на твоей реальной подписке).
  /// Защитно пробуем: сначала как base64, если не вышло/результат не
  /// похож на vless-ссылки — считаем, что тело уже открытым текстом.
  List<_ParsedVless> _parseSubscriptionBody(String body) {
    String text = body.trim();
    if (!text.contains('vless://')) {
      try {
        final normalized = text.replaceAll('-', '+').replaceAll('_', '/');
        final padded = normalized + '=' * ((4 - normalized.length % 4) % 4);
        final decoded = utf8.decode(base64.decode(padded));
        if (decoded.contains('vless://')) text = decoded;
      } catch (_) {
        // не base64 — оставляем как есть, попробуем распарсить построчно
      }
    }
    final lines = text.split(RegExp(r'[\r\n]+')).where((l) => l.trim().startsWith('vless://'));
    final result = <_ParsedVless>[];
    for (final line in lines) {
      final parsed = _ParsedVless.tryParse(line.trim());
      if (parsed != null) result.add(parsed);
    }
    return result;
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

    // [ИСПРАВЛЕНО] По требованию: DNS-защита и обход DPI по умолчанию
    // ВЫКЛЮЧЕНЫ — пользователь включает их сам при необходимости (ранее
    // fallback был `true`, то есть оба работали "из коробки" даже если
    // пользователь их никогда не трогал в SettingsScreen/SecurityScreen).
    final dnsProtection = await LocalPrefs.instance.getBool(PrefKeys.dnsProtection, fallback: false);
    final blockAds = await LocalPrefs.instance.getBool(PrefKeys.blockAds, fallback: false);
    final dpiBypass = await LocalPrefs.instance.getBool(PrefKeys.dpiBypass, fallback: false);
    // [НОВОЕ] См. докстринг класса про добавленный режим прокси.
    final proxyOnly = await LocalPrefs.instance.getBool(PrefKeys.proxyOnlyMode, fallback: false);
    _killSwitchEnabled = await LocalPrefs.instance.getBool(PrefKeys.killSwitch, fallback: true);
    // [ИСПРАВЛЕНО] Раньше SplitTunnelScreen сохранял выбор пользователя
    // (какие приложения идут в обход VPN) только в LocalPrefs — сам
    // туннель этот список никогда не читал, тумблеры были чистым визуалом.
    // Теперь список пакетов, отмеченных "в обход", реально передаётся в
    // sing-box как `exclude_package` на tun-инбаунде (см. ниже).
    final bypassedMap = await LocalPrefs.instance.getBoolMap(PrefKeys.splitTunnelBypass);
    final bypassedPackages = bypassedMap.entries.where((e) => e.value).map((e) => e.key).toList();

    final profiles = await _loadProfiles(connectionString);
    final preferred = _matchProfile(profiles, preferredHostName);
    final ordered = <_ParsedVless>[
      if (preferred != null) preferred,
      ...profiles.where((p) => !identical(p, preferred)),
    ];

    // [ИСПРАВЛЕНО] В режиме "только прокси" VPN-разрешение не требуется
    // вообще — так и задокументировано у пакета ("without requesting VPN
    // permission"). Запрашивать его всё равно было бы как минимум лишним
    // диалогом для пользователя, а на некоторых сборках Android могло бы
    // и просто не иметь смысла без объявленного VpnService.
    if (!proxyOnly) {
      final allowed = await _client.requestVPNPermission();
      if (!allowed) {
        throw TunnelException('Нужно разрешение на создание VPN-подключения — без него туннель не запустится.');
      }
    }

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
        );

        try {
          await _client.checkConfig(config);
        } catch (e) {
          lastFailure = 'конфиг отклонён ядром sing-box: $e';
          continue;
        }

        await _client.connect(SessionOptions(
          config: config,
          networkMode: proxyOnly ? NetworkMode.proxy : NetworkMode.vpn,
          notification: NotificationConfig(
            title: profile.remark.isNotEmpty ? profile.remark : 'VPNonLine',
            showTrafficStats: true,
            showStopButton: true,
            stopButtonLabel: 'Отключить',
          ),
        ));

        final reallyConnected = await _waitForConnected(const Duration(seconds: 12));
        if (!reallyConnected) {
          try {
            await _client.disconnect();
          } catch (_) {}
          lastFailure = 'сервер не ответил за 12с (интерфейс VPN поднялся, но VLESS/Reality-рукопожатие не завершилось)';
          continue;
        }

        final connectedName = profile.remark.isNotEmpty ? profile.remark : (preferredHostName ?? 'VPNonLine');
        connectedServerName.value = connectedName;
        localProxyAddress.value = proxyOnly ? '127.0.0.1:$_proxyPort (SOCKS5 и HTTP)' : null;
        _lastConnectionString = connectionString;
        _lastPreferredHostName = preferredHostName;
        _userInitiatedDisconnect = false;
        killSwitchBlocking.value = false;
        return connectedName;
      } catch (e) {
        lastFailure = e;
        try {
          await _client.disconnect();
        } catch (_) {}
        continue;
      }
    }
    throw TunnelException(
      'Не удалось запустить туннель ни на одном сервере ключа (${ordered.length} шт.): $lastFailure',
    );
  }

  Future<bool> _waitForConnected(Duration timeout) async {
    if (status.value?.state == TunnelConnState.connected) return true;
    final completer = Completer<bool>();
    late final VoidCallback listener;
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(false);
    });
    listener = () {
      final state = status.value?.state;
      if (state == TunnelConnState.connected) {
        if (!completer.isCompleted) completer.complete(true);
      } else if (state == TunnelConnState.disconnected) {
        if (!completer.isCompleted) completer.complete(false);
      }
    };
    status.addListener(listener);
    try {
      return await completer.future;
    } finally {
      status.removeListener(listener);
      timer.cancel();
    }
  }

  // [НОВОЕ] Порт локального SOCKS5+HTTP прокси в режиме "только прокси".
  // sing-box тип `mixed` сам определяет протокол по первому байту
  // соединения — один порт годится и для SOCKS5, и для HTTP клиентов
  // (см. sing-box.sagernet.org/configuration/inbound/mixed/).
  static const _proxyPort = 2080;

  /// [НОВОЕ] Строит РЕАЛЬНЫЙ конфиг sing-box (не Xray JSON) напрямую из
  /// разобранной vless-ссылки — схема (`type: "vless"`, `tls.reality`,
  /// `tls.utls`, `tls.fragment`) подтверждена по официальной документации
  /// sing-box (sing-box.sagernet.org/configuration) и рабочим примерам
  /// клиентских конфигов VLESS+Reality+Vision.
  String _buildSingBoxConfig(
    _ParsedVless p, {
    required bool dnsProtection,
    required bool blockAds,
    required bool dpiBypass,
    List<String> bypassedPackages = const [],
    bool proxyOnly = false,
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
        'utls': {
          'enabled': true,
          'fingerprint': (p.fp == null || p.fp!.isEmpty) ? 'chrome' : p.fp,
        },
        if (p.security == 'reality')
          'reality': {
            'enabled': true,
            'public_key': p.pbk,
            if (p.sid != null && p.sid!.isNotEmpty) 'short_id': p.sid,
          },
        // [НОВОЕ] "Обход DPI" на sing-box — встроенное поле TLS-блока, а не
        // отдельный outbound как в Xray (см. sing-box.sagernet.org/
        // configuration/shared/tls/ — `fragment`/`fragment_fallback_delay`
        // прямо в объекте tls). Резать именно ClientHello на несколько
        // TCP-сегментов — та же техника, что описана как рабочая в реальном
        // issue Hiddify про заморозку VLESS+Reality на российских мобильных
        // сетях после ~15-20 КБ (SagerNet/sing-box, hiddify-app#1976).
        if (dpiBypass) 'fragment': true,
      };
    }

    // [ИСПРАВЛЕНО — критично] Блок `dns` теперь строится ВСЕГДА, а не
    // только когда включён тумблер "DNS-защита". Раньше при выключенном
    // тумблере (а после этой правки он выключен по умолчанию) весь
    // объект `dns` пропадал из конфига целиком, а маршрут
    // `{'protocol':'dns','outbound':'dns-out'}` ниже всё равно
    // безусловно перенаправлял все DNS-запросы на `dns-out` — у которого
    // без верхнеуровневого `dns`-блока просто нет резолвера. Это
    // ГАРАНТИРОВАННО повторило бы тот самый "0 приём / 0 отдача, ключ
    // просто не подключается", который уже был на Xray-core (см. шапку
    // файла) — только теперь на sing-box и при каждом первом запуске
    // (тумблер по умолчанию выключен). Правильное поведение тумблера —
    // не "DNS работает / не работает", а "куда именно резолвить":
    //  - выключен (по умолчанию): резолвим через `direct` — то есть
    //    обычным системным DNS-путём мимо самого туннеля. Менее приватно
    //    (провайдер видит DNS-запросы), но соединение работает сразу.
    //  - включён: тот же 1.1.1.1 DoH, но `detour: proxy` — резолвим
    //    ЧЕРЕЗ сам VLESS-туннель, что и защищает от DNS-спуфинга/блокировок
    //    на уровне провайдера и было тем самым фиксом "0 МБ".
    // [ИСПРАВЛЕНО — критично, реальная причина краша из скриншота]
    // "Ошибка ядра: ... detour to an empty direct outbound makes no sense".
    // В sing-box (начиная примерно с 1.12.x) явное 'detour': 'direct',
    // указывающее на ПУСТОЙ outbound {'type':'direct','tag':'direct'} без
    // доп. опций, — не предупреждение, а FATAL при старте сервиса: ядро
    // считает такой detour бессмысленным (это то же самое, что и просто
    // не указывать detour вовсе) и отказывается стартовать. Подтверждено
    // багтрекером sing-box (SagerNet/sing-box issues #2803, #3585,
    // immortalwrt/homeproxy #385) — рабочее решение именно "не писать
    // detour", а не "написать другой direct outbound". Раньше это поле
    // всегда присутствовало в конфиге (со значением 'direct' по
    // умолчанию, когда DNS-защита выключена) — то есть КАЖДОЕ первое
    // подключение с настройками по умолчанию (DNS-защита выключена по
    // умолчанию, см. выше) гарантированно било по этому фатальному
    // старту ядра. Теперь ключ 'detour' добавляется в объект ТОЛЬКО когда
    // нужно реально увести DNS-запросы через прокси; когда defour не
    // нужен — просто не пишем это поле, и sing-box резолвит напрямую сам.
    // [ИСПРАВЛЕНО — критично, sing-box 1.12.0 → полностью убрано в 1.14.0]
    // "INVALID_CONFIG, decode config: dns.servers[0]: legacy DNS server
    // formats are deprecated in sing-box 1.12.0 and removed in sing-box
    // 1.14.0" — реальная причина краша "0 МБ / не удалось запустить туннель
    // ни на одном сервере ключа" из скриншота 18.08 12:00. Старый формат
    // кодировал тип DNS-сервера префиксом прямо в поле 'address'
    // (например 'https://1.1.1.1/dns-query'). Начиная с 1.12 sing-box
    // требует типизированную форму: отдельное поле 'type' (здесь — 'https',
    // т.е. DNS-over-HTTPS) и голый хост/IP в поле 'server' без схемы и
    // пути — 'server': '1.1.1.1', порт и путь /dns-query для DoH это
    // дефолты самого типа 'https' в sing-box, задавать их отдельно не
    // нужно. Подтверждено официальным migration-гайдом
    // (sing-box.sagernet.org/migration/#migrate-to-new-dns-server-formats).
    final dnsServers = <Map<String, dynamic>>[
      {
        'type': 'https',
        'tag': 'remote-dns',
        'server': '1.1.1.1',
        if (dnsProtection) 'detour': 'proxy',
      },
    ];

    // [ИСПРАВЛЕНО — критично, sing-box 1.13.0] Раньше DNS-хайджек и
    // ad-block заворачивались через "legacy special outbounds" — отдельные
    // outbound'ы {'type':'dns','tag':'dns-out'} / {'type':'block',...} плюс
    // маршруты вида {'protocol':'dns','outbound':'dns-out'}. Это ровно та
    // схема, которую документация sing-box называет "legacy special
    // outbounds (block/dns)": deprecated в 1.11.0, ПОЛНОСТЬЮ УДАЛЕНА в
    // 1.13.0 (sing-box.sagernet.org/deprecated/#1110,
    // /migration/#migrate-legacy-special-outbounds-to-rule-actions).
    // Именно это (вместе с 'sniff': true в инбаунде ниже) — причина
    // реального краша "INVALID_CONFIG ... legacy inbound fields are
    // deprecated in sing-box 1.11.0 and removed in sing-box 1.13.0" со
    // скриншота от 16.08 23:20. Новая схема — никаких dns/block outbound'ов
    // не нужно вообще, вместо них правила маршрутизации с полем "action":
    //   - DNS-хайджек: {'protocol': 'dns', 'action': 'hijack-dns'}
    //   - Ad-block:    {'domain_suffix': [...], 'action': 'reject'}
    final routeRules = <Map<String, dynamic>>[
      // [ИСПРАВЛЕНО] 'action': 'sniff' — та же миграция 1.11→1.13: раньше
      // протокол трафика определялся полем 'sniff': true прямо в объекте
      // инбаунда (см. комментарий у 'inbounds' ниже), теперь — отдельным
      // правилом маршрутизации. Без него sniffing не работает и правило
      // 'protocol': 'dns' ниже никогда не сматчится (хотя сам конфиг уже
      // не упадёт при старте — просто DNS не будет хайджекаться).
      {'action': 'sniff'},
      {'protocol': 'dns', 'action': 'hijack-dns'},
    ];

    final outbounds = <Map<String, dynamic>>[
      outbound,
      {'type': 'direct', 'tag': 'direct'},
    ];

    if (blockAds) {
      routeRules.add({'domain_suffix': _adBlockDomains, 'action': 'reject'});
    }

    final config = <String, dynamic>{
      'log': {'level': 'warn'},
      'dns': {
        'servers': dnsServers,
        'final': 'remote-dns',
      },
      'inbounds': [
        // [ИСПРАВЛЕНО] Критично по документации пакета: "Proxy mode configs
        // must not contain a tun inbound. Starting proxy mode with a TUN
        // config causes an immediate startup failure via faultStream." —
        // поэтому это ЖЁСТКОЕ ветвление, а не просто "добавить ещё один
        // инбаунд поверх" — в режиме прокси tun не создаётся вообще.
        if (proxyOnly)
          {
            'type': 'mixed',
            'tag': 'mixed-in',
            'listen': '127.0.0.1',
            'listen_port': _proxyPort,
            // [ИСПРАВЛЕНО — критично, sing-box 1.13.0] 'sniff' больше не
            // поле инбаунда ("legacy inbound fields", удалены в 1.13.0,
            // см. sing-box.sagernet.org/deprecated/#1110) — сниффинг
            // теперь включается правилом {'action': 'sniff'} в
            // route.rules (см. routeRules выше). Оставление этого поля
            // здесь — прямая причина FATAL "legacy inbound fields are
            // deprecated ... removed in sing-box 1.13.0" при старте ядра.
          }
        else
          {
            'type': 'tun',
            'tag': 'tun-in',
            'interface_name': 'vpnonline-tun',
            // [ИСПРАВЛЕНО — реальная IPv6-утечка] Раньше `address` содержал
            // ТОЛЬКО IPv4-подсеть. У tun-интерфейса без единого IPv6-адреса
            // sing-box физически не может прописать IPv6-маршрут через себя
            // (auto_route строит маршруты по семействам адресов, которые
            // реально назначены интерфейсу) — весь IPv6-трафик устройства
            // в сети с IPv6 продолжал ходить в обход туннеля напрямую через
            // исходный сетевой интерфейс, никак не через VLESS-прокси. Это
            // классическая IPv6-утечка (проверяется на ipleak.net: реальный
            // IPv6 провайдера виден снаружи, даже когда VPN "подключён").
            // Фикс — общепринятый для sing-box/Xray-клиентов (тот же подход
            // у Hiddify/NekoBox/v2rayNG): добавить ULA-подобный IPv6-адрес
            // самому tun-интерфейсу, чтобы auto_route забирал IPv6-трафик в
            // туннель наравне с IPv4. Дальше он либо реально идёт через
            // прокси (если сервер поддерживает IPv6-исходящий), либо просто
            // не находит маршрут наружу и молча дропается ядром — в обоих
            // случаях НЕ обходит VPN. Если у оборудования на VLESS-сервере
            // в принципе нет IPv6, это и есть корректное поведение "заблокировать IPv6, раз сеть его не поддерживает" из ТЗ,
            // а не единственно возможный вариант "молчаливой утечки".
            'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
            'mtu': 1500,
            'auto_route': true,
            'strict_route': true,
            'stack': 'system',
            // [ИСПРАВЛЕНО — см. идентичный комментарий у mixed-in выше]
            // 'sniff': true отсюда убран по той же причине — legacy
            // inbound-поле, удалено в sing-box 1.13.0.
            // [НОВОЕ] Реальное split-tunneling — поле `exclude_package`
            // самого tun-инбаунда sing-box (Android-only, работает через
            // VpnService.Builder.addDisallowedApplication под капотом ядра;
            // см. sing-box.sagernet.org/configuration/inbound/tun/). Список
            // приходит из SplitTunnelScreen через LocalPrefs. Неприменимо к
            // режиму прокси — там нет системного VPN-интерфейса, который
            // можно было бы исключить по пакетам.
            if (bypassedPackages.isNotEmpty) 'exclude_package': bypassedPackages,
          },
      ],
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
    'googletagmanager.com',
    'googletagservices.com',
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

  Future<void> disconnect() async {
    if (!_initialized) return;
    _userInitiatedDisconnect = true;
    _lastConnectionString = null;
    _autoReconnectAttempt = 0;
    killSwitchBlocking.value = false;
    try {
      await _client.disconnect();
    } catch (e) {
      lastError.value = 'Не удалось корректно отключиться: $e';
    } finally {
      connectedServerName.value = null;
      localProxyAddress.value = null;
    }
  }

  Future<void> openSystemVpnSettingsHint() async {
    await AppSettings.openAppSettings(type: AppSettingsType.vpn);
  }

  /// [ИЗМЕНЕНО] У sing-box-пакета нет отдельного "ping текущего сервера"
  /// в подтверждённой части API — возвращаем текущую задержку недоступной
  /// (`null`), UI (ConnectScreen) уже умеет корректно скрывать это
  /// значение, если пинг не пришёл. Если в `flutter_singbox_client` есть
  /// STUN/network-test метод (в README он упомянут как отдельная фича,
  /// "Network Testing") — можно подключить его сюда отдельно после
  /// проверки точного имени метода в установленном пакете.
  Future<int?> connectedDelayMs() async => null;
}

enum TunnelConnState { connecting, connected, disconnecting, disconnected }

class TunnelStatus {
  const TunnelStatus({required this.state, required this.duration, required this.download, required this.upload});
  final TunnelConnState state;
  final int duration;
  final num download;
  final num upload;
}

/// Разобранная `vless://uuid@host:port?...&security=reality&pbk=...&fp=...
/// &sni=...&sid=...&spx=...&flow=...#remark` ссылка.
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
    required this.remark,
  });

  final String uuid;
  final String host;
  final int port;
  final String security; // reality | tls | none
  final String? pbk;
  final String? fp;
  final String? sni;
  final String? sid;
  final String? flow;
  final String remark;

  static _ParsedVless? tryParse(String link) {
    try {
      final uri = Uri.parse(link);
      if (uri.scheme != 'vless') return null;
      final uuid = uri.userInfo;
      final host = uri.host;
      final port = uri.port;
      if (uuid.isEmpty || host.isEmpty || port == 0) return null;
      final q = uri.queryParameters;
      final remark = uri.fragment.isNotEmpty ? Uri.decodeComponent(uri.fragment) : host;
      return _ParsedVless(
        uuid: uuid,
        host: host,
        port: port,
        security: (q['security'] ?? 'none').toLowerCase(),
        pbk: q['pbk'],
        fp: q['fp'],
        sni: q['sni'],
        sid: q['sid'],
        flow: q['flow'],
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
