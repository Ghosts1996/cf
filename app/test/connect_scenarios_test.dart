// Сценарии подключения на управляемой заглушке ядра.
//
// Каждый тест — это конкретная жалоба, которая приходила с телефона:
// «через раз запускается», «пишет подключено, хотя выключил», «сам включается
// обратно». На телефоне их воспроизвести — дело случая, здесь они
// детерминированны и гоняются в каждой сборке.
import 'dart:async';
import 'dart:io';

import 'package:flutter_singbox_client/flutter_singbox_client.dart'
    show LogEntry, LogLevel;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpnonline_app/services/app_log_service.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

import 'support/fake_runtime.dart';

// Три локации: в сессии будет группа-селектор, как на телефоне.
const _subscription =
    'vless://11111111-1111-1111-1111-111111111111@de.example.com:443'
    '?type=tcp&security=reality&pbk=e8Q_05VmcuO12_QIua9nojVHZViU73hqOOZShYo52-c'
    '&sid=aa&sni=yahoo.com&fp=chrome#Германия\n'
    'vless://22222222-2222-2222-2222-222222222222@nl.example.com:443'
    '?type=tcp&security=reality&pbk=e8Q_05VmcuO12_QIua9nojVHZViU73hqOOZShYo52-c'
    '&sid=bb&sni=yahoo.com&fp=chrome#Нидерланды\n'
    'vless://33333333-3333-3333-3333-333333333333@lv.example.com:443'
    '?type=tcp&security=reality&pbk=e8Q_05VmcuO12_QIua9nojVHZViU73hqOOZShYo52-c'
    '&sid=cc&sni=yahoo.com&fp=chrome#Латвия';

/// Ждёт условия, опрашивая раз в 20 мс.
Future<bool> waitUntil(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return cond();
}

