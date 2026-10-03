// Windows: конфиг под штатный sing-box.exe и управление ядром через Clash API.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/clash_api.dart';
import 'package:vpnonline_app/services/singbox_runtime_windows.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

const _de = 'vless://11111111-1111-1111-1111-111111111111@127.0.0.1:24443'
    '?type=tcp&security=reality&pbk=e8Q_05VmcuO12_QIua9nojVHZViU73hqOOZShYo52-c'
    '&sid=aa&sni=yahoo.com&fp=chrome&flow=xtls-rprx-vision#DE';
const _nl = 'vless://22222222-2222-2222-2222-222222222222@127.0.0.1:24444'
    '?type=tcp&security=none#NL';

Map<String, dynamic> _windowsConfig({bool dnsProtection = false}) =>
    WindowsSingboxRuntime.prepareWindowsConfig(
        TunnelService.instance.buildConfigFromUri(
      _de,
      alternateUris: const [_nl],
      dnsProtection: dnsProtection,
      // Всё, что форк ядра на Android умеет сверх штатного sing-box.
      multiDnsSupported: true,
      unifiedDelaySupported: true,
      monitoringOptionsSupported: true,
      fakeIpDns: true,
      blockAds: true,
      adBlockRuleSetPath: File('assets/adblock/adblock.srs').absolute.path,
    ));

void main() {
  group('конфиг под sing-box.exe', () {
    test('DNS через туннель по TCP, даже если «Защита от DNS-протечек» '
        'выключена', () {
      final c = _windowsConfig();
      final dns = c['dns'] as Map;
      expect(dns['final'], 'dns-remote');
      final servers = (dns['servers'] as List).cast<Map>();
      expect(servers.any((s) => s['type'] == 'multi'), isFalse,
          reason: 'составного резолвера у штатного sing-box нет');
      final remote = servers.firstWhere((s) => s['tag'] == 'dns-remote');
      expect(remote['type'], 'tcp');
      expect(remote['detour'], 'proxy');
      expect((c['route'] as Map)['default_domain_resolver'],
          {'server': 'dns-direct'});
    });

    test('ничего из форка ядра: только Clash API в experimental', () {
      final c = _windowsConfig();
      expect(c['experimental'], {
        'clash_api': {'external_controller': '127.0.0.1:9095'}
      });
      final tun = (c['inbounds'] as List)
          .cast<Map>()
          .firstWhere((i) => i['type'] == 'tun');
      expect(tun['interface_name'], 'VPNonLine');
      expect(tun.containsKey('exclude_package'), isFalse);
    });

    test('конфиг для проверки штатным ядром', () {
      final dir = Directory('/tmp/vpnonline-win')..createSync(recursive: true);
      File('${dir.path}/config.json')
          .writeAsStringSync(jsonEncode(_windowsConfig()));
      File('${dir.path}/config-dnsprot.json')
          .writeAsStringSync(jsonEncode(_windowsConfig(dnsProtection: true)));
    });
  });

  // Живая проверка клиента Clash API против настоящего sing-box. Бинарник —
  // через переменную окружения SINGBOX_BIN; без неё тест пропускается (в CI
  // ядра нет).
  final bin = Platform.environment['SINGBOX_BIN'];
  group('Clash API настоящего ядра', () {
    late Process core;
    late HttpServer probe;
    late Directory dir;
    const apiPort = 19195;
    late ClashApiClient api;

    setUp(() async {
      HttpOverrides.global = null;
      probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      probe.listen((r) {
        r.response.statusCode = 204;
        r.response.close();
      });
      dir = Directory.systemTemp.createTempSync('clash');
      final cfg = {
        'log': {'level': 'error'},
        'outbounds': [
          {'type': 'direct', 'tag': 'out-0'},
          {'type': 'direct', 'tag': 'out-1'},
          // Мёртвый участник: никто не слушает.
          {
            'type': 'socks',
            'tag': 'out-2',
            'server': '127.0.0.1',
            'server_port': 1
          },
          {
            'type': 'selector',
            'tag': 'proxy',
            'outbounds': ['out-0', 'out-1', 'out-2'],
            'default': 'out-0'
          },
          {
            'type': 'urltest',
            'tag': 'latency',
            'outbounds': ['out-0', 'out-1', 'out-2'],
            'url': 'http://127.0.0.1:${probe.port}/',
            'interval': '1h',
            'idle_timeout': '3h'
          },
        ],
        'route': {'final': 'proxy'},
        'experimental': {
          'clash_api': {'external_controller': '127.0.0.1:$apiPort'}
        },
      };
      File('${dir.path}/c.json').writeAsStringSync(jsonEncode(cfg));
      core = await Process.start(bin!, ['run', '-c', '${dir.path}/c.json']);
      api = ClashApiClient(port: apiPort);
      for (var i = 0; i < 50; i++) {
        try {
          if ((await api.members('proxy')).isNotEmpty) break;
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });

    tearDown(() async {
      api.close();
      core.kill(ProcessSignal.sigkill);
      await core.exitCode;
      await probe.close(force: true);
      dir.deleteSync(recursive: true);
    });

    test('участники, переключение, замер, закрытие соединений', () async {
      expect(await api.members('proxy'), ['out-0', 'out-1', 'out-2']);
      await api.select('proxy', 'out-1');
      final now = jsonDecode((await HttpClient()
                  .getUrl(Uri.parse('http://127.0.0.1:$apiPort/proxies/proxy'))
                  .then((r) => r.close())
                  .then((r) => r.transform(utf8.decoder).join()))) as Map;
      expect(now['now'], 'out-1');
      final delays = await api.groupDelay('latency',
          url: 'http://127.0.0.1:${probe.port}/');
      expect(delays.keys.toSet(), {'out-0', 'out-1'},
          reason: 'мёртвый out-2 в замер не попадает: $delays');
      await api.closeAllConnections();
      expect(() => api.select('proxy', 'нет-такого'), throwsStateError);
    });
  }, skip: bin == null ? 'нет SINGBOX_BIN — живая проверка пропущена' : false);
}
