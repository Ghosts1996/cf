import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

/// Ссылка с XHTTP в том виде, в каком её отдают панели: transport в `type`,
/// режим в `mode`, остальное — JSON в `extra` (заголовки, паддинг, отдельный
/// канал скачивания).
const _xhttpUri = 'vless://11111111-2222-3333-4444-555555555555@example.com:443'
    '?security=reality&pbk=AAAABBBBCCCCDDDDEEEEFFFF0000111122223333444&sid=ab12'
    '&sni=www.microsoft.com&fp=chrome&type=xhttp&mode=stream-up'
    '&host=cdn.example.com&path=%2Fxh'
    '&extra=%7B%22scMaxEachPostBytes%22%3A1000000%2C%22noGRPCHeader%22%3Atrue%2C'
    '%22headers%22%3A%7B%22X-Test%22%3A%22yes%22%7D%2C%22downloadSettings%22%3A'
    '%7B%22address%22%3A%22dl.example.com%22%2C%22port%22%3A8443%2C%22security%22'
    '%3A%22tls%22%2C%22tlsSettings%22%3A%7B%22serverName%22%3A%22dl.example.com%22'
    '%2C%22fingerprint%22%3A%22chrome%22%7D%7D%7D#XHTTP%20Location';

const _realityUri = 'vless://66666666-7777-8888-9999-000000000000@de.example.com:443'
    '?security=reality&pbk=ZZZZYYYYXXXXWWWWVVVVUUUU0000111122223333444&sid=cd34'
    '&sni=www.microsoft.com&fp=chrome&type=tcp#DE';

Map<String, dynamic> _proxyOutbound(String rawConfig) {
  final config = jsonDecode(rawConfig) as Map<String, dynamic>;
  final outbounds = (config['outbounds'] as List).cast<Map<String, dynamic>>();
  return outbounds.firstWhere((o) => o['tag'] == 'proxy' || o['tag'] == 'out-0');
}

