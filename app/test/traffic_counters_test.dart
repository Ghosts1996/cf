// «Приём» и «Отдача» замирали на одном числе: модуль ядра переставал
// присылать статистику, а туннель работал. Приложение досчитывает объём по
// системным счётчикам Android и никогда не откатывает показанное назад.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

import 'support/fake_runtime.dart';

const _subscription =
    'vless://11111111-1111-1111-1111-111111111111@de.example.com:443'
    '?type=tcp&security=reality&pbk=e8Q_05VmcuO12_QIua9nojVHZViU73hqOOZShYo52-c'
    '&sid=aa&sni=yahoo.com&fp=chrome#Германия\n'
    'vless://22222222-2222-2222-2222-222222222222@nl.example.com:443'
    '?type=tcp&security=reality&pbk=e8Q_05VmcuO12_QIua9nojVHZViU73hqOOZShYo52-c'
    '&sid=bb&sni=yahoo.com&fp=chrome#Нидерланды';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeRuntime core;
  late TunnelService tunnel;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = null;
    core = FakeRuntime();
    tunnel = TunnelService.withRuntime(core);
    await tunnel.connect(_subscription);
  });
  tearDown(() => tunnel.disconnect());

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));
  int down() => tunnel.status.value!.downloadTotalBytes;
  int up() => tunnel.status.value!.uploadTotalBytes;
  const mb = 1024 * 1024;

  test('ядро считает — показываем его итоги как есть', () async {
    core.emitStats(down: 5 * mb, up: mb);
    await settle();
    expect(down(), 5 * mb);
    expect(up(), mb);
  });

  test('статистика ядра встала, а трафик идёт — досчитываем по Android',
      () async {
    core.emitStats(down: 5 * mb, up: mb);
    await settle();
    final later = DateTime.now().add(const Duration(seconds: 12));
    tunnel.debugNoteUidTraffic(2 * mb, 100 * 1024, later);
    expect(down(), 7 * mb);
    expect(up(), mb + 100 * 1024);
    tunnel.debugNoteUidTraffic(mb, 0, later.add(const Duration(seconds: 1)));
    expect(down(), 8 * mb);

    // Ядро ожило и насчитало то же самое — не удваиваем и не откатываем.
    core.emitStats(down: 8 * mb + 1000, up: mb + 100 * 1024);
    await settle();
    expect(down(), 8 * mb + 1000);
    expect(up(), mb + 100 * 1024);
  });

  test('мелкий служебный трафик застоем не считается', () async {
    core.emitStats(down: 5 * mb, up: mb);
    await settle();
    final later = DateTime.now().add(const Duration(seconds: 12));
    tunnel.debugNoteUidTraffic(60 * 1024, 10 * 1024, later);
    expect(down(), 5 * mb, reason: 'замер задержки — это не застой ядра');
  });

  test('ядро начало счёт заново (смена сервера) — показанное не падает',
      () async {
    core.emitStats(down: 5 * mb, up: mb);
    await settle();
    core.emitStats(down: 1000, up: 500);
    await settle();
    expect(down(), 5 * mb + 1000);
    expect(up(), mb + 500);
  });
}
