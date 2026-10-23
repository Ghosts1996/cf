import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
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

/// Локальный журнал диагностических событий (подключение, отключение,
/// ошибки) — раздел "Безопасность" -> "Хранение логов".
///
/// Это технический журнал на самом устройстве, а не логи провайдера о
/// трафике: политика сервиса остаётся No-logs. Пользователь может
/// ограничить срок хранения или стереть записи вручную.
///
/// Хранится в LocalPrefs (shared_preferences) как JSON-массив под одним
/// ключом — тем же способом, что и карта "приложение -> обход VPN" в
/// split-tunnel.
///
/// Автоудаление по сроку срабатывает при новой записи и при любом
/// обращении к логам (например, при открытии экрана "Безопасность"), а не
/// по фоновому таймеру: если приложение долго не открывать, устаревшие
/// записи сотрутся при первом же запуске. Сверху есть жёсткий потолок
/// [_maxEntries], так что список не растёт бесконечно.
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

  // Журнал целиком живёт в памяти, а в хранилище уходит пачкой.
  //
  // Раньше каждая строка стоила полного круга: прочитать весь журнал из
  // хранилища, разобрать JSON, дописать, собрать JSON заново, записать, а
  // затем ещё раз прочитать и разобрать ради очистки старого. В журнале до
  // пятисот записей, среди них полные конфиги ядра по десятку килобайт, —
  // это мегабайты JSON в главном потоке на каждую строку. Подключение пишет
  // их десяток подряд: экран замирал, а приложение «зависало как-то сильно».
  List<AppLogEntry>? _cache;
  Future<List<AppLogEntry>>? _loading;

  // Цепочка нужна, чтобы записи шли строго по порядку и не терялись, даже
  // когда несколько событий приходят в одну миллисекунду.
  Future<void> _writeChain = Future.value();
  Timer? _persistTimer;
  DateTime? _lastRetentionAt;

  /// Пауза перед записью в хранилище: строки одного всплеска (подключение,
  /// пачка журнала ядра) уходят на диск одной записью.
  ///
  /// На Windows — реже: там все настройки лежат одним JSON-файлом, который
  /// переписывается целиком без защиты от обрыва, и приложение, закрытое
  /// посреди записи (выключение компьютера, установщик обновления), оставляло
  /// его обрезанным — см. startup_guard.dart.
  static final _persistDelay = !kIsWeb && Platform.isWindows
      ? const Duration(seconds: 2)
      : const Duration(milliseconds: 150);

  /// Потолок размера журнала в символах. Хранилище настроек целиком
  /// читается при каждом запуске приложения и целиком переписывается при
  /// каждой записи — многомегабайтный журнал замедлял и то, и другое.
  static const _maxTotalChars = 600000;

  /// Одна запись не длиннее этого — конфиг ядра с запасом помещается.
  static const _maxMessageChars = 30000;

  /// Сколько раз журнал реально переписывался в хранилище. Нужен тестам:
  /// по нему видно, что пачка строк ядра стоит одну запись, а не сотню.
  @visibleForTesting
  int debugWriteCount = 0;

  /// Забыть журнал в памяти — как после перезапуска приложения.
  @visibleForTesting
  Future<void> debugDropCache() async {
    await _writeChain;
    _persistTimer?.cancel();
    _persistTimer = null;
    _cache = null;
    _loading = null;
    _lastRetentionAt = null;
  }

  Future<List<AppLogEntry>> _entries() {
    final cached = _cache;
    if (cached != null) return Future.value(cached);
    return _loading ??= _readAll().then((entries) {
      _cache = entries;
      _loading = null;
      return entries;
    });
  }

  /// Добавляет сразу несколько записей за одну запись в хранилище.
  Future<void> logBatch(List<({String message, AppLogLevel level})> items) {
    if (items.isEmpty) return _writeChain;
    final now = DateTime.now();
    return _enqueue([
      for (final item in items)
        AppLogEntry(
            timestamp: now, message: _clip(item.message), level: item.level),
    ]);
  }

  /// Добавляет запись в журнал. Безопасна для вызова откуда угодно —
  /// ошибки чтения/записи хранилища не пробрасываются наружу, чтобы сбой
  /// логирования никогда не мешал основной функциональности приложения.
  Future<void> log(String message, {AppLogLevel level = AppLogLevel.info}) =>
      _enqueue([
        AppLogEntry(
            timestamp: DateTime.now(), message: _clip(message), level: level),
      ]);

  static String _clip(String message) => message.length <= _maxMessageChars
      ? message
      : '${message.substring(0, _maxMessageChars)}…';

  Future<void> _enqueue(List<AppLogEntry> items) {
    final next = _writeChain.then((_) async {
      try {
        final entries = await _entries();
        entries.addAll(items);
        _trim(entries);
        // Срок хранения проверяем не на каждой строке — раз в десять минут
        // хватает: записи старше суток или недели от этого не задержатся.
        final last = _lastRetentionAt;
        if (last == null ||
            DateTime.now().difference(last) > const Duration(minutes: 10)) {
          await _applyRetentionTo(entries);
        }
        entryCount.value = entries.length;
        _schedulePersist();
      } catch (_) {
        // Лог — вспомогательная функция, не критичная для работы VPN.
      }
    });
    _writeChain = next;
    return next;
  }

  /// Старые записи уходят первыми — и по числу, и по общему размеру.
  static void _trim(List<AppLogEntry> entries) {
    if (entries.length > _maxEntries) {
      entries.removeRange(0, entries.length - _maxEntries);
    }
    var total = 0;
    for (final e in entries) {
      total += e.message.length;
    }
    var drop = 0;
    while (total > _maxTotalChars && drop < entries.length - 1) {
      total -= entries[drop].message.length;
      drop++;
    }
    if (drop > 0) entries.removeRange(0, drop);
  }

  void _schedulePersist() {
    _persistTimer ??= Timer(_persistDelay, () {
      _persistTimer = null;
      _writeChain = _writeChain.then((_) async {
        final entries = _cache;
        if (entries == null) return;
        try {
          await _writeAll(entries);
        } catch (_) {}
      });
    });
  }

  /// Все записи, новые сверху, уже с применённым сроком хранения.
  Future<List<AppLogEntry>> getAll() async {
    await _writeChain;
    await applyRetention();
    final entries = await _entries();
    return entries.reversed.toList();
  }

  /// Ручное удаление — кнопка "Удалить все логи" на экране "Безопасность".
  Future<void> clearAll() async {
    await _writeChain;
    _persistTimer?.cancel();
    _persistTimer = null;
    _cache = <AppLogEntry>[];
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
    final entries = await _entries();
    await _applyRetentionTo(entries);
    entryCount.value = entries.length;
  }

  Future<void> _applyRetentionTo(List<AppLogEntry> entries) async {
    _lastRetentionAt = DateTime.now();
    final days = await getRetentionDays();
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final before = entries.length;
    entries.removeWhere((e) => !e.timestamp.isAfter(cutoff));
    if (entries.length != before) _schedulePersist();
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
      final entries = decoded.map(AppLogEntry.tryFromJson).whereType<AppLogEntry>().toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      // Журнал прошлых версий мог разрастись до мегабайтов — ужимаем сразу.
      _trim(entries);
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
    final raw = jsonEncode(entries.map((e) => e.toJson()).toList());
    debugWriteCount++;
    await LocalPrefs.instance.setString(_storageKey, raw);
    entryCount.value = entries.length;
  }
}