import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../widgets/update_banner.dart';
import '../services/locale_service.dart';
import '../services/update_installer.dart';
import '../services/update_service.dart';

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

  Future<void> _open(BuildContext context, String url) async {
    // Пробуем открыть сразу, не спрашивая canLaunchUrl: на Android 11+ он
    // отвечает false и для ссылок, которые открываются (видимость пакетов).
    // Если не вышло — говорим об этом, а не оставляем нажатие без ответа.
    final uri = Uri.parse(url);
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        appSnack('${tr('Не удалось открыть ссылку:')} $url', error: true),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: LocaleService.instance,
      builder: (context, _) => Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppHeader(trailing: Icons.arrow_back_rounded, onTrailingTap: () => Navigator.pop(context)),
              Text(tr('Поддержка и контакты'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 14),
              _ContactCard(
                gradient: const [AppColors.violet, AppColors.violet2],
                icon: Icons.public_rounded,
                title: tr('Сайт'),
                subtitle: 'vpnonline.su',
                onTap: () => _open(context, websiteUrl),
              ),
              _ContactCard(
                color: const Color(0xFF229ED9),
                icon: Icons.send_rounded,
                title: tr('Бот Telegram'),
                subtitle: 't.me/VPNonLineRoBot',
                onTap: () => _open(context, telegramBotUrl),
              ),
              _ContactCard(
                gradient: const [Color(0xFF2B6BFF), Color(0xFF00C2FF)],
                icon: Icons.chat_bubble_rounded,
                title: tr('Бот MAX'),
                subtitle: 'max.ru/se13572942_bot',
                onTap: () => _open(context, maxBotUrl),
              ),
              _ContactCard(
                gradient: const [AppColors.violet, AppColors.violet2],
                icon: Icons.support_agent_rounded,
                title: tr('Бот тех. поддержки'),
                subtitle: 't.me/VPNonLineSupportRoBot',
                onTap: () => _open(context, supportBotUrl),
              ),
              _ContactCard(
                color: const Color(0xFF229ED9),
                icon: Icons.campaign_rounded,
                title: tr('Канал новостей'),
                subtitle: 't.me/vpnonline_info',
                onTap: () => _open(context, newsChannelUrl),
              ),
              SectionTitle(tr('О приложении')),
              NeonCard(
                child: Column(
                  children: [
                    _InfoRow(k: tr('Версия'), v: appVersionLabel),
                    const SizedBox(height: 8),
                    _InfoRow(k: tr('Протокол'), v: 'VLESS / Reality'),
                    const SizedBox(height: 8),
                    _InfoRow(k: tr('Политика логов'), v: tr('No-logs')),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const _UpdateSection(),
            ],
          ),
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

/// Проверка обновлений по кнопке. Нашлась новая версия — здесь же та же
/// плашка, что на главном экране: загрузка со шкалой и установка.
class _UpdateSection extends StatefulWidget {
  const _UpdateSection();

  @override
  State<_UpdateSection> createState() => _UpdateSectionState();
}

class _UpdateSectionState extends State<_UpdateSection> {
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    UpdateService.instance.available.addListener(_changed);
    UpdateInstaller.instance.state.addListener(_changed);
  }

  @override
  void dispose() {
    UpdateService.instance.available.removeListener(_changed);
    UpdateInstaller.instance.state.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    final update = await UpdateService.instance.checkNow();
    if (!mounted) return;
    setState(() => _checking = false);
    // Нашлась — на экране уже плашка с кнопкой «Обновить».
    if (update != null) return;
    final failed = UpdateService.instance.lastCheckFailed;
    ScaffoldMessenger.of(context).showSnackBar(appSnack(
      failed
          ? tr('Не удалось проверить обновления — проверьте интернет и '
              'попробуйте ещё раз.')
          : '${tr('У вас последняя версия')} — $appVersionLabel',
      error: failed,
    ));
  }

  /// Запасной путь, если загрузка внутри приложения не удалась.
  Future<void> _openInBrowser(AppUpdate update) async {
    var opened = false;
    for (final url in [update.downloadUrl, UpdateService.latestReleasePage]) {
      try {
        opened = await launchUrl(url, mode: LaunchMode.externalApplication);
      } catch (_) {}
      if (opened) return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          appSnack(tr('Не удалось открыть ссылку на обновление.'), error: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final update = UpdateService.instance.available.value;
    if (update != null) {
      return UpdateBanner(
        progress: UpdateInstaller.instance.state.value,
        onUpdate: () =>
            unawaited(UpdateInstaller.instance.downloadAndInstall(update)),
        onInstall: () => unawaited(UpdateInstaller.instance.install()),
        onCancel: UpdateInstaller.instance.cancel,
        onOpenInBrowser: () => _openInBrowser(update),
        onDismiss: () => unawaited(UpdateService.instance.dismiss()),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _checking ? null : _check,
        icon: _checking
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.system_update_rounded,
                size: 18, color: AppColors.violetGlow),
        label: Text(
            _checking ? tr('Проверяю обновления…') : tr('Проверить обновления')),
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