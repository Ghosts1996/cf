// Блокировка рекламы: большой список (rule-set с диска) в конфиге ядра и
// раскладка файла списка на диск.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/ad_block_rules.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

const _link = 'vless://11111111-2222-3333-4444-555555555555@127.0.0.1:24443'
    '?type=tcp&security=none#VLESS';

Map<String, dynamic> _config({
  bool blockAds = true,
  String? path = '/data/adblock.srs',
  bool fakeIpDns = false,
  bool proxyOnly = false,
}) =>
    jsonDecode(TunnelService.instance.buildConfigFromUri(
      _link,
      blockAds: blockAds,
      adBlockRuleSetPath: path,
      fakeIpDns: fakeIpDns,
      proxyOnly: proxyOnly,
    )) as Map<String, dynamic>;

void main() {
  group('конфиг ядра', () {
    test('большой список: DNS отвечает «нет такого домена», соединения '
        'отклоняются', () {
      final c = _config(fakeIpDns: true);
      final route = c['route'] as Map<String, dynamic>;
      final ruleSets = route['rule_set'] as List;
      expect(ruleSets, hasLength(1));
      expect(ruleSets.single, {
        'type': 'local',
        'tag': 'adblock',
        'format': 'binary',
        'path': '/data/adblock.srs',
      });

      final dnsRules = (c['dns'] as Map)['rules'] as List;
      // Реклама — раньше Fake IP: иначе рекламный домен получил бы служебный
      // адрес и приложение пошло бы соединяться.
      final adIdx = dnsRules.indexWhere((r) => (r as Map)['rule_set'] != null);
      final fakeIdx =
          dnsRules.indexWhere((r) => (r as Map)['server'] == 'dns-fake');
      expect(adIdx, greaterThanOrEqualTo(0));
      expect(fakeIdx, greaterThan(adIdx));
      expect(dnsRules[adIdx], {
        'rule_set': ['adblock'],
        'action': 'predefined',
        'rcode': 'NXDOMAIN',
      });

      final routeRules = route['rules'] as List;
      expect(
          routeRules,
          anyElement(equals({
            'rule_set': ['adblock'],
            'action': 'reject',
          })));
      // Сниффинг — раньше отклонения: без него у соединения нет домена.
      final sniffIdx =
          routeRules.indexWhere((r) => (r as Map)['action'] == 'sniff');
      final rejectIdx =
          routeRules.indexWhere((r) => (r as Map)['rule_set'] != null);
      expect(sniffIdx, lessThan(rejectIdx));
    });

    test('без файла списка — короткий встроенный, без rule_set', () {
      final c = _config(path: null);
      final route = c['route'] as Map<String, dynamic>;
      expect(route.containsKey('rule_set'), isFalse);
      final routeRules = route['rules'] as List;
      expect(
          routeRules.any((r) =>
              (r as Map)['action'] == 'reject' &&
              (r['domain_suffix'] as List).contains('doubleclick.net')),
          isTrue);
      final dnsRules = (c['dns'] as Map)['rules'] as List;
      expect(dnsRules.any((r) => (r as Map)['rule_set'] != null), isFalse);
      expect(dnsRules.any((r) => (r as Map)['rcode'] == 'NXDOMAIN'), isTrue);
    });

    test('тумблер выключен — никаких правил блокировки', () {
      final c = _config(blockAds: false);
      final route = c['route'] as Map<String, dynamic>;
      expect(route.containsKey('rule_set'), isFalse);
      expect(
          (route['rules'] as List)
              .any((r) => (r as Map)['action'] == 'reject'),
          isFalse);
      final dns = c['dns'] as Map;
      expect(dns['rules'], isNull);
    });

    test('конфиги для проверки настоящим ядром', () {
      // Список, собранный под приложение, — тот же файл, что уйдёт в APK.
      final dir = Directory('/tmp/vpnonline-adblock')
        ..createSync(recursive: true);
      final srs = File('assets/adblock/adblock.srs').absolute.path;
      File('${dir.path}/vpn.json').writeAsStringSync(TunnelService.instance
          .buildConfigFromUri(_link,
              blockAds: true, adBlockRuleSetPath: srs, fakeIpDns: true));
      File('${dir.path}/monitoring.json').writeAsStringSync(TunnelService
          .instance
          .buildConfigFromUri(_link,
              blockAds: true,
              adBlockRuleSetPath: srs,
              fakeIpDns: true,
              monitoringOptionsSupported: true));
      File('${dir.path}/session.json').writeAsStringSync(TunnelService
          .instance
          .buildConfigFromUri(_link,
              blockAds: true,
              adBlockRuleSetPath: srs,
              fakeIpDns: true,
              monitoringOptionsSupported: true,
              alternateUris: [
                'vless://22222222-2222-2222-2222-222222222222@127.0.0.1:24444'
                    '?type=tcp&security=none#NL',
              ]));
      File('${dir.path}/proxy.json').writeAsStringSync(TunnelService.instance
          .buildConfigFromUri(_link,
              blockAds: true, adBlockRuleSetPath: srs, proxyOnly: true));
    });
  });

  group('файл списка на диске', () {
    late Directory tmp;
    setUp(() {
      AdBlockRules.debugReset();
      tmp = Directory.systemTemp.createTempSync('adblock_test');
    });
    tearDown(() {
      AdBlockRules.debugReset();
      tmp.deleteSync(recursive: true);
    });

    Future<ByteData> Function(String) asset(List<int> bytes) =>
        (_) async => ByteData.sublistView(Uint8List.fromList(bytes));

    test('копируется из ассетов и переиспользуется', () async {
      var loads = 0;
      Future<ByteData> load(String key) async {
        loads++;
        expect(key, AdBlockRules.assetPath);
        return ByteData.sublistView(Uint8List.fromList([1, 2, 3, 4]));
      }

      final path = await AdBlockRules.ensureFile(
          directory: () async => tmp, loadAsset: load);
      expect(path, isNotNull);
      expect(File(path!).readAsBytesSync(), [1, 2, 3, 4]);
      expect(File('$path.tmp').existsSync(), isFalse);

      final again = await AdBlockRules.ensureFile(
          directory: () async => tmp, loadAsset: load);
      expect(again, path);
      expect(loads, 1, reason: 'второй раз ассет не читается');
    });

    test('новый список в обновлении заменяет старый', () async {
      final path = await AdBlockRules.ensureFile(
          directory: () async => tmp, loadAsset: asset([1, 2, 3]));
      AdBlockRules.debugReset();
      final updated = await AdBlockRules.ensureFile(
          directory: () async => tmp, loadAsset: asset([9, 9, 9, 9, 9]));
      expect(updated, path);
      expect(File(updated!).readAsBytesSync(), [9, 9, 9, 9, 9]);
    });

    test('ошибка — null, а не исключение: подключение не должно падать',
        () async {
      final path = await AdBlockRules.ensureFile(
          directory: () async => throw const FileSystemException('нет места'),
          loadAsset: asset([1]));
      expect(path, isNull);
      final empty = await AdBlockRules.ensureFile(
          directory: () async => tmp, loadAsset: asset([]));
      expect(empty, isNull);
    });

    test('настоящий список в ассетах на месте и не пустой', () {
      final f = File('assets/adblock/adblock.srs');
      expect(f.existsSync(), isTrue);
      expect(f.lengthSync(), greaterThan(100000));
    });
  });
}
