import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

void main() {
  group('scaleDisplayPingMs', () {
    test('нулевые и отрицательные значения не масштабируются', () {
      expect(scaleDisplayPingMs(0), 0);
      expect(scaleDisplayPingMs(-5), -5);
    });

    test('маленькое значение не опускается ниже нижней границы', () {
      expect(scaleDisplayPingMs(1), greaterThanOrEqualTo(3));
    });

    test('значение уменьшается монотонно', () {
      expect(scaleDisplayPingMs(500), lessThan(500));
      expect(scaleDisplayPingMs(1000),
          greaterThanOrEqualTo(scaleDisplayPingMs(500)));
    });
  });

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
