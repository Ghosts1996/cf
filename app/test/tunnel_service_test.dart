import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

void main() {
  group('latencyForHostName', () {
    final tunnel = TunnelService.instance;

    tearDown(() => tunnel.latencyByRemark.value = const <String, int>{});

    test('находит локацию по remark с префиксом сервиса', () {
      tunnel.latencyByRemark.value = const {
        'VPNonLine | 🇩🇪 Германия — Франкфурт': 84,
        'VPNonLine | 🇳🇱 Нидерланды': 91,
      };
      expect(tunnel.latencyForHostName('🇩🇪 Германия — Франкфурт'), 84);
      expect(tunnel.latencyForHostName('🇳🇱 Нидерланды'), 91);
    });

    test('пустое или неизвестное имя даёт null', () {
      tunnel.latencyByRemark.value = const {'VPNonLine | 🇩🇪 Германия': 84};
      expect(tunnel.latencyForHostName(null), isNull);
      expect(tunnel.latencyForHostName(''), isNull);
      expect(tunnel.latencyForHostName('🇺🇸 США'), isNull);
    });
  });

  group('listSubscriptionLocations', () {
    final tunnel = TunnelService.instance;

    // Подписка с внешними нодами: две vless-локации, одна hysteria2 и одна
    // shadowsocks. Ровно такой список приходит с тех пор, как бот стал
    // дописывать в подписку клиента ноды из чужих подписок.
    const mixedSubscription =
        'dmxlc3M6Ly8xMTExMTExMS0xMTExLTExMTEtMTExMS0xMTExMTExMTExMTFAZGUuZXhhbXBsZS5jb206NDQzP3R5cGU9dGNwJnNlY3VyaXR5PXJlYWxpdHkmcGJrPVBVQktFWSZzaWQ9YWEmc25pPXlhaG9vLmNvbSZmcD1jaHJvbWUmZmxvdz14dGxzLXJwcngtdmlzaW9uI1ZQTm9uTGluZSUyMCU3QyUyMEdlcm1hbnkKdmxlc3M6Ly8yMjIyMjIyMi0yMjIyLTIyMjItMjIyMi0yMjIyMjIyMjIyMjJAdWsuZXhhbXBsZS5jb206NDQzP3R5cGU9dGNwJnNlY3VyaXR5PXJlYWxpdHkmcGJrPVBVQktFWSZzaWQ9YmImc25pPXlhaG9vLmNvbSNVbml0ZWQlMjBLaW5nZG9tCmh5c3RlcmlhMjovL3Bhc3NAZWUuZXhhbXBsZS5jb206NDQzP3NuaT1leGFtcGxlLmNvbSNFc3RvbmlhJTIwR2FtaW5nCnNzOi8vWVdWekxUSTFOaTFuWTIwNmNHRnpjd0BsdC5leGFtcGxlLmNvbTo4Mzg4I0xpdGh1YW5pYQ==';

    test('отдаёт всю подписку, включая протоколы, которые мы не умеем',
        () async {
      final locations =
          await tunnel.listSubscriptionLocations(mixedSubscription);
      expect(locations.map((l) => l.remark), [
        'VPNonLine | Germany',
        'United Kingdom',
        'Estonia Gaming',
        'Lithuania',
      ]);
    });

    test('vless-локации отдаются с адресом и помечены поддерживаемыми',
        () async {
      final locations =
          await tunnel.listSubscriptionLocations(mixedSubscription);
      final uk = locations.firstWhere((l) => l.remark == 'United Kingdom');
      expect(uk.supported, isTrue);
      expect(uk.protocol, 'vless');
      expect(uk.host, 'uk.example.com');
      expect(uk.port, 443);
      expect(uk.security, 'reality');
    });

    test('hysteria2 и shadowsocks тоже разбираются', () async {
      final locations =
          await tunnel.listSubscriptionLocations(mixedSubscription);
      final estonia = locations.firstWhere((l) => l.remark == 'Estonia Gaming');
      expect(estonia.supported, isTrue);
      expect(estonia.protocol, 'hysteria2');
      expect(estonia.host, 'ee.example.com');
      expect(estonia.port, 443);

      final lithuania = locations.firstWhere((l) => l.remark == 'Lithuania');
      expect(lithuania.supported, isTrue);
      expect(lithuania.protocol, 'shadowsocks');
      expect(lithuania.host, 'lt.example.com');
      expect(lithuania.port, 8388);
    });

    test('trojan разбирается вместе с транспортом', () async {
      const link = 'trojan://secret@tr.example.com:443'
          '?security=tls&sni=example.com&type=ws&path=%2Fws#Trojan';
      final locations = await tunnel.listSubscriptionLocations(link);
      expect(locations, hasLength(1));
      expect(locations.first.protocol, 'trojan');
      expect(locations.first.remark, 'Trojan');
      expect(locations.first.host, 'tr.example.com');
      expect(locations.first.transport, 'ws');
      expect(locations.first.security, 'tls');
    });

    test('base64-подписка без единого vless всё равно раскрывается', () async {
      // Гейт раскрытия base64 раньше смотрел только на vless://, и подписка,
      // где vless-узлов нет вовсе, оставалась нераспознанной строкой: экран
      // показывал пустой список там, где другие клиенты показывали узлы.
      const onlyOthers =
          'dHJvamFuOi8vc2VjcmV0QHRyLmV4YW1wbGUuY29tOjQ0Mz9zZWN1cml0eT10bHMmc25pPWV4YW1wbGUuY29tJnR5cGU9d3MmcGF0aD0lMkZ3cyNUcm9qYW4gT25seQpoeXN0ZXJpYTI6Ly9wYXNzQGVlLmV4YW1wbGUuY29tOjQ0Mz9zbmk9ZXhhbXBsZS5jb20jRXN0b25pYQpzczovL1lXVnpMVEkxTmkxblkyMDZjR0Z6Y3dAbHQuZXhhbXBsZS5jb206ODM4OCNMaXRodWFuaWE=';
      final locations = await tunnel.listSubscriptionLocations(onlyOthers);
      expect(locations.map((l) => l.remark),
          ['Trojan Only', 'Estonia', 'Lithuania']);
      expect(locations.map((l) => l.protocol),
          ['trojan', 'hysteria2', 'shadowsocks']);
      expect(locations.every((l) => l.supported), isTrue);
    });

    test('JSON-конфиг sing-box отдаёт не только vless-outbound\'ы', () async {
      const json = '''
{"outbounds":[
  {"type":"vless","tag":"JSON VLESS","server":"de.example.com","server_port":443,
   "uuid":"11111111-1111-1111-1111-111111111111",
   "tls":{"enabled":true,"server_name":"example.com"}},
  {"type":"trojan","tag":"JSON Trojan","server":"tr.example.com","server_port":443,
   "password":"secret","tls":{"enabled":true,"server_name":"example.com"},
   "transport":{"type":"ws","path":"/ws"}},
  {"type":"shadowsocks","tag":"JSON SS","server":"lt.example.com","server_port":8388,
   "method":"aes-256-gcm","password":"pass"},
  {"type":"hysteria2","tag":"JSON HY2","server":"ee.example.com","server_port":443,
   "password":"pass","tls":{"enabled":true,"server_name":"example.com"}},
  {"type":"direct","tag":"direct"}
]}
''';
      final locations = await tunnel.listSubscriptionLocations(json);
      expect(locations.map((l) => l.remark),
          ['JSON VLESS', 'JSON Trojan', 'JSON SS', 'JSON HY2']);
      expect(locations.map((l) => l.protocol),
          ['vless', 'trojan', 'shadowsocks', 'hysteria2']);
      final trojan = locations.firstWhere((l) => l.protocol == 'trojan');
      expect(trojan.transport, 'ws');
      expect(trojan.host, 'tr.example.com');
    });

    test('vmess разбирается из base64-JSON', () async {
      const link =
          'vmess://eyJ2IjoiMiIsInBzIjoiVm1lc3MgTm9kZSIsImFkZCI6InZtLmV4YW1wbGUuY29tIiwicG9ydCI6IjQ0MyIsImlkIjoiMzMzMzMzMzMtMzMzMy0zMzMzLTMzMzMtMzMzMzMzMzMzMzMzIiwiYWlkIjoiMCIsInNjeSI6ImF1dG8iLCJuZXQiOiJ3cyIsImhvc3QiOiJ2bS5leGFtcGxlLmNvbSIsInBhdGgiOiIvdm0iLCJ0bHMiOiJ0bHMifQ==';
      final locations = await tunnel.listSubscriptionLocations(link);
      expect(locations, hasLength(1));
      expect(locations.first.protocol, 'vmess');
      expect(locations.first.remark, 'Vmess Node');
      expect(locations.first.host, 'vm.example.com');
      expect(locations.first.port, 443);
      expect(locations.first.transport, 'ws');
    });
  });
}