/// Изображает рабочий туннель: HTTP-прокси на порту сервиса, отвечающий на
/// любой запрос. Без него проверка связи через туннель проваливается —
/// так выглядит «подключено, а интернета нет».
Future<HttpServer> startWorkingTunnel() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 2080,
      shared: true);
  server.listen((req) {
    req.response.statusCode = 204;
    req.response.close();
  });
  return server;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRuntime core;
  late TunnelService tunnel;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Тестовая привязка Flutter подменяет весь HTTP и отвечает на любой запрос
    // кодом 400. Проверка связи считает любой ответ признаком интернета — и с
    // такой подменой туннель на стенде всегда выглядел рабочим. Возвращаем
    // настоящую сеть: без прокси на порту сервиса запрос честно проваливается,
    // ровно как на телефоне с мёртвым сервером.
    HttpOverrides.global = null;
    core = FakeRuntime();
    tunnel = TunnelService.withRuntime(core);
  });

  test('обычное подключение поднимает ровно одну сессию', () async {
    await tunnel.connect(_subscription);
    expect(tunnel.isConnected, isTrue);
    expect(core.connectCount, 1);
    expect(core.maxLiveSessions, 1);
    await tunnel.disconnect();
  });

  test('«Отключить» гасит туннель и экран показывает «отключено»', () async {
    await tunnel.connect(_subscription);
    await tunnel.disconnect();
    expect(tunnel.isConnected, isFalse);
    expect(tunnel.status.value?.state, TunnelConnState.disconnected);
    expect(core.disconnectCount, greaterThanOrEqualTo(1));
  });

  test('после «Отключить» туннель сам обратно не поднимается', () async {
    tunnel.appInForeground = false; // даже если приложение свёрнуто
    await tunnel.connect(_subscription);
    await tunnel.disconnect();
    final before = core.connectCount;
    await Future<void>.delayed(const Duration(seconds: 5));
    expect(core.connectCount, before,
        reason: 'нажатая кнопка «Отключить» — окончательное решение');
  });

  test('выключение из шторки при открытом приложении не отменяется', () async {
    tunnel.appInForeground = true;
    await tunnel.connect(_subscription);
    final before = core.connectCount;
    core.simulateDrop(); // так выглядит кнопка «Отключить» в шторке
    await Future<void>.delayed(const Duration(seconds: 5));
    expect(core.connectCount, before,
        reason: 'пользователь выключил VPN сам — включать обратно нельзя');
    expect(tunnel.isConnected, isFalse);
  });

  test('обрыв при свёрнутом приложении поднимается обратно сам', () async {
    tunnel.appInForeground = false;
    await tunnel.connect(_subscription);
    final before = core.connectCount;
    core.simulateDrop(); // сеть пропала, Android усыпил сервис
    final restored = await waitUntil(() => core.connectCount > before,
        timeout: const Duration(seconds: 8));
    expect(restored, isTrue, reason: 'туннель обязан вернуться сам');
    expect(await waitUntil(() => tunnel.isConnected), isTrue);
    await tunnel.disconnect();
  });

  test('экран не врёт «подключено», когда сервиса уже нет', () async {
    await tunnel.connect(_subscription);
    expect(tunnel.isConnected, isTrue);
    // Сервис погас, а событие до приложения не дошло — так бывает при
    // выключении из шторки или системных настроек.
    core.stateOverride = 'ServiceState.stopped';
    final corrected = await waitUntil(() => !tunnel.isConnected,
        timeout: const Duration(seconds: 15));
    expect(corrected, isTrue,
        reason: 'сторож обязан привести экран в соответствие');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('двойное нажатие «Подключить» не поднимает две сессии', () async {
    final first = tunnel.connect(_subscription);
    Object? secondError;
    try {
      await tunnel.connect(_subscription);
    } catch (e) {
      secondError = e;
    }
    await first;
    expect(secondError, isNotNull,
        reason: 'второе нажатие должно отказать, а не стартовать параллельно');
    expect(core.maxLiveSessions, 1);
    await tunnel.disconnect();
  });

  test('проверка серверов не стартует, пока идёт подключение', () async {
    final connecting = tunnel.connect(_subscription);
    // Подключение ещё готовится — статус «отключено», но ядро уже занято.
    final probe = await tunnel.realCheckAllProfiles(_subscription);
    await connecting;
    expect(probe, isEmpty,
        reason: 'проверка обязана уступить, а не поднимать сессию поверх');
    expect(core.maxLiveSessions, 1);
    await tunnel.disconnect();
  });

  test('«Подключить» во время проверки серверов — подключается с первого раза',
      () async {
    // Ровно та жалоба: открыл приложение, фоновая проверка уже пошла,
    // нажал «Подключить» — и ошибка по таймауту.
    unawaited(tunnel.realCheckAllProfiles(_subscription));
    await waitUntil(() => core.connectCount >= 1); // проверка подняла сессию
    await tunnel.connect(_subscription);
    expect(tunnel.isConnected, isTrue,
        reason: 'подключение не должно проваливаться из-за проверки');
    // Опоздавшая проверка не должна погасить уже поднятый туннель.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(tunnel.isConnected, isTrue,
        reason: 'проверка не имеет права обрывать чужую сессию');
    await tunnel.disconnect();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('рабочий туннель: фоновая проверка не уводит с выбранной локации',
      () async {
    final proxy = await startWorkingTunnel();
    try {
      await tunnel.connect(_subscription);
      // Фоновая проверка ждёт 3 с и спрашивает дважды.
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(core.selected, isEmpty,
          reason: 'связь есть — переключать локацию незачем');
      expect(tunnel.isConnected, isTrue);
      await tunnel.disconnect();
    } finally {
      await proxy.close(force: true);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('нет интернета ни на одной локации — сессия возвращается на исходную',
      () async {
    await tunnel.connect(_subscription);
    final heal = await waitUntil(() => core.selected.contains('out-0'),
        timeout: const Duration(seconds: 20));
    expect(heal, isTrue);
    expect(core.selected.last, 'out-0',
        reason: 'не оставлять сессию на последнем перебранном кандидате');
    await tunnel.disconnect();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('задача от старой сессии не трогает новую', () async {
    // Подключились, фоновая проверка уснула на 3 секунды…
    await tunnel.connect(_subscription);
    // …а пользователь тут же отключился и подключился заново.
    await tunnel.disconnect();
    await tunnel.connect(_subscription);
    // Дождёмся, пока отработает проверка новой сессии.
    await waitUntil(() => core.selected.contains('out-0'),
        timeout: const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(seconds: 2));
    // Одна живая проверка: out-1, out-2, затем возврат на out-0 — три
    // переключения. Две (старая + новая) дали бы шесть.
    expect(core.selected.length, 3,
        reason: 'проснувшаяся задача от старой сессии полезла в новую: '
            '${core.selected}');
    await tunnel.disconnect();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('после проверки серверов журнал ядра снова доходит, ровно по разу',
      () async {
    // Проверка снимает подписки на время своей сессии. Журнал ядра раньше не
    // возвращался вовсе — ошибки ядра после неё пропадали из журнала.
    final server = await startWorkingTunnel();
    addTearDown(() => server.close(force: true));
    await tunnel.realCheckAllProfiles(_subscription);
    final before = AppLogService.instance.debugWriteCount;
    core.emitCoreLog([
      LogEntry(
          level: LogLevel.warn,
          message: 'WARN[0005] outbound/vless[out-0]: dial tcp: i/o timeout',
          time: DateTime.now()),
    ]);
    await waitUntil(
        () => AppLogService.instance.debugWriteCount > before,
        timeout: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(AppLogService.instance.debugWriteCount, before + 1,
        reason: 'строка ядра должна попасть в журнал один раз');
  }, timeout: const Timeout(Duration(seconds: 90)));
}
