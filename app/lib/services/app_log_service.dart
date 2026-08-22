import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'local_prefs.dart';

/// Уровень записи локального лога приложения.
enum AppLogLevel { info, warning, error }

/// Одна запись локального лога — используется на экране "Безопасность" в
/// разделе "Хранение логов".
@immutable
class AppLogEntry {
  const AppLogEntry({
    required this.timestamp,
    required this.message,
    required this.level,
  });

  final DateTime timestamp;
  final String message;
  final AppLogLevel level;

  Map<String, dynamic> toJson() => {
        't': timestamp.millisecondsSinceEpoch,
        'm': message,
        'l': level.name,
      };

  static AppLogEntry? tryFromJson(dynamic raw) {
    if (raw is! Map) return null;
    final t = raw['t'];
    final m = raw['m'];
    if (t is! int || m is! String) return null;
    final levelName = raw['l'];
    final level = AppLogLevel.values.firstWhere(
      (e) => e.name == levelName,
      orElse: () => AppLogLevel.info,
    );
    return AppLogEntry(
      timestamp: DateTime.fromMillisecondsSinceEpoch(t),
      message: m,
      level: level,
    );
  }
}

/// [НОВОЕ] Локальное хранилище диагностических логов приложения
/// (подключение/отключение туннеля, ошибки) — раздел "Безопасность" ->
/// "Хранение логов" в макете. Это НЕ логи VPN-провайдера о трафике
/// пользователя (см. SupportScreen — политика провайдера остаётся
/// No-logs), а исключительно технический журнал событий на самом
/// устройстве: помогает разобраться в проблеме подключения и который
/// пользователь может ограничить по сроку хранения или стереть вручную
/// в любой момент.
///
/// Хранится через уже существующий LocalPrefs (shared_preferences) —
/// как JSON-массив под одним ключом, тем же способом, каким уже хранится
/// map "приложение -> обход VPN" в split-tunnel (см. LocalPrefs.getBoolMap).
/// Новых зависимостей пакет не требует.
///
/// [ЧЕСТНО] Автоудаление по сроку хранения запускается при каждой новой
/// записи и при каждом обращении к логам (в частности — при открытии
/// экрана "Безопасность"), а не по таймеру в фоне: ни Android
/// WorkManager, ни iOS BGTaskScheduler здесь не подключены. Если
/// приложение долго не открывать, устаревшие записи сотрутся при первом
/// же следующем запуске, а не в момент истечения срока. Дополнительно
/// список в любом случае ограничен потолком [_maxEntries] записей — лог
/// не растёт бесконечно, даже если про срок хранения забыть.
class AppLogService {
  AppLogService._();
  static final AppLogService instance = AppLogService._();

  static const _storageKey = 'logs.entries';
  static const _lastCleanupKey = 'logs.last_cleanup_millis';
  static const _maxEntries = 500;

  /// Срок хранения по умолчанию, пока пользователь не выбрал свой на
  /// экране "Безопасность".
  static const defaultRetentionDays = 7;

  /// Доступные пользователю варианты срока хранения — 1/7/30 дней, как
  /// на макете.
  static const availableRetentionDays = [1, 7, 30];

  /// Текущее число сохранённых записей — для живого отображения на экране
  /// "Безопасность" без лишних перечитываний хранилища.
  final ValueNotifier<int> entryCount = ValueNotifier(0);

  Future<int> getRetentionDays() => LocalPrefs.instance
      .getInt(PrefKeys.logRetentionDays, fallback: defaultRetentionDays);

  Future<void> setRetentionDays(int days) async {
    await LocalPrefs.instance.setInt(PrefKeys.logRetentionDays, days);
    // Смена срока хранения сразу применяется к уже накопленным записям —
    // иначе выбор "1 день" не удалил бы записи, сделанные ещё при "30 дней",
    // до следующего события.
    await applyRetention();
  }

  /// Добавляет запись в журнал. Безопасна для вызова откуда угодно —
  /// ошибки чтения/записи хранилища не пробрасываются наружу, чтобы сбой
  /// логирования никогда не мешал основной функциональности приложения.
  Future<void> log(String message, {AppLogLevel level = AppLogLevel.info}) async {
    try {
      final entries = await _readAll();
      entries.add(AppLogEntry(timestamp: DateTime.now(), message: message, level: level));
      final trimmed = entries.length > _maxEntries
          ? entries.sublist(entries.length - _maxEntries)
          : entries;
      await _writeAll(trimmed);
      await applyRetention();
    } catch (_) {
      // Лог — вспомогательная функция, не критичная для работы VPN.
    }
  }

  /// Все записи, новые сверху, уже с применённым сроком хранения.
  Future<List<AppLogEntry>> getAll() async {
    await applyRetention();
    final entries = await _readAll();
    return entries.reversed.toList();
  }

  /// Ручное удаление — кнопка "Удалить все логи" на экране "Безопасность".
  Future<void> clearAll() async {
    await LocalPrefs.instance.setString(_storageKey, '[]');
    entryCount.value = 0;
    await LocalPrefs.instance.setInt(
      _lastCleanupKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Стирает записи старше выбранного срока хранения. Безопасна для
  /// повторного вызова — если удалять нечего, просто ничего не делает.
  Future<void> applyRetention() async {
    final days = await getRetentionDays();
    final entries = await _readAll();
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final kept = entries.where((e) => e.timestamp.isAfter(cutoff)).toList();
    if (kept.length != entries.length) {
      await _writeAll(kept);
    }
    await LocalPrefs.instance.setInt(
      _lastCleanupKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<DateTime?> getLastCleanupTime() async {
    final millis = await LocalPrefs.instance.getInt(_lastCleanupKey, fallback: 0);
    if (millis == 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<List<AppLogEntry>> _readAll() async {
    final raw = await LocalPrefs.instance.getString(_storageKey);
    if (raw == null || raw.isEmpty) {
      entryCount.value = 0;
      return [];
    }
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final entries = decoded.map(AppLogEntry.tryFromJson).whereType<AppLogEntry>().toList();
      entryCount.value = entries.length;
      return entries;
    } catch (_) {
      // Повреждённые данные не должны ронять экран "Безопасность" —
      // просто считаем, что логов нет.
      entryCount.value = 0;
      return [];
    }
  }

  Future<void> _writeAll(List<AppLogEntry> entries) async {
    entries.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final raw = jsonEncode(entries.map((e) => e.toJson()).toList());
    await LocalPrefs.instance.setString(_storageKey, raw);
    entryCount.value = entries.length;
  }
}