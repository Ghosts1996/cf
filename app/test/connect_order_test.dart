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

  setUp(() => SharedPreferences.setMockInitialValues({}));

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
}
