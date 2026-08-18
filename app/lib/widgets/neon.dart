import 'package:flutter/material.dart';
import '../theme.dart';

/// Общие компоненты, воспроизводящие CSS-классы из макета
/// vpnonline-app-mockup-2.html: .app-header/.brand, .neon-ring icon badge
/// (.menu-row .ic), .server-pill, .stat-card, .badge, .toggle, .btn-pill,
/// .plan-card, .key-card/.contact-card, .section-title, .header-divider.
/// Один источник правды для стиля — экраны просто собирают их.

/// Шапка экрана: кольцо-лого + "VPN"+"onLine" + кнопка справа (меню/назад).
class AppHeader extends StatelessWidget {
  const AppHeader({
    super.key,
    this.trailing,
    this.onTrailingTap,
    this.screenLabel,
  });

  final IconData? trailing;
  final VoidCallback? onTrailingTap;
  final String? screenLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // [ИСПРАВЛЕНО] Раньше отступ сверху был всего 4px — на части
        // реальных устройств (вырез камеры / изогнутый угол экрана вне
        // зоны status bar, которую SafeArea не всегда полностью учитывает
        // на некоторых прошивках) заголовок визуально "залезал" под вырез.
        // Увеличено до 14px — достаточный запас на большинстве устройств,
        // при этом не создаёт заметной лишней пустоты там, где выреза нет.
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.violet2, width: 2),
                      boxShadow: AppColors.glow(AppColors.violet2, blur: 10, alpha: 0.7),
                    ),
                  ),
                  const SizedBox(width: 8),
                  RichText(
                    text: TextSpan(
                      style: orbitron(fontSize: 15, fontWeight: FontWeight.w700),
                      children: [
                        const TextSpan(text: 'VPN'),
                        TextSpan(
                          text: 'onLine',
                          style: orbitron(
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            color: AppColors.violet2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (trailing != null)
                GestureDetector(
                  onTap: onTrailingTap,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: const Color(0xFF120B22),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Icon(trailing, size: 16, color: AppColors.textDim),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                Colors.transparent,
                AppColors.violet2.withOpacity(0.35),
                Colors.transparent,
              ]),
            ),
          ),
        ),
        if (screenLabel != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              screenLabel!.toUpperCase(),
              style: orbitron(fontSize: 11, color: AppColors.violetDim, letterSpacing: 2),
            ),
          ),
      ],
    );
  }
}

/// Кольцевой неоновый бейдж иконки — как .menu-row .ic в макете.
class RingIconBadge extends StatelessWidget {
  const RingIconBadge({super.key, required this.icon, this.danger = false, this.size = 42});
  final IconData icon;
  final bool danger;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : AppColors.violetGlow;
    final ringColor = danger ? AppColors.danger : AppColors.violet2;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ringColor.withOpacity(0.6), width: 1.5),
        boxShadow: AppColors.glow(ringColor, blur: 10, alpha: 0.35),
      ),
      child: Icon(icon, size: size * 0.45, color: color),
    );
  }
}

/// Базовая карточка — .key-card/.contact-card/.plan-card фон+бордер.
class NeonCard extends StatelessWidget {
  const NeonCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.selected = false,
    this.selectedColor,
    this.onTap,
    this.margin,
  });

  final Widget child;
  final EdgeInsets padding;
  final bool selected;
  final Color? selectedColor;
  final VoidCallback? onTap;
  final EdgeInsets? margin;

  @override
  Widget build(BuildContext context) {
    final sColor = selectedColor ?? AppColors.violet2;
    return Container(
      margin: margin,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: AppColors.bgCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: selected ? sColor : AppColors.border),
              boxShadow: selected ? AppColors.glow(sColor, blur: 16, alpha: 0.25) : null,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Заголовок секции — .section-title.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          color: AppColors.textDim,
          letterSpacing: 1.5,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// Маленький статус-бейдж — .badge ("активен", "выбран" и т.д.).
class NeonBadge extends StatelessWidget {
  const NeonBadge(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.violetGlow;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withOpacity(0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(fontSize: 9, color: c, fontWeight: FontWeight.w600)),
    );
  }
}

/// Кастомный неоновый переключатель — .toggle / .toggle.on.
class NeonToggle extends StatelessWidget {
  const NeonToggle({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 38,
        height: 22,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1330),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 150),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value ? AppColors.violet2 : AppColors.textDim,
              boxShadow: value ? AppColors.glow(AppColors.violet2, blur: 6, alpha: 0.7) : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// Кнопка-пилюля — .btn-pill (ghost/dashed) и градиентный вариант.
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    this.onTap,
    this.filled = false,
    this.dashed = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onTap;
  final bool filled;
  final bool dashed;
  final String? icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            gradient: filled ? AppColors.violetGradient : null,
            color: filled ? null : (dashed ? Colors.transparent : AppColors.violet2.withOpacity(0.06)),
            borderRadius: BorderRadius.circular(20),
            border: filled
                ? null
                : Border.all(
                    color: dashed ? AppColors.border : AppColors.border,
                    style: BorderStyle.solid,
                  ),
            boxShadow: filled ? AppColors.glow(AppColors.violet2, blur: 14, alpha: 0.35) : null,
          ),
          child: Text(
            icon != null ? '$icon $label' : label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: filled ? Colors.white : AppColors.violetGlow,
            ),
          ),
        ),
      ),
    );
  }
}

/// Мини-карточка статистики — .stat-card.
class StatMiniCard extends StatelessWidget {
  const StatMiniCard({super.key, required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label.toUpperCase(),
                style: const TextStyle(fontSize: 9, color: AppColors.textDim, letterSpacing: 0.6)),
            const SizedBox(height: 4),
            Text(value, style: orbitron(fontSize: 13, color: AppColors.violetGlow)),
          ],
        ),
      ),
    );
  }
}

/// Строка сервера — .server-pill (флаг-инициалы, название, пинг, chevron).
class ServerPill extends StatelessWidget {
  const ServerPill({
    super.key,
    required this.code,
    required this.name,
    required this.pingLabel,
    this.pingColor = AppColors.success,
    this.trailing,
    this.onTap,
    this.flagGradientColors,
  });

  final String code;
  final String name;
  final String pingLabel;
  final Color pingColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final List<Color>? flagGradientColors;

  @override
  Widget build(BuildContext context) {
    return NeonCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      margin: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: flagGradientColors ?? [AppColors.violet, AppColors.violet2],
              ),
            ),
            alignment: Alignment.center,
            child: Text(code,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(pingLabel, style: TextStyle(fontSize: 10, color: pingColor)),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
