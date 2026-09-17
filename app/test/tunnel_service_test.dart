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

    test('чужие протоколы видны, но помечены неподдерживаемыми', () async {
      final locations =
          await tunnel.listSubscriptionLocations(mixedSubscription);
      final estonia = locations.firstWhere((l) => l.remark == 'Estonia Gaming');
      expect(estonia.supported, isFalse);
      expect(estonia.protocol, 'hysteria2');
      // Адреса у такой локации нет: подключаться к ней нечем, и притворяться,
      // что есть, нельзя.
      expect(estonia.host, isNull);

      final lithuania = locations.firstWhere((l) => l.remark == 'Lithuania');
      expect(lithuania.supported, isFalse);
      expect(lithuania.protocol, 'ss');
    });
  });
}