void main() {
  final tunnel = TunnelService.instance;

  group('конфиг XHTTP', () {
    late Map<String, dynamic> transport;

    setUpAll(() {
      final raw = tunnel.buildConfigFromUri(_xhttpUri, proxyOnly: true);
      transport = _proxyOutbound(raw)['transport'] as Map<String, dynamic>;
    });

    test('тип и режим берутся из ссылки', () {
      expect(transport['type'], 'xhttp');
      expect(transport['mode'], 'stream-up');
    });

    test('без mode в ссылке подставляется auto — без него ядро откажет', () {
      final raw = tunnel.buildConfigFromUri(
        'vless://11111111-2222-3333-4444-555555555555@example.com:443'
        '?type=xhttp&path=%2Fx&security=none#NoMode',
        proxyOnly: true,
      );
      final t = _proxyOutbound(raw)['transport'] as Map<String, dynamic>;
      expect(t['mode'], 'auto');
    });

    test('host и path подставляются из ссылки, если их нет в extra', () {
      expect(transport['host'], 'cdn.example.com');
      expect(transport['path'], '/xh');
    });

    test('поля extra переносятся как есть, в camelCase ядра', () {
      expect(transport['scMaxEachPostBytes'], 1000000);
      expect(transport['noGRPCHeader'], true);
      expect(transport['headers'], {'X-Test': 'yes'});
    });

    test('downloadSettings переводится в формат ядра', () {
      final download = transport['downloadSettings'] as Map<String, dynamic>;
      expect(download['server'], 'dl.example.com');
      expect(download['server_port'], 8443);
      // path у канала скачивания не задан — наследуется от основного.
      expect(download['path'], '/xh');
      final tls = download['tls'] as Map<String, dynamic>;
      expect(tls['enabled'], true);
      expect(tls['server_name'], 'dl.example.com');
      expect((tls['utls'] as Map)['fingerprint'], 'chrome');
      // Xray-поля, у которых в ядре свои имена, не должны просочиться.
      expect(download.containsKey('address'), isFalse);
      expect(download.containsKey('tlsSettings'), isFalse);
    });
  });

  group('обычные профили не задеты', () {
    test('reality поверх tcp остаётся без блока transport', () {
      final outbound = _proxyOutbound(tunnel.buildConfigFromUri(_realityUri));
      expect(outbound.containsKey('transport'), isFalse);
      expect((outbound['tls'] as Map)['enabled'], true);
      expect(((outbound['tls'] as Map)['reality'] as Map)['enabled'], true);
    });

    test('несколько локаций собираются в группу-селектор', () {
      final raw = tunnel.buildConfigFromUri(
        _realityUri,
        alternateUris: const [_xhttpUri],
      );
      final config = jsonDecode(raw) as Map<String, dynamic>;
      final outbounds = (config['outbounds'] as List).cast<Map<String, dynamic>>();
      final selector = outbounds.firstWhere((o) => o['type'] == 'selector');
      expect(selector['tag'], 'proxy');
      expect(selector['outbounds'], ['out-0', 'out-1']);
      expect(selector['default'], 'out-0');
    });
  });

  test('конфиги сохраняются для проверки настоящим ядром', () {
    final dir = Directory('${Directory.systemTemp.path}/vpnonline-config-probe')
      ..createSync(recursive: true);
    File('${dir.path}/xhttp.json')
        .writeAsStringSync(tunnel.buildConfigFromUri(_xhttpUri, proxyOnly: true));
    File('${dir.path}/reality.json')
        .writeAsStringSync(tunnel.buildConfigFromUri(_realityUri, proxyOnly: true));
    // ignore: avoid_print
    print('configs: ${dir.path}');
    expect(Directory(dir.path).listSync().length, 2);
  });
  group('обход DPI', () {
    const reality = 'vless://11111111-1111-1111-1111-111111111111@a.example.com:443'
        '?type=tcp&security=reality&pbk=PUBKEY&sid=aa&sni=yahoo.com'
        '&fp=chrome&flow=xtls-rprx-vision#DPI';

    Map<String, dynamic> proxyOf(String config) =>
        (jsonDecode(config) as Map<String, dynamic>)['outbounds']
            .cast<Map<String, dynamic>>()
            .first as Map<String, dynamic>;

    test('на ядре с поддержкой рвётся собственное рукопожатие', () {
      final config = TunnelService.instance.buildConfigFromUri(reality,
          proxyOnly: true, dpiBypass: true, tlsFragmentSupported: true);
      final fragment = proxyOf(config)['tls_fragment'] as Map<String, dynamic>;
      expect(fragment['enabled'], true);
      expect(fragment['method'], 'tlsHello');
      // Правило маршрутизации при этом не нужно: оно рвёт трафик уже внутри
      // туннеля и от блокировки по ClientHello не спасает.
      final rules = (jsonDecode(config) as Map<String, dynamic>)['route']
          ['rules'] as List;
      expect(rules.any((r) => (r as Map).containsKey('tls_fragment')), isFalse);
    });

    test('на штатном ядре остаётся прежнее правило маршрутизации', () {
      final config = TunnelService.instance.buildConfigFromUri(reality,
          proxyOnly: true, dpiBypass: true, tlsFragmentSupported: false);
      expect(proxyOf(config).containsKey('tls_fragment'), isFalse);
      final rules = (jsonDecode(config) as Map<String, dynamic>)['route']
          ['rules'] as List;
      expect(rules.any((r) => (r as Map)['tls_fragment'] == true), isTrue);
    });

    test('выключенный тумблер не добавляет ничего', () {
      final config = TunnelService.instance.buildConfigFromUri(reality,
          proxyOnly: true, dpiBypass: false, tlsFragmentSupported: true);
      expect(proxyOf(config).containsKey('tls_fragment'), isFalse);
    });
  });

  group('замер задержки', () {
    const reality = 'vless://11111111-1111-1111-1111-111111111111@a.example.com:443'
        '?type=tcp&security=reality&pbk=PUBKEY&sid=aa&sni=yahoo.com'
        '&fp=chrome&flow=xtls-rprx-vision#PING';

    Map<String, dynamic> experimentalOf(String config) =>
        (jsonDecode(config) as Map<String, dynamic>)['experimental']
            as Map<String, dynamic>;

    Map<String, dynamic> latencyGroupOf(String config) =>
        ((jsonDecode(config) as Map<String, dynamic>)['outbounds'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((o) => o['tag'] == 'latency');

    test('на ядре с поддержкой включается единая задержка', () {
      final config = TunnelService.instance
          .buildConfigFromUri(reality, unifiedDelaySupported: true);
      final unified =
          experimentalOf(config)['unified_delay'] as Map<String, dynamic>;
      expect(unified['enabled'], true);
    });

    test('на штатном ядре поля нет — оно отвергло бы конфиг целиком', () {
      final config = TunnelService.instance
          .buildConfigFromUri(reality, unifiedDelaySupported: false);
      expect(experimentalOf(config).containsKey('unified_delay'), isFalse);
    });

    test('проверка всех локаций видит всю подписку, а не только первую', () {
      // Так собирается конфиг «Реальной проверки»: proxy-режим и все
      // остальные локации подписки. Раньше группа-селектор в proxy-режиме не
      // собиралась, в группе latency оставался один участник, и на экране
      // все локации кроме первой показывались как «не отвечает».
      final raw = TunnelService.instance.buildConfigFromUri(
        reality,
        proxyOnly: true,
        alternateUris: const [
          'vless://22222222-2222-2222-2222-222222222222@b.example.com:443'
              '?type=tcp&security=reality&pbk=PUBKEY&sid=bb&sni=yahoo.com#PING2',
        ],
      );
      final group = latencyGroupOf(raw);
      expect(group['outbounds'], ['out-0', 'out-1']);
      final outbounds =
          ((jsonDecode(raw) as Map<String, dynamic>)['outbounds'] as List)
              .cast<Map<String, dynamic>>();
      expect(outbounds.any((o) => o['tag'] == 'out-0'), isTrue);
      expect(outbounds.any((o) => o['tag'] == 'out-1'), isTrue);
      // Маршрут по-прежнему заканчивается на proxy — теперь это селектор.
      final selector = outbounds.firstWhere((o) => o['tag'] == 'proxy');
      expect(selector['type'], 'selector');
      expect(selector['default'], 'out-0');
    });

    test('группа latency меряет по тому же адресу, что и Hiddify', () {
      final config = TunnelService.instance.buildConfigFromUri(reality);
      final group = latencyGroupOf(config);
      expect(group['type'], 'urltest');
      expect(group['url'], 'http://cp.cloudflare.com/');
    });
  });
}
