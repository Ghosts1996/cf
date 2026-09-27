import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/update_installer.dart';
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

  Future<List<String>> pumpState(WidgetTester tester, UpdateProgress p) async {
    final taps = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: UpdateBanner(
            progress: p,
            onUpdate: () => taps.add('обновить'),
            onDismiss: () => taps.add('скрыть'),
            onCancel: () => taps.add('отмена'),
            onInstall: () => taps.add('установить'),
            onOpenInBrowser: () => taps.add('браузер'),
          ),
        ),
      ),
    ));
    return taps;
  }

  testWidgets('загрузка: проценты, мегабайты, шкала и «Отмена»', (tester) async {
    final taps = await pumpState(
        tester,
        const UpdateProgress(
            phase: UpdatePhase.downloading,
            receivedBytes: 37 * 1024 * 1024,
            totalBytes: 100 * 1024 * 1024));
    expect(find.textContaining('37%'), findsOneWidget);
    expect(find.textContaining('37.0 МБ из 100.0 МБ'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, closeTo(0.37, 0.001));
    await tester.tap(find.text('Отмена'));
    expect(taps, ['отмена']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('размер неизвестен — шкала бегущая, без процентов', (tester) async {
    await pumpState(tester,
        const UpdateProgress(phase: UpdatePhase.downloading, receivedBytes: 5000));
    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, isNull);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('загружено — «Установить»', (tester) async {
    final taps = await pumpState(
        tester, const UpdateProgress(phase: UpdatePhase.ready));
    await tester.tap(find.text('Установить'));
    expect(taps, ['установить']);
  });

  testWidgets('нужно разрешение — подсказка и «Установить», без переполнения',
      (tester) async {
    await pumpState(
        tester, const UpdateProgress(phase: UpdatePhase.needsPermission));
    expect(find.textContaining('Разрешите установку'), findsOneWidget);
    expect(find.text('Установить'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ошибка — текст, «Повторить» и запасной путь через браузер',
      (tester) async {
    final taps = await pumpState(
        tester,
        const UpdateProgress(
            phase: UpdatePhase.failed,
            error: 'Загрузка остановилась — проверьте интернет и повторите.'));
    expect(find.textContaining('остановилась'), findsOneWidget);
    await tester.tap(find.text('Повторить'));
    await tester.tap(find.text('Скачать через браузер'));
    expect(taps, ['обновить', 'браузер']);
    expect(tester.takeException(), isNull);
  });
}
