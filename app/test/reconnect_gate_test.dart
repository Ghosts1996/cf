import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

void main() {
  // Из Dart «пользователь выключил VPN» и «туннель оборвался сам» приходят
  // одинаковым «отключено»: кнопка в шторке и переключатель в системных
  // настройках гасят сервис тем же путём, что и наша кнопка. Различаем по
  // тому, смотрит ли человек на экран.
  test('выключение при открытом приложении не отменяется', () {
    expect(
      TunnelService.shouldAutoReconnectAfterDrop(appInForeground: true),
      isFalse,
    );
  });

  test('обрыв при свёрнутом приложении поднимается обратно', () {
    expect(
      TunnelService.shouldAutoReconnectAfterDrop(appInForeground: false),
      isTrue,
    );
  });
}
