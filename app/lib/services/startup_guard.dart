// Защита запуска: всё, что выполняется до первого кадра, не должно ни
// падать, ни висеть — иначе окно остаётся пустым, на Windows чёрным.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Что сделала [repairCorruptWindowsPrefs]: null — ничего, иначе путь, куда
/// отложен повреждённый файл. Пишется в журнал, когда тот уже доступен.
String? repairedPrefsBackupPath;

/// На Windows все настройки приложения (и журнал) лежат одним JSON-файлом
/// shared_preferences_windows, а модуль переписывает его целиком без защиты
/// от обрыва. Закрыли приложение посреди записи — установщик обновления,
/// выключение компьютера, «Снять задачу» — и файл остаётся обрезанным. При
/// следующем запуске модуль не может его разобрать, чтение настроек падает
/// ещё до первого кадра, и окно навсегда остаётся чёрным.
///
/// Здесь такой файл откладывается в сторону (`.broken`), и приложение
/// стартует с чистыми настройками. Вход в аккаунт хранится отдельно, в
/// диспетчере учётных данных Windows, и не теряется.
Future<void> repairCorruptWindowsPrefs({
  Future<Directory> Function()? supportDirectory,
  bool? isWindows,
}) async {
  if (!(isWindows ?? (!kIsWeb && Platform.isWindows))) return;
  try {
    final dir = await (supportDirectory ?? getApplicationSupportDirectory)();
    final file = File('${dir.path}${Platform.pathSeparator}'
        'shared_preferences.json');
    if (!file.existsSync()) return;
    final text = file.readAsStringSync();
    if (text.trim().isEmpty) return; // пустой файл модуль читает сам
    try {
      if (jsonDecode(text) is Map) return; // файл цел
    } on FormatException {
      // повреждён — откладываем ниже
    }
    final backup = File('${file.path}.broken');
    if (backup.existsSync()) backup.deleteSync();
    file.renameSync(backup.path);
    repairedPrefsBackupPath = backup.path;
  } catch (_) {
    // Нет доступа к папке — оставляем как есть: дальше main() всё равно
    // запустит интерфейс, даже если настройки не прочитаются.
  }
}

/// Выполняет шаг запуска, но не даёт ему ни уронить запуск, ни задержать
/// первый кадр дольше [timeout].
Future<void> guardedStartupStep(
  String name,
  Future<void> Function() step, {
  Duration timeout = const Duration(seconds: 5),
  void Function(String message)? onProblem,
}) async {
  try {
    await step().timeout(timeout);
  } on TimeoutException {
    onProblem?.call('Запуск: «$name» не ответил за ${timeout.inSeconds} с — '
        'продолжаю без него');
  } catch (e) {
    onProblem?.call('Запуск: «$name» не удался: $e');
  }
}
