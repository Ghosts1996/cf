// Целостность сессии: ядро стартует там, где думает приложение; экран не
// врёт «Подключено»; подключение не ждёт сеть ради подписки.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpnonline_app/services/local_prefs.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

import 'support/fake_runtime.dart';

String _link(String id, String host, String name) =>
    'vless://$id@$host:443?type=tcp&security=reality'
    '&pbk=e8Q_05VmcuO12_QIua9nojVHZViU73hqOOZShYo52-c&sid=aa&sni=yahoo.com'
    '&fp=chrome#$name';

final _de = _link('11111111-1111-1111-1111-111111111111', 'de.example.com', 'Германия');
final _nl = _link('22222222-2222-2222-2222-222222222222', 'nl.example.com', 'Нидерланды');
final _lv = _link('33333333-3333-3333-3333-333333333333', 'lv.example.com', 'Латвия');

Future<HttpServer> _workingTunnel() async {
  final server =
      await HttpServer.bind(InternetAddress.loopbackIPv4, 2080, shared: true);
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
    HttpOverrides.global = null;
    await LocalPrefs.instance.setString(PrefKeys.subscriptionCacheJson, '');
    await LocalPrefs.instance.setString(PrefKeys.deadLocationsJson, '');
    await LocalPrefs.instance.setString(PrefKeys.cachedLatencyJson, '');
    await LocalPrefs.instance.setBool(PrefKeys.serverChosenManually, false);
    core = FakeRuntime();
    tunnel = TunnelService.withRuntime(core);
  });

  group('выбор сервера не переезжает между сессиями', () {
    Map<String, dynamic> cacheFile(String config) =>
        ((jsonDecode(config) as Map)['experimental'] as Map)['cache_file']
            as Map<String, dynamic>;

    test('у каждого набора серверов свой раздел кэша ядра', () {
      final a = TunnelService.instance
          .buildConfigFromUri(_de, alternateUris: [_nl, _lv]);
      final same = TunnelService.instance
          .buildConfigFromUri(_de, alternateUris: [_nl, _lv]);
      final reordered = TunnelService.instance
          .buildConfigFromUri(_lv, alternateUris: [_de, _nl]);
      final idA = cacheFile(a)['cache_id'];
      expect(idA, startsWith('sel-'));
      expect(cacheFile(same)['cache_id'], idA,
          reason: 'тот же набор в том же порядке — тот же раздел');
      expect(cacheFile(reordered)['cache_id'], isNot(idA),
          reason: 'out-0 теперь другой сервер — выбор прошлой сессии '
              'применять нельзя');
    });

    test('одна локация, без группы — раздел не нужен', () {
      expect(cacheFile(TunnelService.instance.buildConfigFromUri(_de))
          .containsKey('cache_id'), isFalse);
    });

    test('после старта ядро явно ставится на первую локацию', () async {
      final server = await _workingTunnel();
      addTearDown(() => server.close(force: true));
      await tunnel.connect('$_de\n$_nl\n$_lv');
      expect(core.selected.first, 'out-0');
      await tunnel.disconnect();
    });
  });

  test('одноимённые локации в одну сессию не попадают', () async {
    final server = await _workingTunnel();
    addTearDown(() => server.close(force: true));
    final italy2 = _link(
        '44444444-4444-4444-4444-444444444444', 'it2.example.com', 'Италия');
    final italy1 = _link(
        '55555555-5555-5555-5555-555555555555', 'it1.example.com', 'Италия');
    await tunnel.connect('$_de\n$italy1\n$_nl\n$italy2');
    final outbounds = ((jsonDecode(core.lastConfig!) as Map)['outbounds']
            as List)
        .where((o) => '${(o as Map)['tag']}'.startsWith('out-'))
        .map((o) => (o as Map)['server'])
        .toList();
    expect(outbounds, ['de.example.com', 'it1.example.com', 'nl.example.com']);
    await tunnel.disconnect();
  });

  test('хвост прошлой сессии сначала гасится, потом стартует новое ядро',
      () async {
    final server = await _workingTunnel();
    addTearDown(() => server.close(force: true));
    core.leftoverSession = true;
    await tunnel.connect('$_de\n$_nl');
    final firstDisconnect = core.calls.indexOf('disconnect');
    final firstConnect = core.calls.indexOf('connect');
    expect(firstDisconnect, greaterThanOrEqualTo(0));
    expect(firstDisconnect, lessThan(firstConnect),
        reason: 'нельзя запускать ядро поверх недобитого: ${core.calls}');
    expect(tunnel.isConnected, isTrue);
    await tunnel.disconnect();
  });

  group('сторож: «Подключено» без VPN в системе', () {
    test('VPN-интерфейс был и пропал — показываем «отключено»', () async {
      final server = await _workingTunnel();
      addTearDown(() => server.close(force: true));
      await tunnel.connect('$_de\n$_nl');
      var up = true;
      tunnel.vpnInterfaceProbe = () async => up;
      await tunnel.debugCheckRealState();
      expect(tunnel.isConnected, isTrue);
      up = false;
      final before = core.disconnectCount;
      await tunnel.debugCheckRealState();
      expect(tunnel.isConnected, isTrue, reason: 'одному ответу не верим');
      await tunnel.debugCheckRealState();
      expect(tunnel.isConnected, isFalse);
      expect(core.disconnectCount, greaterThan(before),
          reason: 'остатки сессии в плагине гасятся');
    });

    test('прошивка не показывает приложению VPN вовсе — живую сессию не '
        'трогаем', () async {
      final server = await _workingTunnel();
      addTearDown(() => server.close(force: true));
      await tunnel.connect('$_de\n$_nl');
      tunnel.vpnInterfaceProbe = () async => false;
      for (var i = 0; i < 4; i++) {
        await tunnel.debugCheckRealState();
      }
      expect(tunnel.isConnected, isTrue);
      tunnel.vpnInterfaceProbe = () async => null;
      await tunnel.debugCheckRealState();
      expect(tunnel.isConnected, isTrue);
      await tunnel.disconnect();
    });
  });

  group('подписка: подключение не ждёт сеть', () {
    late HttpServer sub;
    late Future<void> Function(HttpResponse) reply;
    late String url;
    var requests = 0;

    setUp(() async {
      requests = 0;
      sub = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      url = 'http://127.0.0.1:${sub.port}/sub';
      sub.listen((req) async {
        requests++;
        await reply(req.response);
      });
    });
    tearDown(() => sub.close(force: true));

    test('копия сохраняется и выручает, когда сервер подписки лёг', () async {
      reply = (r) async {
        r.write('$_de\n$_nl');
        await r.close();
      };
      expect(await tunnel.debugLoadProfileCount(url), 2);
      reply = (r) async {
        r.statusCode = 503;
        await r.close();
      };
      tunnel.debugDropMemoryCache();
      expect(await tunnel.debugLoadProfileCount(url, forceRefresh: true), 2,
          reason: 'сервер подписки недоступен — берём сохранённую копию');
    });

    test('медленный сервер подписки не задерживает подключение', () async {
      reply = (r) async {
        r.write('$_de\n$_nl\n$_lv');
        await r.close();
      };
      await tunnel.debugLoadProfileCount(url);
      // Копия «устарела», а сервер теперь отвечает пять секунд.
      final stale = jsonDecode((await LocalPrefs.instance
          .getString(PrefKeys.subscriptionCacheJson))!) as Map;
      stale['savedAt'] = DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch;
      await LocalPrefs.instance
          .setString(PrefKeys.subscriptionCacheJson, jsonEncode(stale));
      reply = (r) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        r.write('$_de\n$_nl');
        await r.close();
      };
      tunnel.debugDropMemoryCache();
      final sw = Stopwatch()..start();
      expect(await tunnel.debugLoadProfileCount(url), 3);
      expect(sw.elapsedMilliseconds, lessThan(1000));
      // А свежая копия подтянулась в фоне — к следующему разу.
      final refreshed = await () async {
        final end = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(end)) {
          final raw = await LocalPrefs.instance
              .getString(PrefKeys.subscriptionCacheJson);
          if (raw != null && !(jsonDecode(raw)['body'] as String).contains('lv.')) {
            return true;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        return false;
      }();
      expect(refreshed, isTrue);
      expect(requests, 2);
    });
  });
}
