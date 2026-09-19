import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/theme.dart';
import 'package:vpnonline_app/widgets/neon.dart';

void main() {
  // Карточку сервера видит платящий клиент. Красная надпись «не работает» под
  // каждой страной отпугивала людей сильнее, чем помогала, — на экране не
  // должно оставаться ни одной подписи цветом тревоги.
  Color colorOf(WidgetTester tester, String text) =>
      (tester.widget<Text>(find.text(text))).style!.color!;

  Future<void> pump(WidgetTester tester, String label, Color color) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ServerPill(
          code: 'NL',
          name: '🇳🇱 Нидерланды',
          pingLabel: label,
          pingColor: color,
          techLabel: 'VLESS / TCP / REALITY',
        ),
      ),
    ));
  }

  testWidgets('отказ подписан приглушённо, а не тревожным цветом',
      (tester) async {
    await pump(tester, 'нет ответа', AppColors.textDim);
    expect(colorOf(tester, 'нет ответа'), AppColors.textDim);
    expect(colorOf(tester, 'нет ответа'), isNot(AppColors.danger));
  });

  testWidgets('живое число остаётся зелёным', (tester) async {
    await pump(tester, '101 мс · подключено', AppColors.success);
    expect(colorOf(tester, '101 мс · подключено'), AppColors.success);
  });

  testWidgets('медленный сервер — предупреждение, а не отказ', (tester) async {
    await pump(tester, '380 мс · медленно', AppColors.warning);
    expect(colorOf(tester, '380 мс · медленно'), AppColors.warning);
  });
}
