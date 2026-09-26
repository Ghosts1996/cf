// Выгружает конфиги, которые приложение реально отдаёт ядру при подключении,
// в /tmp/vpnonline-session. Дальше их гоняет настоящее ядро sing-box —
// не проверкой схемы, а запуском.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpnonline_app/services/local_prefs.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

import 'support/fake_runtime.dart';

String _link(int i, {String type = 'tcp', String extra = ''}) =>
    'vless://${'$i'.padLeft(8, '0')}-1111-1111-1111-111111111111@'
    'node$i.example.com:443?type=$type&security=reality'
    '&pbk=e8Q_05VmcuO12_QIua9nojVHZViU73hqOOZShYo52-c&sid=aa&sni=yahoo.com'
    '&fp=chrome$extra#Локация%20$i';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = Directory('/tmp/vpnonline-session')..createSync(recursive: true);

  // Подписка на тридцать локаций со смесью транспортов — как у пользователя.
  final big = [
    for (var i = 1; i <= 26; i++) _link(i),
    _link(27, type: 'grpc', extra: '&serviceName=gun'),
    _link(28, type: 'grpc', extra: '&serviceName=gun'),
    _link(29, type: 'xhttp', extra: '&mode=auto&path=%2Fx'),
    _link(30, type: 'ws', extra: '&path=%2Fw&host=example.com'),
  ].join('\n');

  // Все переключатели, которые влияют на конфиг. Перед каждым выгрузом
  // сбрасываем их явно: LocalPrefs держит значения в памяти, и сброс
  // хранилища между тестами до него не доходит — без этого все конфиги
  // выходили одинаковыми и тесты молча проверяли одно и то же.
  const toggles = <String>[
    PrefKeys.dpiBypass,
    PrefKeys.fastPing,
    PrefKeys.dnsProtection,
    PrefKeys.proxyOnlyMode,
  ];

  Future<Map<String, dynamic>> dump(
      String name, Map<String, bool> prefs) async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    for (final key in toggles) {
      await LocalPrefs.instance.setBool(key, prefs[key] ?? false);
    }
    final core = FakeRuntime();
    final tunnel = TunnelService.withRuntime(core);
    // Рабочий туннель: прокси на порту сервиса отвечает на любой запрос. В
    // прокси-режиме группы-селектора нет и проверка связи идёт до возврата —
    // без «интернета» подключение честно откажет и конфига не будет.
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 2080,
        shared: true);
    proxy.listen((req) {
      req.response.statusCode = 204;
      req.response.close();
    });
    try {
      await tunnel.connect(big);
      await tunnel.disconnect();
    } finally {
      await proxy.close(force: true);
    }
    final cfg = core.lastConfig!;
    File('${dir.path}/$name.json').writeAsStringSync(cfg);
    return jsonDecode(cfg) as Map<String, dynamic>;
  }

  test('VPN-режим по умолчанию', () async {
    final cfg = await dump('vpn_default', {});
    final outbounds = cfg['outbounds'] as List;
    final proxies = outbounds
        .where((o) => '${(o as Map)['tag']}'.startsWith('out-'))
        .toList();
    // Выбранная плюс одиннадцать соседей, а не все тридцать: на тридцати
    // ядро не укладывалось в окно подъёма.
    expect(proxies.length, 12);
    expect(outbounds.any((o) => (o as Map)['type'] == 'selector'), isTrue);
    expect(outbounds.any((o) => (o as Map)['type'] == 'urltest'), isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('обход DPI включён', () async {
    await dump('vpn_dpi', {PrefKeys.dpiBypass: true});
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('быстрый пинг включён', () async {
    await dump('vpn_fastping', {PrefKeys.fastPing: true});
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('защита от утечек DNS включена', () async {
    await dump('vpn_dnsprotect', {PrefKeys.dnsProtection: true});
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('режим прокси без VPN', () async {
    final cfg =
        await dump('proxy_only', {PrefKeys.proxyOnlyMode: true});
    final inbounds = cfg['inbounds'] as List;
    expect(inbounds.any((i) => (i as Map)['type'] == 'tun'), isFalse,
        reason: 'в режиме прокси системный туннель не поднимается');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
