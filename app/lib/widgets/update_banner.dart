import 'package:flutter/material.dart';

import '../services/locale_service.dart';
import '../services/update_installer.dart';
import '../theme.dart';

/// Плашка обновления на главном экране. Меняется по ходу дела:
/// «Доступна новая версия» → шкала загрузки → «Установить».
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({
    super.key,
    this.progress = const UpdateProgress(),
    required this.onUpdate,
    required this.onDismiss,
    this.onCancel,
    this.onInstall,
    this.onOpenInBrowser,
  });

  final UpdateProgress progress;
  final VoidCallback onUpdate;
  final VoidCallback onDismiss;
  final VoidCallback? onCancel;
  final VoidCallback? onInstall;

  /// Запасной путь, если загрузка внутри приложения не удалась.
  final VoidCallback? onOpenInBrowser;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: AppColors.violet.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.violet.withValues(alpha: 0.45)),
      ),
      child: switch (progress.phase) {
        UpdatePhase.idle => _row(
            icon: Icons.system_update_rounded,
            text: tr('Доступна новая версия приложения'),
            actions: [
              _button(tr('Обновить'), onUpdate),
              _close(),
            ],
          ),
        UpdatePhase.downloading => _downloading(),
        UpdatePhase.ready => _row(
            icon: Icons.download_done_rounded,
            text: tr('Обновление загружено'),
            actions: [_button(tr('Установить'), onInstall ?? onUpdate)],
          ),
        UpdatePhase.needsPermission => _row(
            icon: Icons.lock_open_rounded,
            text: tr('Разрешите установку обновлений в открывшихся настройках, '
                'затем нажмите «Установить»'),
            actions: [_button(tr('Установить'), onInstall ?? onUpdate)],
          ),
        UpdatePhase.failed => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row(
                icon: Icons.error_outline_rounded,
                iconColor: AppColors.danger,
                text: progress.error ?? tr('Не удалось загрузить обновление'),
                actions: [_button(tr('Повторить'), onUpdate), _close()],
              ),
              if (onOpenInBrowser != null)
                Padding(
                  padding: const EdgeInsets.only(left: 30),
                  child: TextButton(
                    onPressed: onOpenInBrowser,
                    style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: Text(tr('Скачать через браузер'),
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.textDim)),
                  ),
                ),
            ],
          ),
      },
    );
  }

  Widget _downloading() {
    final percent = progress.percent;
    final mb = progress.totalBytes > 0
        ? ' · ${_mb(progress.receivedBytes)} из ${_mb(progress.totalBytes)}'
        : (progress.receivedBytes > 0 ? ' · ${_mb(progress.receivedBytes)}' : '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row(
          icon: Icons.downloading_rounded,
          text: percent == null
              ? '${tr('Загрузка обновления…')}$mb'
              : '${tr('Загрузка обновления')} $percent%$mb',
          actions: [
            if (onCancel != null) _button(tr('Отмена'), onCancel!, dim: true),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(30, 6, 8, 2),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              // null — размер неизвестен, шкала бегущая.
              value: progress.fraction,
              minHeight: 6,
              backgroundColor: AppColors.violet.withValues(alpha: 0.18),
              valueColor:
                  const AlwaysStoppedAnimation<Color>(AppColors.violetGlow),
            ),
          ),
        ),
      ],
    );
  }

  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';

  Widget _row({
    required IconData icon,
    required String text,
    required List<Widget> actions,
    Color iconColor = AppColors.violetGlow,
  }) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.text,
                fontWeight: FontWeight.w600,
                height: 1.3),
          ),
        ),
        ...actions,
      ],
    );
  }

  Widget _button(String label, VoidCallback onPressed, {bool dim = false}) {
    return TextButton(
      onPressed: onPressed,
      child: Text(label,
          style: TextStyle(
              color: dim ? AppColors.textDim : AppColors.violetGlow,
              fontWeight: FontWeight.w700)),
    );
  }

  Widget _close() {
    return IconButton(
      tooltip: tr('Скрыть'),
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.textDim),
      onPressed: onDismiss,
    );
  }
}
