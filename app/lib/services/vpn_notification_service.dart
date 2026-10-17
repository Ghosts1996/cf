// Содержимое уведомления работающего VPN в шторке Android.
//
// Само уведомление создаёт модуль ядра — с цветной иконкой приложения
// (Android делает из неё пятно в кружке) и единственной строкой «VPN
// подключён». Приложение обновляет то же уведомление своим содержимым (см.
// MainActivity.updateVpnNotification): аккуратный значок-щит, сервер, пинг,
// сколько дней осталось ключу, время сессии и кнопка «Отключить».
//
// Обновляется только когда меняется показанное: сервер, пинг, ключ. Время
// сессии система считает сама, без обновлений каждую секунду — шторка не
// перерисовывается впустую и батарея не тратится.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../l10n/app_language.dart';
import 'locale_service.dart';
import 'local_prefs.dart';
import 'tunnel_service.dart';

class VpnNotificationService {
  VpnNotificationService._();
  static final VpnNotificationService instance = VpnNotificationService._();

  static const _channel = MethodChannel('vpnonline/native_stats');

  /// События экрана от MainActivity: включён ли он сейчас.
  static const _screen = MethodChannel('vpnonline/screen');

  /// Включён ли экран. С погасшим экраном шторку никто не видит —
  /// уведомление не обновляется вовсе, а при включении сразу получает
  /// свежие числа.
  bool _screenOn = true;

  bool _started = false;
  DateTime? _keyExpiry;
  String? _lastPosted;
  Timer? _debounce;
  Timer? _hourly;
  TunnelConnState? _lastState;
  DateTime? _lastPostAt;

  /// Как часто уведомление обновляется ради трафика — только пока экран
  /// включён и числа меняются. Простой VPN и погасший экран шторку не
  /// перерисовывают вовсе.
  static const trafficRefresh = Duration(seconds: 2);

  /// Подключить к событиям туннеля. Только Android: на Windows шторки нет.
  void start() {
    if (_started || !Platform.isAndroid) return;
    _started = true;
    _screen.setMethodCallHandler((call) async {
      if (call.method != 'screenChanged') return;
      _screenOn = call.arguments == true;
      if (_screenOn) _schedule();
    });
    unawaited(_readScreen());
    final tunnel = TunnelService.instance;
    tunnel.status.addListener(_onStatus);
    tunnel.connectedServerName.addListener(_schedule);
    tunnel.latencyByRemark.addListener(_schedule);
    // «Ещё N дней» меняется со временем и без всяких событий.
    _hourly = Timer.periodic(const Duration(hours: 1), (_) => _schedule());
  }

  /// Срок действия ключа, с которым подключаемся. null — неизвестен
  /// (ручной ключ, ключи ещё не загрузились).
  set keyExpiry(DateTime? value) {
    if (value == _keyExpiry) return;
    _keyExpiry = value;
    _schedule();
  }

  void _onStatus() {
    final state = TunnelService.instance.status.value?.state;
    // Статус меняется каждую секунду (счётчики трафика): тогда обновляем не
    // чаще [trafficRefresh], а повтор тех же чисел отсеет сравнение текста.
    if (state == _lastState) {
      if (state == TunnelConnState.connected) _scheduleTraffic();
      return;
    }
    _lastState = state;
    if (state == TunnelConnState.connected) {
      _schedule();
    } else if (state == TunnelConnState.disconnected) {
      _lastPosted = null;
      _debounce?.cancel();
      // Если наше уведомление пережило сервис — убираем (нативная сторона
      // не тронет его, пока сервис работает).
      unawaited(_invoke('clearVpnNotification'));
    }
  }

