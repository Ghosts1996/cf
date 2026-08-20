import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/local_prefs.dart';
import '../services/tunnel_service.dart';

/// Безопасность (Kill Switch, DNS) — пункт меню из макета.
///
/// [ИСПРАВЛЕНО] Тумблеры были обычным `bool` полем State — забывались при
/// выходе с экрана/перезапуске (подробности — services/local_prefs.dart).
/// Теперь читаются/пишутся в LocalPrefs, значение реально сохраняется.
/// Ключи хранения общие с SettingsScreen (killSwitch — один и тот же
/// переключатель показан в двух местах интерфейса, обе копии теперь
/// синхронизированы через один и тот же persist-ключ вместо двух
/// независимых друг от друга состояний).
///
/// ДОПУЩЕНИЕ (принцип 4, честно): реальная блокировка трафика при обрыве
/// туннеля/фильтрация DNS зависит от нативной реализации VPN-сервиса —
/// см. NATIVE_SETUP.md. Сохранение выбора уже полностью рабочее.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});
  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  final _prefs = LocalPrefs.instance;

  bool _killSwitch = true;
  bool _dnsProtection = false;
  bool _blockAds = false;
  // [НОВОЕ] "Агрессивное переподключение" — настраиваемое число попыток
  // восстановления соединения. false = 3 попытки (мягко,
  // экономит батарею при долгом отсутствии сети), true = 8 попыток
  // (пытается дольше на нестабильных сетях). Реально читается
  // TunnelService.connect() при каждом подключении — см. tunnel_service.dart.
  bool _aggressiveReconnect = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _prefs.getBool(PrefKeys.killSwitch, fallback: true),
      // [ИСПРАВЛЕНО] По умолчанию выключено — совпадает с fallback в
      // tunnel_service.dart, чтобы UI не расходился с реальным конфигом.
      _prefs.getBool(PrefKeys.dnsProtection, fallback: false),
      _prefs.getBool(PrefKeys.blockAds, fallback: false),
      _prefs.getInt(PrefKeys.reconnectAttempts, fallback: 3),
    ]);
    if (!mounted) return;
    setState(() {
      _killSwitch = results[0] as bool;
      _dnsProtection = results[1] as bool;
      _blockAds = results[2] as bool;
      _aggressiveReconnect = (results[3] as int) > 3;
      _loaded = true;
    });
  }

  /// [НОВОЕ] Реальная настройка, не декоративная — TunnelService.connect()
  /// читает settings.reconnect_attempts при каждом подключении и именно
  /// столько раз подряд пытается восстановить туннель после неожиданного
  /// обрыва, прежде чем сдаться и показать предупреждение "интернет БЕЗ
  /// защиты VPN".
  Future<void> _setAggressiveReconnect(bool v) async {
    setState(() => _aggressiveReconnect = v);
    await _prefs.setInt(PrefKeys.reconnectAttempts, v ? 8 : 3);
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
              const Text('Безопасность', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              if (!_loaded)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else
                NeonCard(
                  child: Column(
                    children: [
                      _Row(
                        icon: Icons.shield_rounded,
                        title: 'Kill Switch',
                        subtitle: 'Блокирует интернет при обрыве туннеля',
                        trailing: NeonToggle(
                          value: _killSwitch,
                          onChanged: (v) async {
                            setState(() => _killSwitch = v);
                            await _prefs.setBool(PrefKeys.killSwitch, v);
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                      // [НОВОЕ] Тумблер выше — это автоматическое
                      // восстановление соединения при обрыве (реальное, см.
                      // tunnel_service.dart), а НЕ физическая блокировка
                      // трафика на уровне ОС. Настоящая блокировка ("ни
                      // байта мимо VPN") — системная настройка Android,
                      // приложение не может включить её программно, только
                      // привести пользователя на нужный экран.
                      GestureDetector(
                        onTap: () => TunnelService.instance.openSystemVpnSettingsHint(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppColors.violet2.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.violet2.withValues(alpha: 0.3)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.settings_suggest_rounded, size: 16, color: AppColors.violetGlow),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'Включить настоящую блокировку трафика без VPN (системная настройка Android)',
                                  style: TextStyle(fontSize: 10.5, color: AppColors.textDim),
                                ),
                              ),
                              const Icon(Icons.chevron_right_rounded, size: 16, color: AppColors.textDim),
                            ],
                          ),
                        ),
                      ),
                      const Divider(height: 20),
                      _Row(
                        icon: Icons.dns_rounded,
                        title: 'Защита от DNS-протечек',
                        subtitle: 'Весь DNS-трафик идёт через туннель',
                        trailing: NeonToggle(
                          value: _dnsProtection,
                          onChanged: (v) async {
                            setState(() => _dnsProtection = v);
                            await _prefs.setBool(PrefKeys.dnsProtection, v);
                          },
                        ),
                      ),
                      const Divider(height: 20),
                      _Row(
                        icon: Icons.block_rounded,
                        title: 'Блокировка рекламы и трекеров',
                        subtitle: 'На уровне DNS-фильтрации',
                        trailing: NeonToggle(
                          value: _blockAds,
                          onChanged: (v) async {
                            setState(() => _blockAds = v);
                            await _prefs.setBool(PrefKeys.blockAds, v);
                          },
                        ),
                      ),
                      const Divider(height: 20),
                      // [НОВОЕ] Настраиваемая "живучесть" Kill Switch —
                      // реально влияет на TunnelService.connect(), см.
                      // _setAggressiveReconnect выше.
                      _Row(
                        icon: Icons.replay_circle_filled_rounded,
                        title: 'Агрессивное переподключение',
                        subtitle: _aggressiveReconnect
                            ? 'До 8 попыток восстановить туннель при обрыве'
                            : 'До 3 попыток восстановить туннель при обрыве',
                        trailing: NeonToggle(
                          value: _aggressiveReconnect,
                          onChanged: _setAggressiveReconnect,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
                ),
                child: const Text(
                  'На Android эти переключатели реально влияют на трафик (DNS-защита и блокировка рекламы '
                  'встроены в конфиг туннеля при следующем подключении, Kill Switch — это автовосстановление '
                  'соединения при обрыве). На платформах без нативного VPN-туннеля (см. NATIVE_SETUP.md) выбор '
                  'сохраняется, но пока ни на что не влияет.',
                  style: TextStyle(fontSize: 11, color: AppColors.textDim, height: 1.4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, required this.subtitle, required this.trailing});
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        RingIconBadge(icon: icon, size: 36),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(fontSize: 10, color: AppColors.textDim)),
            ],
          ),
        ),
        trailing,
      ],
    );
  }
}