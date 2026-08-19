import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_singbox_client/flutter_singbox_client.dart';
import 'package:http/http.dart' as http;
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
  static const _maxAutoReconnectAttempts = 3;

  StreamSubscription? _stateSub;
  StreamSubscription? _statsSub;
  StreamSubscription? _faultSub;
  DateTime? _connectStartedAt;

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
    _killSwitchEnabled = await LocalPrefs.instance.getBool(PrefKeys.killSwitch, fallback: true);
    final bypassedMap = await LocalPrefs.instance.getBoolMap(PrefKeys.splitTunnelBypass);
    final bypassedPackages = bypassedMap.entries.where((e) => e.value).map((e) => e.key).toList();

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
        );
        await _client.checkConfig(config);
        await _client.connect(SessionOptions(
          config: config,
          networkMode: proxyOnly ? NetworkMode.proxy : NetworkMode.vpn,
          notification: NotificationConfig(
            title: profile.remark.isNotEmpty ? profile.remark : 'VPNOnline',
            showTrafficStats: true,
            showStopButton: true,
            stopButtonLabel: 'Отключить',
          ),
        ));

        final reallyConnected = await _waitForConnected(Duration(seconds: 12));
        if (!reallyConnected) {
          await _client.disconnect();
          lastFailure = 'VPN не подключился за 12 сек (ядра sing-box требуют время для инициализации туннеля)';
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
        try { await _client.disconnect(); } catch (_) {}
        continue;
      }
    }
    throw TunnelException(
      'Не удалось подключиться ни к одному серверу (${ordered.length} исп.): $lastFailure',
    );
  }

  static const _proxyPort = 2080;

  String _buildSingBoxConfig(
    _ParsedVless p, {
    required bool dnsProtection,
    required bool blockAds,
    required bool dpiBypass,
    required List<String> bypassedPackages,
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
        if (p.alpn != null && p.alpn!.isNotEmpty) 'alpn': p.alpn!.split(','),
        'utls': {'enabled': true, 'fingerprint': (p.fp == null || p.fp!.isEmpty) ? 'chrome' : p.fp},
        if (p.security == 'reality')
          'reality': {
            'enabled': true,
            'public_key': p.pbk,
            if (p.sid != null && p.sid!.isNotEmpty) 'short_id': p.sid,
          },
        if (dpiBypass) 'fragment': true,
      };
    }

    // Маскировка/транспорт (ws, grpc, http) — обязателен для ключей, где
    // сервер ожидает не голый TCP, а конкретный транспортный "конверт".
    // Без этого блока такие ключи (например, экспортированные из Hiddify
    // с http-заголовками) не подключаются: сервер отвергает handshake.
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

    final dnsServers = <Map<String, dynamic>>[
      {
        'type': 'https',
        'tag': 'remote-dns',
        'server': '1.1.1.1',
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
      if (blockAds) 
        {'domain_suffix': _adBlockDomains, 'action': 'reject'},
      {'action': 'sniff'},
      {'protocol': 'dns', 'action': 'hijack-dns'},
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
        'strict_route': true,
        'stack': 'system',
        'auto_route': true,
        'endpoint_independent_nat': true,
        if (bypassedPackages.isNotEmpty) 'exclude_package': bypassedPackages,
      });
    }

    final config = <String, dynamic>{
      'log': {'level': 'warn'},
      'dns': {'servers': dnsServers, 'final': 'remote-dns'},
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
        final res = await http.get(Uri.parse(source)).timeout(Duration(seconds: 12));
        if (res.statusCode >= 400) {
          throw TunnelException('Подписка недоступна (${res.statusCode}). Попробуйте позднее.');
        }
        body = res.body;
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

  Future<void> disconnect() async {
    if (!_initialized) return;
    _userInitiatedDisconnect = true;
    _lastConnectionString = null;
    _autoReconnectAttempt = 0;
    killSwitchBlocking.value = false;
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

  Future<int?> connectedDelayMs() async => null;

  Future<void> dispose() async {
    await _stateSub?.cancel();
    await _statsSub?.cancel();
    await _faultSub?.cancel();
    _stateSub = null;
    _statsSub = null;
    _faultSub = null;
  }
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

      // Hiddify/Xray экспортируют тип транспорта либо как "type", либо как "headerType".
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