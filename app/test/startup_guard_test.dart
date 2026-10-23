// Запуск не должен застревать до первого кадра: битый файл настроек на
// Windows откладывается в сторону, упавший или зависший шаг пропускается.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/startup_guard.dart';

void main() {
  late Directory dir;
  late File prefs;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vpnonline-prefs');
    prefs = File('${dir.path}${Platform.pathSeparator}shared_preferences.json');
    repairedPrefsBackupPath = null;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> repair() => repairCorruptWindowsPrefs(
      supportDirectory: () async => dir, isWindows: true);

  test('обрезанный при записи файл откладывается, приложение стартует с '
      'чистыми настройками', () async {
    prefs.writeAsStringSync('{"flutter.logs.entries":"[{\\"t\\":17');
    await repair();
    expect(prefs.existsSync(), isFalse);
    expect(File('${prefs.path}.broken').existsSync(), isTrue);
    expect(repairedPrefsBackupPath, '${prefs.path}.broken');
  });

  test('целый и пустой файлы не трогаются', () async {
    prefs.writeAsStringSync('{"flutter.lang":"ru"}');
    await repair();
    expect(prefs.readAsStringSync(), '{"flutter.lang":"ru"}');
    prefs.writeAsStringSync('');
    await repair();
    expect(prefs.existsSync(), isTrue);
    expect(repairedPrefsBackupPath, isNull);
  });

  test('не Windows — ничего не делает', () async {
    prefs.writeAsStringSync('{broken');
    await repairCorruptWindowsPrefs(
        supportDirectory: () async => dir, isWindows: false);
    expect(prefs.readAsStringSync(), '{broken');
  });

  test('упавший или зависший шаг запуска не держит запуск', () async {
    final problems = <String>[];
    await guardedStartupStep('падает', () async => throw StateError('нет'),
        onProblem: problems.add);
    final hang = Completer<void>();
    await guardedStartupStep('висит', () => hang.future,
        timeout: const Duration(milliseconds: 50), onProblem: problems.add);
    expect(problems, hasLength(2));
    expect(problems.last, contains('висит'));
  });
}
