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
}
