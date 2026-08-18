import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../widgets/neon.dart';

/// Реальные контакты бренда VPNonLine.
const websiteUrl = 'https://vpnonline.su';
const telegramBotUrl = 'https://t.me/VPNonLineRoBot';
const maxBotUrl = 'https://max.ru/se13572942_bot';
const supportBotUrl = 'https://t.me/VPNonLineSupportRoBot';
const newsChannelUrl = 'https://t.me/vpnonline_info';

/// Поддержка и контакты — сведено по SCREEN 6 макета: цветные логотип-бейджи
/// мессенджеров вместо обычных Material-иконок, .contact-card, блок
/// "О приложении" внизу.
class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppHeader(trailing: Icons.arrow_back_rounded, onTrailingTap: () => Navigator.pop(context)),
              const Text('Поддержка и контакты', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 14),
              _ContactCard(
                gradient: const [AppColors.violet, AppColors.violet2],
                icon: Icons.public_rounded,
                title: 'Сайт',
                subtitle: 'vpnonline.su',
                onTap: () => _open(websiteUrl),
              ),
              _ContactCard(
                color: const Color(0xFF229ED9),
                icon: Icons.send_rounded,
                title: 'Бот Telegram',
                subtitle: 't.me/VPNonLineRoBot',
                onTap: () => _open(telegramBotUrl),
              ),
              _ContactCard(
                gradient: const [Color(0xFF2B6BFF), Color(0xFF00C2FF)],
                icon: Icons.chat_bubble_rounded,
                title: 'Бот MAX',
                subtitle: 'max.ru/se13572942_bot',
                onTap: () => _open(maxBotUrl),
              ),
              _ContactCard(
                gradient: const [AppColors.violet, AppColors.violet2],
                icon: Icons.support_agent_rounded,
                title: 'Бот тех. поддержки',
                subtitle: 't.me/VPNonLineSupportRoBot',
                onTap: () => _open(supportBotUrl),
              ),
              _ContactCard(
                color: const Color(0xFF229ED9),
                icon: Icons.campaign_rounded,
                title: 'Канал новостей',
                subtitle: 't.me/vpnonline_info',
                onTap: () => _open(newsChannelUrl),
              ),
              const SectionTitle('О приложении'),
              NeonCard(
                child: Column(
                  children: const [
                    _InfoRow(k: 'Версия', v: '1.0.0'),
                    SizedBox(height: 8),
                    _InfoRow(k: 'Протокол', v: 'VLESS / Reality'),
                    SizedBox(height: 8),
                    _InfoRow(k: 'Политика логов', v: 'No-logs'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContactCard extends StatelessWidget {
  const _ContactCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.color,
    this.gradient,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? color;
  final List<Color>? gradient;

  @override
  Widget build(BuildContext context) {
    return NeonCard(
      margin: const EdgeInsets.only(bottom: 10),
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: gradient == null ? color : null,
              gradient: gradient != null ? LinearGradient(colors: gradient!) : null,
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 18, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(fontSize: 11, color: AppColors.textDim)),
            ],
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.k, required this.v});
  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(k, style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
        Text(v, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
