import 'dart:convert';
import 'dart:io';
import 'package:vpnonline_app/services/tunnel_service.dart';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Каждый протокол подписки собирается в свой тип outbound'а. Конфиги
  // выгружаются в /tmp/vpnonline-protocols, чтобы их можно было прогнать
  // настоящим ядром: разбора схемы мало, часть ограничений ядро проверяет
  // только при запуске.
  test('каждый протокол собирается в свой outbound', () {
  final t = TunnelService.instance;
  final cases = <String, String>{
    'vless_reality': 'vless://11111111-1111-1111-1111-111111111111@a.example.com:443'
        '?type=tcp&security=reality&pbk=e8Q_05VmcuO12_QIua9nojVHZViU73hqOOZShYo52-c&sid=aa&sni=yahoo.com&fp=chrome&flow=xtls-rprx-vision#VLESS',
    'vless_xhttp': 'vless://11111111-1111-1111-1111-111111111111@a.example.com:443'
        '?type=xhttp&mode=auto&security=tls&sni=example.com&path=%2Fx#XHTTP',
    'trojan_ws': 'trojan://secret@tr.example.com:443?security=tls&sni=example.com&type=ws&path=%2Fws#TROJAN',
    'trojan_tcp': 'trojan://secret@tr.example.com:443?security=tls&sni=example.com#TROJAN2',
    'vmess_ws': 'vmess://eyJ2IjoiMiIsInBzIjoiVm1lc3MiLCJhZGQiOiJ2bS5leGFtcGxlLmNvbSIsInBvcnQiOiI0NDMiLCJpZCI6IjMzMzMzMzMzLTMzMzMtMzMzMy0zMzMzLTMzMzMzMzMzMzMzMyIsImFpZCI6IjAiLCJzY3kiOiJhdXRvIiwibmV0Ijoid3MiLCJob3N0Ijoidm0uZXhhbXBsZS5jb20iLCJwYXRoIjoiL3ZtIiwidGxzIjoidGxzIn0=',
    'ss': 'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@ss.example.com:8388#SS',
    'hysteria2': 'hysteria2://pass@hy.example.com:443?sni=example.com&insecure=1&obfs=salamander&obfs-password=zzz#HY2',
  };
  final dir = Directory('/tmp/vpnonline-protocols')..createSync(recursive: true);
  cases.forEach((name, link) {
    try {
      final cfg = t.buildConfigFromUri(link, proxyOnly: true);
      File('${dir.path}/$name.json').writeAsStringSync(cfg);
      final out = (jsonDecode(cfg) as Map<String, dynamic>)['outbounds'] as List;
      final proxy = out.first as Map<String, dynamic>;
      stdout.writeln('$name -> type=${proxy['type']} '
          'transport=${(proxy['transport'] as Map?)?['type'] ?? '-'}');
    } catch (e) {
      fail('$name не собрался: $e');
    }
  });

  Map<String, dynamic> proxyOf(String name) {
    final cfg = jsonDecode(File('${dir.path}/$name.json').readAsStringSync())
        as Map<String, dynamic>;
    return (cfg['outbounds'] as List).first as Map<String, dynamic>;
  }

  expect(proxyOf('vless_reality')['type'], 'vless');
  expect(proxyOf('vless_xhttp')['transport']['type'], 'xhttp');
  expect(proxyOf('trojan_ws')['type'], 'trojan');
  expect(proxyOf('trojan_ws')['password'], 'secret');
  expect(proxyOf('trojan_ws')['transport']['type'], 'ws');
  expect(proxyOf('vmess_ws')['type'], 'vmess');
  expect(proxyOf('vmess_ws')['security'], 'auto');
  expect(proxyOf('ss')['type'], 'shadowsocks');
  expect(proxyOf('ss')['method'], 'aes-256-gcm');
  expect(proxyOf('ss')['password'], 'password');
  expect(proxyOf('hysteria2')['type'], 'hysteria2');
  expect(proxyOf('hysteria2')['obfs']['type'], 'salamander');
  expect(proxyOf('hysteria2')['tls']['insecure'], true);
  });
}