  void _schedule() {
    if (!TunnelService.instance.isConnected) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () {
      unawaited(_post());
    });
  }

  Future<void> _readScreen() async {
    try {
      _screenOn = await _screen.invokeMethod<bool>('isScreenOn') ?? true;
    } catch (_) {
      _screenOn = true;
    }
  }

  void _scheduleTraffic() {
    if (!_screenOn) return;
    if (_debounce?.isActive ?? false) return; // обновление и так в пути
    final last = _lastPostAt;
    final wait = last == null
        ? Duration.zero
        : trafficRefresh - DateTime.now().difference(last);
    _debounce = Timer(wait.isNegative ? Duration.zero : wait, () {
      unawaited(_post());
    });
  }

  Future<void> _post() async {
    final tunnel = TunnelService.instance;
    if (!tunnel.isConnected) return;
    // Экран погашен — ничего не рисуем; при включении придут свежие числа.
    if (!_screenOn) return;
    final server = tunnel.connectedServerName.value;
    final blockAds =
        await LocalPrefs.instance.getBool(PrefKeys.blockAds, fallback: true);
    final status = tunnel.status.value;
    final payload = buildPayload(
      server: server,
      pingMs: tunnel.latencyForHostName(server),
      keyExpiry: _keyExpiry,
      now: DateTime.now(),
      since: tunnel.connectedSince,
      adBlock: blockAds,
      downloadBytes: status?.downloadTotalBytes ?? 0,
      uploadBytes: status?.uploadTotalBytes ?? 0,
      downloadBps: (status?.download ?? 0).toInt(),
      uploadBps: (status?.upload ?? 0).toInt(),
      english: LocaleService.instance.language == AppLanguage.en,
    );
    final fingerprint = jsonEncode(payload);
    if (fingerprint == _lastPosted) return;
    _lastPosted = fingerprint;
    _lastPostAt = DateTime.now();
    await _invoke('updateVpnNotification', payload);
  }

  Future<void> _invoke(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (_) {
      // Старая сборка без метода или канал не готов — остаётся уведомление
      // модуля, VPN от этого не зависит.
    }
  }

  @visibleForTesting
  void debugStop() {
    _hourly?.cancel();
    _debounce?.cancel();
  }

  // ── Текст ───────────────────────────────────────────────────────────────

  /// Всё, что уходит в уведомление. Отдельно от отправки — чтобы текст
  /// можно было проверить тестом.
  @visibleForTesting
  static Map<String, Object?> buildPayload({
    required String? server,
    required int? pingMs,
    required DateTime? keyExpiry,
    required DateTime now,
    required DateTime? since,
    required bool adBlock,
    int downloadBytes = 0,
    int uploadBytes = 0,
    int downloadBps = 0,
    int uploadBps = 0,
    bool english = false,
  }) {
    final serverName = (server == null || server.trim().isEmpty)
        ? null
        : server.trim();
    final ping = (pingMs != null && pingMs > 0) ? pingMs : null;
    final title = english
        ? (serverName == null ? 'VPN connected' : 'VPN connected · $serverName')
        : (serverName == null ? 'VPN подключён' : 'VPN подключён · $serverName');

    final keyShort =
        keyExpiry == null ? null : keyLeftText(keyExpiry, now, english: english);
    final msUnit = english ? 'ms' : 'мс';
    final traffic =
        '↓ ${formatBytes(downloadBytes)}  ·  ↑ ${formatBytes(uploadBytes)}';
    // Скорость показываем, только пока что-то идёт: «↓ 0 B/s» — шум.
    final moving = downloadBps >= 1024 || uploadBps >= 1024;

    // Свёрнутое: пинг и трафик одной строкой.
    final text = ping == null ? traffic : '⚡ $ping $msUnit  ·  $traffic';

    // Развёрнутое: сервер уже в заголовке, срок ключа — в шапке; здесь по
    // строке на пункт, трафик и скорость — внизу.
    final details = <String>[
      if (ping != null)
        '⚡ ${english ? 'Ping' : 'Пинг'}: $ping $msUnit — '
            '${pingQuality(ping, english: english)}',
      if (keyExpiry != null)
        keyExpiry.isAfter(now)
            ? '🔑 ${english ? 'Key valid until' : 'Ключ действует до'} '
                '${_date(keyExpiry)}'
            : (english ? '🔑 Key expired' : '🔑 Ключ истёк'),
      if (adBlock)
        english
            ? '🛡 Ads and trackers are blocked'
            : '🛡 Реклама и трекеры блокируются',
      '📶 ${english ? 'Traffic' : 'Трафик'}: $traffic',
      if (moving)
        '🚀 ${english ? 'Speed' : 'Скорость'}: ↓ ${formatSpeed(downloadBps)}'
            '  ·  ↑ ${formatSpeed(uploadBps)}',
    ];

    return {
      'title': title,
      'text': text,
      // В шапке уведомления, рядом с названием приложения и таймером.
      'subText': keyShort == null ? null : '🔑 $keyShort',
      'details': details.join('\n'),
      'since': since?.millisecondsSinceEpoch ?? 0,
      'stopLabel': english ? 'Disconnect' : 'Отключить',
    };
  }

  /// «ещё 23 дня», «меньше суток», «истёк».
  @visibleForTesting
  static String keyLeftText(DateTime expiry, DateTime now,
      {bool english = false}) {
    final left = expiry.difference(now);
    if (left.isNegative) return english ? 'expired' : 'истёк';
    final days = left.inDays;
    if (days < 1) return english ? 'less than a day left' : 'меньше суток';
    if (english) return '$days ${days == 1 ? 'day' : 'days'} left';
    return 'ещё $days ${_daysWord(days)}';
  }

  static String _daysWord(int n) {
    final mod100 = n % 100;
    final mod10 = n % 10;
    if (mod100 >= 11 && mod100 <= 14) return 'дней';
    if (mod10 == 1) return 'день';
    if (mod10 >= 2 && mod10 <= 4) return 'дня';
    return 'дней';
  }

  /// Объём — так же, как на главном экране: «370.8 MB», «1.25 GB».
  @visibleForTesting
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    final mb = bytes / (1024 * 1024);
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  /// Скорость в байтах в секунду: «85 KB/s», «1.2 MB/s».
  @visibleForTesting
  static String formatSpeed(int bytesPerSecond) {
    if (bytesPerSecond < 1024) return '$bytesPerSecond B/s';
    final kb = bytesPerSecond / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(0)} KB/s';
    return '${(kb / 1024).toStringAsFixed(1)} MB/s';
  }

  @visibleForTesting
  static String pingQuality(int ms, {bool english = false}) {
    if (ms < 120) return english ? 'excellent' : 'отлично';
    if (ms < 300) return english ? 'good' : 'хорошо';
    return english ? 'slow' : 'медленно';
  }

  static String _date(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year}';
  }
}
