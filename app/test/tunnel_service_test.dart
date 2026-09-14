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
}
