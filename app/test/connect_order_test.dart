import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpnonline_app/services/local_prefs.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Подписка: Германия быстрая, но стоит в списке третьей. Порядок в подписке
  // не значит ничего — упереться первой же кнопкой в далёкий или мёртвый узел
  // было обычным делом.
  const subscription =
      'vless://11111111-1111-1111-1111-111111111111@us.example.com:443'
          '?type=tcp&security=tls&sni=example.com#США\n'
      'vless://22222222-2222-2222-2222-222222222222@jp.example.com:443'
          '?type=tcp&security=tls&sni=example.com#Япония\n'
      'vless://33333333-3333-3333-3333-333333333333@de.example.com:443'
          '?type=tcp&security=tls&sni=example.com#Германия';

  const latency = {'США': 210, 'Япония': 330, 'Германия': 70};

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // LocalPrefs держит значения в памяти — отметки прошлых тестов стираем.
    await LocalPrefs.instance.setString(PrefKeys.deadLocationsJson, '');
    // Адреса выдуманные — по умолчанию считаем, что открываются все.
    TunnelService.instance.endpointReachableProbe = (_, __) async => true;
  });

  Future<List<String>> order({required bool chosenManually, String? preferred}) async {
    await LocalPrefs.instance
        .setString(PrefKeys.cachedLatencyJson, jsonEncode(latency));
    await LocalPrefs.instance
        .setBool(PrefKeys.serverChosenManually, chosenManually);
    final result = await TunnelService.instance
        .debugOrderProfilesForConnect(subscription, preferred);
    return result;
  }

  test('страну не выбирали — первой идёт самая быстрая', () async {
    expect(await order(chosenManually: false), ['Германия', 'США', 'Япония']);
  });

  test('страну выбрали сами — её выбор важнее замеров', () async {
    final result = await order(chosenManually: true, preferred: 'Япония');
    expect(result.first, 'Япония');
  });

  test('замеров нет — порядок подписки не переставляется', () async {
    // LocalPrefs держит значения в памяти, поэтому пустой снимок нужно
    // записать явно, а не полагаться на сброс SharedPreferences.
    await LocalPrefs.instance.setString(PrefKeys.cachedLatencyJson, '');
    await LocalPrefs.instance.setBool(PrefKeys.serverChosenManually, false);
    final result = await TunnelService.instance
        .debugOrderProfilesForConnect(subscription, null);
    expect(result, ['США', 'Япония', 'Германия']);
  });

  group('замолчавшая локация', () {
    test('выбрана вручную, но недавно замолчала — начинаем с самой быстрой '
        'живой, а выбранная второй: её проверит замер в этой же сессии',
        () async {
      await TunnelService.instance.debugMarkLocationDead('Япония');
      final result = await order(chosenManually: true, preferred: 'Япония');
      expect(result, ['Германия', 'Япония', 'США']);
    });

    test('ответила на замер — снова первая, выбор пользователя в силе',
        () async {
      await TunnelService.instance.debugMarkLocationDead('Япония');
      await TunnelService.instance.debugClearDeadMarks(['Япония']);
      final result = await order(chosenManually: true, preferred: 'Япония');
      expect(result.first, 'Япония');
    });

    test('не выбирали сами — замолчавшая уходит в конец даже при хорошем '
        'старом замере', () async {
      // По старому замеру Германия быстрее всех, но сейчас она молчит.
      await TunnelService.instance.debugMarkLocationDead('Германия');
      expect(await order(chosenManually: false), ['США', 'Япония', 'Германия']);
    });

    test('старая отметка (больше двенадцати часов) не мешает', () async {
      final old = DateTime.now()
          .subtract(const Duration(hours: 13))
          .millisecondsSinceEpoch;
      await LocalPrefs.instance.setString(
          PrefKeys.deadLocationsJson, jsonEncode({'Япония': old}));
      final result = await order(chosenManually: true, preferred: 'Япония');
      expect(result.first, 'Япония');
    });

    test('замеров нет — замолчавшая всё равно не первой', () async {
      await LocalPrefs.instance.setString(PrefKeys.cachedLatencyJson, '');
      await LocalPrefs.instance.setBool(PrefKeys.serverChosenManually, false);
      await TunnelService.instance.debugMarkLocationDead('США');
      final result = await TunnelService.instance
          .debugOrderProfilesForConnect(subscription, null);
      expect(result, ['Япония', 'Германия', 'США']);
    });
  });

  test('страну выбрали сами — запасные места в сессии занимают самые '
      'быстрые, а не первые по подписке', () async {
    // Подписка: США, Япония, Германия; по замеру Германия быстрее США.
    final result = await order(chosenManually: true, preferred: 'Япония');
    expect(result, ['Япония', 'Германия', 'США']);
  });

  test('не ответившие на замер уходят в конец даже без ухода с них', () async {
    await TunnelService.instance.debugMarkLocationDead('США');
    expect(await order(chosenManually: false), ['Германия', 'Япония', 'США']);
  });

  group('переход на более быструю', () {
    test('вдвое медленнее и на 200+ мс — переходим', () {
      expect(TunnelService.shouldPreferFaster(current: 1460, best: 87), isTrue);
      expect(TunnelService.shouldPreferFaster(current: 467, best: 87), isTrue);
    });
    test('мелкая разница или всплеск — остаёмся', () {
      expect(TunnelService.shouldPreferFaster(current: 150, best: 87), isFalse);
      expect(TunnelService.shouldPreferFaster(current: 300, best: 200), isFalse);
      expect(TunnelService.shouldPreferFaster(current: 260, best: 87), isFalse,
          reason: 'втрое медленнее, но разница меньше 200 мс');
    });
  });

  group('приоритет зарубежных серверов', () {
    test('российская локация распознаётся по флагу и названию', () {
      expect(TunnelService.isRussianLocation('🇷🇺 Россия'), isTrue);
      expect(TunnelService.isRussianLocation('Россия (3)'), isTrue);
      expect(
          TunnelService.isRussianLocation(
              '🇷🇺 Мобильный интернет #5 | Билайн'),
          isTrue);
      expect(TunnelService.isRussianLocation('🇳🇱 Белые списки №3'), isFalse);
      expect(TunnelService.isRussianLocation('🇬🇧 Англия (через Москву)'),
          isFalse);
    });

    test('среди ответивших выбираем самую быструю зарубежную', () {
      // Россия быстрее всех, но её выход блокировки не обходит — берём
      // зарубежную.
      expect(
          TunnelService.pickPreferredLive(
              {'🇷🇺 Россия': 45, '🇳🇱 Нидерланды': 90, '🇬🇧 Англия': 120}),
          '🇳🇱 Нидерланды');
    });

    test('зарубежных среди ответивших нет — берём самую быструю из всех', () {
      expect(
          TunnelService.pickPreferredLive(
              {'🇷🇺 Россия': 80, '🇷🇺 Мобильный интернет #9': 70}),
          '🇷🇺 Мобильный интернет #9');
    });

    test('пустой ввод или нули — null', () {
      expect(TunnelService.pickPreferredLive(const {}), isNull);
      expect(TunnelService.pickPreferredLive({'🇷🇺 Россия': 0}), isNull);
    });
  });

  group('адрес не открывается из текущей сети', () {
    // Журнал 07.11: «самой быстрой» по замеру из мобильной сети был мост
    // 212.15.49.92:9443, а с Wi-Fi до него не открывался даже TCP.
    test('самая быстрая по старому замеру закрыта — первой идёт доступная',
        () async {
      TunnelService.instance.endpointReachableProbe =
          (host, _) async => host != 'de.example.com';
      expect(await order(chosenManually: false), ['США', 'Япония', 'Германия']);
    });

    test('выбранная вручную закрыта — первой доступная, выбранная второй',
        () async {
      TunnelService.instance.endpointReachableProbe =
          (host, _) async => host != 'jp.example.com';
      final result = await order(chosenManually: true, preferred: 'Япония');
      expect(result, ['Германия', 'Япония', 'США']);
    });

    test('не открылся никто (нет сети) — проверка ничего не говорит, порядок '
        'прежний', () async {
      TunnelService.instance.endpointReachableProbe = (_, __) async => false;
      expect(await order(chosenManually: false), ['Германия', 'США', 'Япония']);
    });

    test('адрес молчит дольше полутора секунд — для этой сети он закрыт, '
        'подключение не ждёт его дольше', () async {
      TunnelService.instance.endpointReachableProbe = (host, _) async {
        if (host == 'de.example.com') {
          await Future<void>.delayed(const Duration(seconds: 10));
        }
        return true;
      };
      final sw = Stopwatch()..start();
      final result = await order(chosenManually: false);
      sw.stop();
      expect(result.first, 'США');
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('все открылись быстро — ждать полторы секунды не нужно', () async {
      final sw = Stopwatch()..start();
      await order(chosenManually: false);
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 800)));
    });
  });

  group('Hysteria 2 ходит по UDP — TCP-стук в её порт ничего не значит', () {
    // Журнал 11.11: «Чехия · Hysteria 2» записана в «не открываются из этой
    // сети», хотя TCP-адреса того же сервера открывались. В её порт стучались
    // по TCP, а слушает он только UDP — такой стук всегда молчит.
    const sub =
        'vless://11111111-1111-1111-1111-111111111111@cz.example.com:443'
            '?type=tcp&security=tls&sni=example.com#Чехия\n'
        'hysteria2://pass@cz.example.com:8443?sni=example.com&insecure=1'
            '#Чехия · Hysteria 2\n'
        'vless://22222222-2222-2222-2222-222222222222@fi.example.com:443'
            '?type=tcp&security=tls&sni=example.com#Финляндия\n'
        'hysteria2://pass@fi.example.com:8443?sni=example.com&insecure=1'
            '#Финляндия · Hysteria 2\n'
        'vless://33333333-3333-3333-3333-333333333333@de.example.com:443'
            '?type=tcp&security=tls&sni=example.com#Германия';

    // Финляндия закрыта целиком, а в UDP-порты Hysteria TCP не проходит ни у
    // кого.
    Future<bool> probe(String host, int port) async =>
        host != 'fi.example.com' && port != 8443;

    Future<List<String>> orderOf(String body, {String? preferred}) async {
      await LocalPrefs.instance.setString(PrefKeys.cachedLatencyJson, '');
      await LocalPrefs.instance
          .setBool(PrefKeys.serverChosenManually, preferred != null);
      return TunnelService.instance
          .debugOrderProfilesForConnect(body, preferred);
    }

    test('сервер открыт, TCP в порт Hysteria — нет: локация не закрыта и при '
        'ручном выборе идёт первой', () async {
      TunnelService.instance.endpointReachableProbe = probe;
      final result = await orderOf(sub, preferred: 'Чехия · Hysteria 2');
      expect(result.first, 'Чехия · Hysteria 2');
    });

    test('сервер закрыт целиком — его Hysteria уходит в конец вместе с ним',
        () async {
      TunnelService.instance.endpointReachableProbe = probe;
      expect(await orderOf(sub), [
        'Чехия',
        'Чехия · Hysteria 2',
        'Германия',
        'Финляндия',
        'Финляндия · Hysteria 2',
      ]);
    });

    test('у сервера только Hysteria — судить не по чему, место не меняется',
        () async {
      const alone = 'hysteria2://pass@hy.example.com:443?sni=example.com'
          '&insecure=1#Только Hysteria\n'
          'vless://11111111-1111-1111-1111-111111111111@cz.example.com:443'
          '?type=tcp&security=tls&sni=example.com#Чехия\n'
          'vless://33333333-3333-3333-3333-333333333333@de.example.com:443'
          '?type=tcp&security=tls&sni=example.com#Германия';
      TunnelService.instance.endpointReachableProbe =
          (host, _) async => host != 'hy.example.com';
      expect(await orderOf(alone), ['Только Hysteria', 'Чехия', 'Германия']);
    });
  });

  group('обход «белых списков» и чистый выход', () {
    // Чехия/Германия — свои серверы; «Авто БС …» — общий обходной узел,
    // который делят тысячи людей (с него Google/Gemini ловят капчу).
    const sub =
        'vless://11111111-1111-1111-1111-111111111111@de.example.com:443'
            '?type=tcp&security=tls&sni=example.com#🇩🇪 Германия\n'
        'vless://22222222-2222-2222-2222-222222222222@se.example.com:443'
            '?type=tcp&security=tls&sni=example.com#🇸🇪 Авто БС Швеция 1 сервер\n'
        'vless://33333333-3333-3333-3333-333333333333@us.example.com:443'
            '?type=tcp&security=tls&sni=example.com#🇺🇸 США';

    Future<List<String>> autoOrder(Map<String, int> lat,
        {bool preferBypass = false}) async {
      await LocalPrefs.instance
          .setString(PrefKeys.cachedLatencyJson, jsonEncode(lat));
      await LocalPrefs.instance.setBool(PrefKeys.serverChosenManually, false);
      if (preferBypass) TunnelService.instance.debugPreferBypassNext = true;
      return TunnelService.instance.debugOrderProfilesForConnect(sub, null);
    }

    test('обходные локации распознаются по названию', () {
      expect(
          TunnelService.isBypassLocation('🇸🇪 Авто БС Швеция 1 сервер'), isTrue);
      expect(
          TunnelService.isBypassLocation('🇩🇪 Германия • БС (НОВОЕ)'), isTrue);
      expect(TunnelService.isBypassLocation('LTE Обход'), isTrue);
      expect(TunnelService.isBypassLocation('🇳🇱 Белые списки №3'), isTrue);
      expect(TunnelService.isBypassLocation('🇩🇪 Германия'), isFalse);
      expect(TunnelService.isBypassLocation('🇺🇸 США'), isFalse);
    });

    test('авто-режим ведёт на свой чистый сервер, когда общий узел быстрее '
        'лишь ненамного', () async {
      final result = await autoOrder(
          {'🇩🇪 Германия': 80, '🇸🇪 Авто БС Швеция 1 сервер': 60, '🇺🇸 США': 200});
      expect(result.first, '🇩🇪 Германия');
    });

    test('общий узел намного быстрее своего — остаёмся на нём', () async {
      final result = await autoOrder(
          {'🇩🇪 Германия': 200, '🇸🇪 Авто БС Швеция 1 сервер': 60, '🇺🇸 США': 300});
      expect(result.first, '🇸🇪 Авто БС Швеция 1 сервер');
    });

    test('пересборка молчащей сессии — обходные локации впереди', () async {
      final result = await autoOrder(
          {'🇩🇪 Германия': 80, '🇸🇪 Авто БС Швеция 1 сервер': 200, '🇺🇸 США': 90},
          preferBypass: true);
      expect(result.first, '🇸🇪 Авто БС Швеция 1 сервер');
    });

    test('приоритет обхода одноразовый — следующий порядок обычный', () async {
      await autoOrder(
          {'🇩🇪 Германия': 80, '🇸🇪 Авто БС Швеция 1 сервер': 200, '🇺🇸 США': 90},
          preferBypass: true);
      final result = await autoOrder(
          {'🇩🇪 Германия': 80, '🇸🇪 Авто БС Швеция 1 сервер': 200, '🇺🇸 США': 90});
      expect(result.first, '🇩🇪 Германия');
    });
  });
}
