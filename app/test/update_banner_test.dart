import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/widgets/update_banner.dart';

void main() {
  Future<({List<String> taps})> pump(WidgetTester tester) async {
    final taps = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          // Узкий телефон: кнопки не должны вылезать за край.
          width: 320,
          child: UpdateBanner(
            onUpdate: () => taps.add('обновить'),
            onDismiss: () => taps.add('скрыть'),
          ),
        ),
      ),
    ));
    return (taps: taps);
  }

  testWidgets('плашка показывает текст и обе кнопки', (tester) async {
    await pump(tester);
    expect(find.text('Доступна новая версия приложения'), findsOneWidget);
    expect(find.text('Обновить'), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'переполнение на узком экране');
  });

  testWidgets('«Обновить» зовёт обновление', (tester) async {
    final r = await pump(tester);
    await tester.tap(find.text('Обновить'));
    expect(r.taps, ['обновить']);
  });

  testWidgets('«×» скрывает плашку', (tester) async {
    final r = await pump(tester);
    await tester.tap(find.byIcon(Icons.close_rounded));
    expect(r.taps, ['скрыть']);
  });
}
