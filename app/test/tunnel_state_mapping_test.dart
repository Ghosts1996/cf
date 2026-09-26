import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

import 'support/fake_runtime.dart';

void main() {
  // Состояние сервиса приходит строкой, и сопоставляется оно поиском
  // подстрок. Android-плагин шлёт `ServiceState.stopped/started/...`,
  // Windows-ядро — `disconnected/connecting/connected`.
  final tunnel = TunnelService.withRuntime(FakeRuntime());

  group('состояние Android-плагина', () {
    test('stopped — отключено', () {
      expect(tunnel.debugMapServiceState('ServiceState.stopped'),
          TunnelConnState.disconnected);
    });
    test('starting — подключение', () {
      expect(tunnel.debugMapServiceState('ServiceState.starting'),
          TunnelConnState.connecting);
    });
    test('started — подключено', () {
      expect(tunnel.debugMapServiceState('ServiceState.started'),
          TunnelConnState.connected);
    });
    test('stopping — отключение', () {
      expect(tunnel.debugMapServiceState('ServiceState.stopping'),
          TunnelConnState.disconnecting);
    });
  });

  group('состояние Windows-ядра', () {
    // «disconnected» содержит подстроку «connected». Проверка на «connected»
    // стояла раньше проверки на отключение — и каждое отключение на Windows
    // сопоставлялось как «подключено».
    test('disconnected — отключено, а не подключено', () {
      expect(tunnel.debugMapServiceState('disconnected'),
          TunnelConnState.disconnected);
    });
    test('connecting — подключение', () {
      expect(tunnel.debugMapServiceState('connecting'),
          TunnelConnState.connecting);
    });
    test('connected — подключено', () {
      expect(tunnel.debugMapServiceState('connected'),
          TunnelConnState.connected);
    });
  });
}
