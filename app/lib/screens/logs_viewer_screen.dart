import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/app_log_service.dart';
import '../services/locale_service.dart';

/// Просмотр локальных логов приложения. Открывается кнопкой
/// "Просмотреть логи" в разделе "Хранение логов" на экране
/// "Безопасность", читает записи через AppLogService.instance.getAll().
///
/// Загрузка по требованию — при открытии и по свайпу вниз: список меняется
/// нечасто, а живой счётчик записей уже есть на экране "Безопасность".
class LogsViewerScreen extends StatefulWidget {
  const LogsViewerScreen({super.key});

  @override
  State<LogsViewerScreen> createState() => _LogsViewerScreenState();
}

class _LogsViewerScreenState extends State<LogsViewerScreen> {
  List<AppLogEntry> _entries = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await AppLogService.instance.getAll();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _deleteAllLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgCard,
        title: Text(tr('Удалить все логи?')),
        content: Text(
          tr('Локальный журнал событий приложения (подключения, ошибки) будет удалён полностью. '
          'Действие необратимо.'),
          style: const TextStyle(color: AppColors.textDim, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Отмена'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Удалить'), style: const TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await AppLogService.instance.clearAll();
    if (!mounted) return;
    setState(() => _entries = const []);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('Логи удалены'))),
    );
  }

  /// Копирует весь журнал текстом. Нужно, чтобы отправить его в поддержку:
  /// сообщения ядра ("Ядро: ...") — единственный источник настоящей причины,
  /// когда туннель поднят, а трафика нет.
  Future<void> _copyAllLogs() async {
    final text = _entries
        .map((e) => '${_formatTimestamp(e.timestamp)}  '
            '[${e.level.name.toUpperCase()}] ${e.message}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('Журнал скопирован'))),
    );
  }

  Color _levelColor(AppLogLevel level) {
    switch (level) {
      case AppLogLevel.error:
        return AppColors.danger;
      case AppLogLevel.warning:
        return AppColors.warning;
      case AppLogLevel.info:
        return AppColors.violetGlow;
    }
  }

  IconData _levelIcon(AppLogLevel level) {
    switch (level) {
      case AppLogLevel.error:
        return Icons.error_rounded;
      case AppLogLevel.warning:
        return Icons.warning_rounded;
      case AppLogLevel.info:
        return Icons.info_rounded;
    }
  }

  String _formatTimestamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)}.${t.year} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: LocaleService.instance,
      builder: (context, _) => Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppHeader(trailing: Icons.arrow_back_rounded, onTrailingTap: () => Navigator.pop(context)),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(tr('Логи приложения'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  if (_entries.isNotEmpty)
                    Row(
                      children: [
                        GestureDetector(
                          onTap: _copyAllLogs,
                          child: const Padding(
                            padding:
                                EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                            child: Icon(Icons.copy_all_rounded,
                                size: 20, color: AppColors.textDim),
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: _deleteAllLogs,
                          child: const Padding(
                            padding:
                                EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                            child: Icon(Icons.delete_forever_rounded,
                                size: 20, color: AppColors.danger),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                tr('Технический журнал событий на устройстве: подключения, ошибки. Это не логи трафика — политика провайдера No-logs не затрагивается.'),
                style: const TextStyle(fontSize: 10.5, color: AppColors.textDim, height: 1.4),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                    : RefreshIndicator(
                        color: AppColors.violet2,
                        backgroundColor: AppColors.bgCard,
                        onRefresh: _load,
                        child: _entries.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: [
                                  const SizedBox(height: 80),
                                  const Center(
                                    child: Icon(Icons.receipt_long_rounded, size: 40, color: AppColors.textDim),
                                  ),
                                  const SizedBox(height: 12),
                                  Center(
                                    child: Text(
                                      tr('Логов пока нет'),
                                      style: const TextStyle(fontSize: 13, color: AppColors.textDim),
                                    ),
                                  ),
                                ],
                              )
                            : ListView.separated(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.only(bottom: 20),
                                itemCount: _entries.length,
                                separatorBuilder: (_, __) => const SizedBox(height: 8),
                                itemBuilder: (context, index) {
                                  final e = _entries[index];
                                  final color = _levelColor(e.level);
                                  return NeonCard(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Icon(_levelIcon(e.level), size: 16, color: color),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                e.message,
                                                style: const TextStyle(fontSize: 12.5, height: 1.35),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                _formatTimestamp(e.timestamp),
                                                style: orbitron(fontSize: 9.5, color: AppColors.textDim),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}