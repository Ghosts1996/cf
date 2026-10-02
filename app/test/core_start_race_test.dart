// Гонка при старте ядра: новое ядро запускалось, пока прошлое ещё держало
// служебный порт, и падало с «bind: address already in use».
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = null;
  });

  Future<int> freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  test('порт свободен — запуск сразу, без ожидания', () async {
    final port = await freePort();
    final sw = Stopwatch()..start();
    expect(
        await TunnelService.waitCommandPortFree(port: port, force: true), isTrue);
    expect(sw.elapsedMilliseconds, lessThan(200));
  });

  test('прошлое ядро держит порт и отпускает через полсекунды — дожидаемся',
      () async {
    final port = await freePort();
    final old = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    Timer(const Duration(milliseconds: 500), () => old.close());
    final sw = Stopwatch()..start();
    final ok = await TunnelService.waitCommandPortFree(
        port: port, force: true, timeout: const Duration(seconds: 5));
    expect(ok, isTrue);
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(450));
    expect(sw.elapsedMilliseconds, lessThan(2000));
  });

  test('порт так и не освободился — сдаёмся по таймауту, а не висим', () async {
    final port = await freePort();
    final old = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    addTearDown(old.close);
    final sw = Stopwatch()..start();
    final ok = await TunnelService.waitCommandPortFree(
        port: port, force: true, timeout: const Duration(seconds: 1));
    expect(ok, isFalse);
    expect(sw.elapsedMilliseconds, lessThan(2500));
  });

  test('ошибки старта ядра распознаются по тексту плагина', () {
    const busy = 'Start failed: listen command server: listen tcp '
        '127.0.0.1:10086: bind: address already in use';
    expect(TunnelService.isCoreStartFault(busy), isTrue);
    expect(TunnelService.isPortBusyFault(busy), isTrue);
    expect(TunnelService.isCoreStartFault('Core failed: decode config'), isTrue);
    expect(TunnelService.isPortBusyFault('Core failed: decode config'), isFalse);
    expect(TunnelService.isCoreStartFault(
        'Разрешите уведомления, чтобы видеть статус VPN в шторке.'), isFalse);
    expect(TunnelService.isCoreStartFault(null), isFalse);
  });

  group('проверка живости туннеля', () {
    test('данные приходят — туннель жив, запросов не шлём', () {
      expect(
          TunnelService.liveCheckDecision(
              rxDelta: 500 * 1024, txDelta: 20 * 1024, foreground: false),
          LiveCheckAction.alive);
    });

    test('телефон лежит без трафика в фоне — радио не будим', () {
      expect(
          TunnelService.liveCheckDecision(
              rxDelta: 0, txDelta: 0, foreground: false),
          LiveCheckAction.skip);
    });

    test('приложения шлют, а в ответ почти ничего — проверяем', () {
      expect(
          TunnelService.liveCheckDecision(
              rxDelta: 300, txDelta: 8 * 1024, foreground: false),
          LiveCheckAction.probe);
    });

    test('пользователь смотрит на экран приложения — проверяем даже без '
        'трафика', () {
      expect(
          TunnelService.liveCheckDecision(
              rxDelta: 0, txDelta: 0, foreground: true),
          LiveCheckAction.probe);
    });
  });
}
