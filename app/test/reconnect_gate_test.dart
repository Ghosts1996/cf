import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

void main() {
  // Из Dart «пользователь выключил VPN» и «туннель оборвался сам» приходят
  // одинаковым «отключено»: кнопка в шторке и переключатель в системных
  // настройках гасят сервис тем же путём, что и наша кнопка. Обратно
  // поднимаем только упавшее у нас — когда приложение свёрнуто, а ядро перед
  // этим сообщило об аварии.
  test('выключение при открытом приложении не отменяется', () {
    expect(
      TunnelService.shouldAutoReconnectAfterDrop(
          appInForeground: true, coreCrashed: true),
      isFalse,
    );
  });

  test('выключение из шторки при свёрнутом приложении не отменяется', () {
    expect(
      TunnelService.shouldAutoReconnectAfterDrop(
          appInForeground: false, coreCrashed: false),
      isFalse,
    );
  });

  test('авария ядра при свёрнутом приложении поднимается обратно', () {
    expect(
      TunnelService.shouldAutoReconnectAfterDrop(
          appInForeground: false, coreCrashed: true),
      isTrue,
    );
  });

  test('аварией считаются только сообщения о падении ядра', () {
    expect(TunnelService.isCoreCrashFault('Core failed: decode config'), isTrue);
    expect(TunnelService.isCoreCrashFault('Start failed: listen tcp'), isTrue);
    expect(
        TunnelService.isCoreCrashFault('sing-box неожиданно завершился (код 1)'),
        isTrue);
    expect(TunnelService.isCoreCrashFault('VPN permission required'), isFalse);
    expect(
        TunnelService.isCoreCrashFault(
            'Скачиваю sing-box.exe (один раз, при первом подключении)…'),
        isFalse);
    expect(TunnelService.isCoreCrashFault(null), isFalse);
  });
}
