// Журнал приложения: держится в памяти, на диск уходит пачкой, размер
// ограничен. Раньше каждая строка перечитывала и переписывала весь журнал в
// главном потоке — подключение пишет десяток строк подряд, и экран замирал.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpnonline_app/services/app_log_service.dart';
import 'package:vpnonline_app/services/local_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final log = AppLogService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await log.clearAll();
  });

  test('десяток строк подряд — одна запись в хранилище', () async {
    final before = log.debugWriteCount;
    for (var i = 0; i < 12; i++) {
      unawaited(log.log('строка $i'));
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(log.debugWriteCount - before, 1);
    final all = await log.getAll();
    expect(all.first.message, 'строка 11', reason: 'новые сверху');
    expect(all.length, 12);
  });

  test('журнал переживает перезапуск приложения', () async {
    await log.log('до перезапуска');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await log.debugDropCache();
    final all = await log.getAll();
    expect(all.map((e) => e.message), contains('до перезапуска'));
  });

  test('огромные записи не раздувают хранилище', () async {
    final big = 'x' * 25000;
    for (var i = 0; i < 60; i++) {
      unawaited(log.log('$i:$big'));
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final all = await log.getAll();
    final total = all.fold<int>(0, (sum, e) => sum + e.message.length);
    expect(total, lessThanOrEqualTo(600000));
    expect(all.first.message, startsWith('59:'), reason: 'уходят старые');
    final raw = await LocalPrefs.instance.getString('logs.entries');
    expect(raw!.length, lessThan(700000));
    expect((jsonDecode(raw) as List).length, all.length);
  });

  test('слишком длинная строка обрезается, а не теряется', () async {
    await log.log('y' * 100000);
    final all = await log.getAll();
    expect(all.first.message.length, lessThan(31000));
    expect(all.first.message, endsWith('…'));
  });
}
