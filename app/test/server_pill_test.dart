import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/widgets/neon.dart';

void main() {
  // Подпись под именем локации читают глазами, сверяя список с другими
  // клиентами. Формат должен оставаться ровно таким: «VLESS / TCP / REALITY».
  Future<void> pump(WidgetTester tester, String? tech) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ServerPill(
          code: 'DE',
          name: '🇩🇪 Германия',
          pingLabel: '106 мс · проверено',
          techLabel: tech,
        ),
      ),
    ));
  }

  testWidgets('техническая строка показывается отдельной строкой',
      (tester) async {
    await pump(tester, 'VLESS / TCP / REALITY');
    expect(find.text('106 мс · проверено'), findsOneWidget);
    expect(find.text('VLESS / TCP / REALITY'), findsOneWidget);
  });

  testWidgets('без техстроки карточка рисуется как раньше', (tester) async {
    await pump(tester, null);
    expect(find.text('106 мс · проверено'), findsOneWidget);
    expect(find.textContaining('/'), findsNothing);
  });

  testWidgets('длинные подписи обрезаются, а не ломают вёрстку',
      (tester) async {
    await pump(tester,
        'HYSTERIA2 / REALITY очень длинная строка которая точно не влезает');
    expect(tester.takeException(), isNull);
  });
}
