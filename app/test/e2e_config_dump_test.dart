// Клиентские конфиги для сквозной проверки против настоящего сервера на
// 127.0.0.1. Собираются тем же кодом, что и на телефоне.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

void main() {
  test('конфиги для сквозной проверки', () {
    final dir = Directory('/tmp/vpnonline-e2e')..createSync(recursive: true);
    final cases = <String, String>{
      'vless': 'vless://11111111-2222-3333-4444-555555555555@127.0.0.1:24443'
          '?type=tcp&security=none#VLESS',
      'ss': 'ss://YWVzLTI1Ni1nY206dGVzdHBhc3M@127.0.0.1:24444#SS',
      'trojan': 'trojan://trpass@127.0.0.1:24445'
          '?security=tls&sni=example.com&allowInsecure=1#TROJAN',
      // {"v":"2","ps":"VMESS","add":"127.0.0.1","port":"24446",
      //  "id":"11111111-2222-3333-4444-555555555555","aid":"0","net":"tcp"}
      'vmess': 'vmess://eyJ2IjoiMiIsInBzIjoiVk1FU1MiLCJhZGQiOiIxMjcuMC4wLjEiLCJwb3J0IjoiMjQ0NDYiLCJpZCI6IjExMTExMTExLTIyMjItMzMzMy00NDQ0LTU1NTU1NTU1NTU1NSIsImFpZCI6IjAiLCJuZXQiOiJ0Y3AifQ==',
      'hysteria2': 'hysteria2://hypass@127.0.0.1:24447'
          '?sni=example.com&insecure=1#HY2',
    };
    cases.forEach((name, link) {
      File('${dir.path}/$name.json').writeAsStringSync(
          TunnelService.instance.buildConfigFromUri(link, proxyOnly: true));
    });
  });
}
