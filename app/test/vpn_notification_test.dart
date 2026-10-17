// Текст уведомления VPN в шторке: сервер, пинг, дни ключа.
import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/vpn_notification_service.dart';

void main() {
  final now = DateTime(2026, 10, 17, 16, 39);

  group('сколько осталось ключу', () {
    String left(Duration d) =>
        VpnNotificationService.keyLeftText(now.add(d), now);
    test('склонение', () {
      expect(left(const Duration(days: 1, hours: 2)), 'ещё 1 день');
      expect(left(const Duration(days: 3, hours: 1)), 'ещё 3 дня');
      expect(left(const Duration(days: 5, hours: 1)), 'ещё 5 дней');
      expect(left(const Duration(days: 11, hours: 1)), 'ещё 11 дней');
      expect(left(const Duration(days: 21, hours: 1)), 'ещё 21 день');
      expect(left(const Duration(days: 23, hours: 1)), 'ещё 23 дня');
    });
    test('меньше суток и истёкший', () {
      expect(left(const Duration(hours: 5)), 'меньше суток');
      expect(left(const Duration(hours: -1)), 'истёк');
    });
  });

  test('полное уведомление: сервер, пинг, трафик, скорость, ключ, реклама',
      () {
    final p = VpnNotificationService.buildPayload(
      server: '🇬🇧 Великобритания · Лондон',
      pingMs: 68,
      keyExpiry: DateTime(2026, 11, 9, 12),
      now: now,
      since: DateTime(2026, 10, 17, 14, 52),
      adBlock: true,
      downloadBytes: 388811571, // 370.8 MB
      uploadBytes: 39321600, // 37.5 MB
      downloadBps: 1258291, // 1.2 MB/s
      uploadBps: 87040, // 85 KB/s
    );
    expect(p['title'], 'VPN подключён · 🇬🇧 Великобритания · Лондон');
    expect(p['text'], '⚡ 68 мс   ·   ↓ 370.8 MB  ↑ 37.5 MB');
    expect(p['subText'], '🔑 ещё 22 дня');
    expect(
        p['details'],
        '🌍 Сервер: 🇬🇧 Великобритания · Лондон\n'
        '⚡ Пинг: 68 мс — отлично\n'
        '📥 Приём: 370.8 MB   📤 Отдача: 37.5 MB\n'
        '🚀 Скорость: ↓ 1.2 MB/s  ↑ 85 KB/s\n'
        '🔑 Ключ: ещё 22 дня (до 09.11.2026)\n'
        '🛡 Реклама и трекеры блокируются');
    expect(p['since'], DateTime(2026, 10, 17, 14, 52).millisecondsSinceEpoch);
    expect(p['stopLabel'], 'Отключить');
  });

  test('пинга ещё нет и ключ без срока — без пустых строк', () {
    final p = VpnNotificationService.buildPayload(
      server: null,
      pingMs: null,
      keyExpiry: null,
      now: now,
      since: null,
      adBlock: false,
    );
    expect(p['title'], 'VPN подключён');
    expect(p['text'], '↓ 0 MB  ↑ 0 MB');
    expect(p['subText'], isNull);
    expect(p['details'], '📥 Приём: 0 MB   📤 Отдача: 0 MB',
        reason: 'без трафика — без строки скорости');
    expect(p['since'], 0);
  });

  test('объём и скорость — как на главном экране', () {
    expect(VpnNotificationService.formatBytes(0), '0 MB');
    expect(VpnNotificationService.formatBytes(2 * 1024 * 1024 * 1024),
        '2.00 GB');
    expect(VpnNotificationService.formatSpeed(500), '500 B/s');
    expect(VpnNotificationService.formatSpeed(87040), '85 KB/s');
  });

  test('английский интерфейс', () {
    final p = VpnNotificationService.buildPayload(
      server: 'Sweden',
      pingMs: 350,
      keyExpiry: DateTime(2026, 10, 19, 17),
      now: now,
      since: null,
      adBlock: true,
      english: true,
    );
    expect(p['title'], 'VPN connected · Sweden');
    expect(p['text'], '⚡ 350 ms   ·   ↓ 0 MB  ↑ 0 MB');
    expect(p['subText'], '🔑 2 days left');
    expect((p['details'] as String).split('\n')[1], '⚡ Ping: 350 ms — slow');
    expect(p['stopLabel'], 'Disconnect');
  });
}
