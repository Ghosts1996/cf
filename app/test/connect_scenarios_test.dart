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
import 'package:vpnonline_app/services/local_prefs.dart';
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // LocalPrefs держит значения в памяти между тестами: замеры, отметки о
    // замолчавших локациях и копия подписки из прошлого сценария меняли бы
    // порядок подключения в следующем.
    for (final key in [
      PrefKeys.cachedLatencyJson,
      PrefKeys.deadLocationsJson,
      PrefKeys.subscriptionCacheJson,
    ]) {
      await LocalPrefs.instance.setString(key, '');
    }
    await LocalPrefs.instance.setBool(PrefKeys.serverChosenManually, false);
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
      // Единственный выбор — закрепление первой локации сразу после старта
      // (ядро не должно стартовать на выбранном в прошлой сессии сервере).
      expect(core.selected, ['out-0'],
          reason: 'связь есть — переключать локацию незачем');
      expect(tunnel.isConnected, isTrue);
      await tunnel.disconnect();
    } finally {
      await proxy.close(force: true);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('нет интернета ни на одной локации — остаёмся на выбранной, по мёртвым '
      'не скачем', () async {
    await tunnel.connect(_subscription);
    // Проверка: 3 с паузы, две попытки, замер с окном 12 с.
    await Future<void>.delayed(const Duration(seconds: 20));
    expect(core.selected, ['out-0'],
        reason: 'никто не ответил — это сеть телефона, а не сервер: '
            'переключаться некуда');
    expect(tunnel.isConnected, isTrue);
    await tunnel.disconnect();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('выбранная локация молчит, соседи живы — сразу на самую быструю живую, '
      'мёртвых соседей не пробуем', () async {
    // Ответила только третья локация; вторая (out-1) мертва.
    core.groupDelays = {'out-2': 45};
    await tunnel.connect(_subscription);
    final healed = await waitUntil(() => core.selected.contains('out-2'),
        timeout: const Duration(seconds: 25));
    expect(healed, isTrue);
    expect(core.selected, ['out-0', 'out-2'],
        reason: 'на мёртвую out-1 заходить нельзя: ${core.selected}');
    expect(tunnel.connectedServerName.value, 'Латвия');
    expect(core.closeAllCount, 1,
        reason: 'старые соединения на мёртвом сервере закрываются сразу');
    await tunnel.disconnect();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('задача от старой сессии не трогает новую', () async {
    core.groupDelays = {'out-1': 50};
    // Подключились, фоновая проверка уснула на 3 секунды…
    await tunnel.connect(_subscription);
    // …а пользователь тут же отключился и подключился заново.
    await tunnel.disconnect();
    await tunnel.connect(_subscription);
    // Дождёмся, пока отработает проверка новой сессии.
    await waitUntil(() => core.selected.contains('out-1'),
        timeout: const Duration(seconds: 25));
    await Future<void>.delayed(const Duration(seconds: 3));
    // Закрепление out-0 при каждом из двух стартов и одно переключение от
    // проверки новой сессии. Проснувшаяся старая дала бы второе.
    expect(core.selected, ['out-0', 'out-0', 'out-1'],
        reason: 'проснувшаяся задача от старой сессии полезла в новую: '
            '${core.selected}');
    await tunnel.disconnect();
  }, timeout: const Timeout(Duration(seconds: 50)));

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

  test('ядро не стартовало: порт занят прошлой сессией — подключаемся с '
      'первого нажатия и быстро, без ошибки', () async {
    final server = await startWorkingTunnel();
    addTearDown(() => server.close(force: true));
    core.failNextStarts = 1;
    final sw = Stopwatch()..start();
    await tunnel.connect(_subscription);
    sw.stop();
    expect(tunnel.isConnected, isTrue);
    expect(core.connectCount, 2, reason: 'одна неудачная попытка и повтор');
    expect(tunnel.connectedServerName.value, 'Германия',
        reason: 'сервер не виноват — повторяем ту же локацию, а не соседнюю');
    expect(core.maxLiveSessions, 1);
    // Раньше после такого сбоя ждали всё окно подъёма — 12+ секунд.
    expect(sw.elapsedMilliseconds, lessThan(6000));
    await tunnel.disconnect();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('сервер умер посреди работы — проверка живости уводит на живой сразу, '
      'а живой туннель не трогает', () async {
    var server = await startWorkingTunnel();
    addTearDown(() => server.close(force: true));
    await tunnel.connect(_subscription);
    tunnel.appInForeground = true;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    core.selected.clear();

    // Туннель жив — никаких переключений.
    await tunnel.debugLiveCheckTick();
    expect(core.selected, isEmpty);
    expect(tunnel.connectedServerName.value, 'Германия');

    // Сервер умер: запросы через туннель не проходят, а соседи по группе
    // отвечают.
    await server.close(force: true);
    core.groupDelays = {'out-1': 60, 'out-2': 40};
    await tunnel.debugLiveCheckTick();
    expect(core.selected, contains('out-2'),
        reason: 'переключение на самую быструю живую локацию');
    expect(tunnel.connectedServerName.value, 'Латвия');
    server = await startWorkingTunnel();
    await tunnel.disconnect();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('страну не выбирали, текущая медленная — переходим на быструю; '
      'выбрали сами — остаёмся', () async {
    final server = await startWorkingTunnel();
    addTearDown(() => server.close(force: true));
    await tunnel.connect(_subscription);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    core.selected.clear();
    core.groupDelays = {'out-0': 1460, 'out-1': 600, 'out-2': 87};
    await tunnel.debugRunLatencyProbe();
    expect(core.selected, ['out-2']);
    expect(tunnel.connectedServerName.value, 'Латвия');
    await tunnel.disconnect();

    // Тот же расклад, но страну человек выбрал сам — его выбор важнее.
    await LocalPrefs.instance.setBool(PrefKeys.serverChosenManually, true);
    await tunnel.connect(_subscription, preferredHostName: 'Германия');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    core.selected.clear();
    await tunnel.debugRunLatencyProbe();
    expect(core.selected, isEmpty);
    expect(tunnel.connectedServerName.value, 'Германия');
    await tunnel.disconnect();
  }, timeout: const Timeout(Duration(seconds: 40)));
}
