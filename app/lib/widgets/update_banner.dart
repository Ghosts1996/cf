import 'package:flutter/material.dart';

import '../services/locale_service.dart';
import '../theme.dart';

/// Плашка «Доступна новая версия» с кнопками «Обновить» и «×».
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({
    super.key,
    required this.onUpdate,
    required this.onDismiss,
  });

  final VoidCallback onUpdate;
  final VoidCallback onDismiss;

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
      child: Row(
        children: [
          const Icon(Icons.system_update_rounded,
              color: AppColors.violetGlow, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              tr('Доступна новая версия приложения'),
              style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.text,
                  fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: onUpdate,
            child: Text(tr('Обновить'),
                style: const TextStyle(
                    color: AppColors.violetGlow, fontWeight: FontWeight.w700)),
          ),
          IconButton(
            tooltip: tr('Скрыть'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded,
                size: 18, color: AppColors.textDim),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
