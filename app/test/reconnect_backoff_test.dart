import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

void main() {
  // Туннель обязан возвращаться сам, пока пользователь не нажал «Отключить».
  // Раньше восстановление вообще не запускалось, если выключен Kill Switch —
  // а выключен он по умолчанию, — и обрыв означал «перестало работать».
  group('пауза перед восстановлением туннеля', () {
    test('первая попытка идёт почти сразу', () {
      expect(TunnelService.reconnectBackoffFor(1).inSeconds, 3);
    });

    test('пауза растёт, но не обрывается на третьей попытке', () {
      final delays = [
        for (var attempt = 1; attempt <= 8; attempt++)
          TunnelService.reconnectBackoffFor(attempt).inSeconds,
      ];
      // Монотонно не убывает — каждая следующая попытка не чаще предыдущей.
      for (var i = 1; i < delays.length; i++) {
        expect(delays[i], greaterThanOrEqualTo(delays[i - 1]));
      }
      // И не кончается: даже на восьмой попытке пауза конечна.
      expect(delays.last, greaterThan(0));
    });

    test('потолок — минута, туннель не ждёт возврата сети четверть часа', () {
      for (var attempt = 1; attempt <= 100; attempt++) {
        expect(TunnelService.reconnectBackoffFor(attempt).inSeconds,
            lessThanOrEqualTo(60));
      }
    });
  });
}
