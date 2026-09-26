// Журнал ядра: строки взяты из журнала пользователя как есть, с цветовыми
// кодами терминала.
import 'package:flutter_singbox_client/flutter_singbox_client.dart'
    show LogEntry, LogLevel;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpnonline_app/services/app_log_service.dart';
import 'package:vpnonline_app/services/tunnel_service.dart';

import 'support/fake_runtime.dart';

const _esc = '\x1B';
String line(String level, String text) =>
    '$_esc[37m$level$_esc[0m[0211] $text';

// Плагин присылает уровень по зеркальной таблице: так эти строки и
// приходили с телефона.
LogEntry entry(LogLevel pluginLevel, String message) =>
    LogEntry(level: pluginLevel, message: message, time: DateTime.now());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('уровень строки ядра', () {
    test('TRACE, пришедший как panic, — шум, а не ошибка', () {
      expect(
          TunnelService.coreLogSeverity(LogLevel.panic,
              line('TRACE', 'outbound/vless[out-2]: XtlsPadding 76 171 0')),
          isNull);
    });
    test('DEBUG, пришедший как fatal, — шум', () {
      expect(
          TunnelService.coreLogSeverity(LogLevel.fatal,
              line('DEBUG', 'outbound/urltest[latency]: out-2 available: 75ms')),
          isNull);
    });
    test('INFO, пришедший как error, — шум', () {
      expect(
          TunnelService.coreLogSeverity(LogLevel.error,
              line('INFO', 'outbound/vless[out-2]: outbound connection to cp.cloudflare.com:80')),
          isNull);
    });
    test('WARN — предупреждение', () {
      expect(
          TunnelService.coreLogSeverity(LogLevel.warn,
              line('WARN', 'dns: exchange failed')),
          AppLogLevel.warning);
    });
    test('настоящий ERROR, пришедший как info, больше не теряется', () {
      expect(
          TunnelService.coreLogSeverity(LogLevel.info,
              line('ERROR', 'router: process connection: dial failed')),
          AppLogLevel.error);
    });
    test('без слова в тексте — поле плагина разворачивается обратно', () {
      // «info» от плагина — это на самом деле ERROR (уровень 2).
      expect(TunnelService.coreLogSeverity(LogLevel.info, 'что-то сломалось'),
          AppLogLevel.error);
      // «panic» от плагина — это на самом деле TRACE (уровень 6).
      expect(TunnelService.coreLogSeverity(LogLevel.panic, 'пакет'), isNull);
    });
    test('цветовые коды терминала вычищаются', () {
      expect(TunnelService.cleanCoreLogMessage(line('WARN', 'dns: timeout')),
          'WARN[0211] dns: timeout');
    });
  });

  group('нагрузка', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('тысяча строк трассировки — ни одной записи в хранилище', () async {
      final tunnel = TunnelService.withRuntime(FakeRuntime());
      final before = AppLogService.instance.debugWriteCount;
      final batch = [
        for (var i = 0; i < 1000; i++)
          entry(LogLevel.panic,
              line('TRACE', 'outbound/vless[out-10]: Xtls Unpadding new block $i')),
      ];
      final sw = Stopwatch()..start();
      tunnel.debugHandleCoreLogs(batch);
      sw.stop();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(AppLogService.instance.debugWriteCount, before,
          reason: 'шум ядра не должен трогать диск');
      expect(sw.elapsedMilliseconds, lessThan(200),
          reason: 'разбор тысячи строк должен быть дешёвым');
    });

    test('пачка с предупреждениями — одна запись, а не по строке', () async {
      final tunnel = TunnelService.withRuntime(FakeRuntime());
      final before = AppLogService.instance.debugWriteCount;
      tunnel.debugHandleCoreLogs([
        for (var i = 0; i < 50; i++) entry(LogLevel.warn, line('WARN', 'w$i')),
        for (var i = 0; i < 500; i++) entry(LogLevel.panic, line('TRACE', 't$i')),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(AppLogService.instance.debugWriteCount - before, 1);
      final logs = await AppLogService.instance.getAll();
      expect(logs.where((e) => e.message.contains('TRACE')), isEmpty);
      expect(logs.where((e) => e.message.startsWith('Ядро: WARN')).length, 50);
      expect(logs.any((e) => e.message.contains('\x1B')), isFalse);
    });
  });
}
