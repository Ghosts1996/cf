import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';
import 'keys_screen.dart';
import 'plans_screen.dart';
import 'servers_screen.dart';
import 'split_tunnel_screen.dart';
import 'referral_screen.dart';
import 'security_screen.dart';
import 'settings_screen.dart';
import 'support_screen.dart';
import 'topup_screen.dart';

/// Меню/профиль — сведено по SCREEN 5 макета (.contact-card шапка с
/// email+балансом, .menu-list с кольцевыми иконками).
///
/// [ИСПРАВЛЕНО v4] Раньше `final _api = ApiClient()` создавал свой
/// собственный неавторизованный клиент (см. подробный разбор в
/// services/api_client.dart) — теперь используется общий
/// `ApiClient.instance` с реально восстановленным токеном.
/// [ИСПРАВЛЕНО v4] Кнопка "Выйти из аккаунта" была `onPressed: () {}` —
/// ничего не делала. Теперь реально чистит токен и возвращает на экран входа.
/// [ИСПРАВЛЕНО v4] Диалог "Бесплатный период" сообщал, что триал "не
/// настроен" — это было неверно: триал включён через bot_settings (не
/// через таблицу plans, см. backend v4), просто предыдущая версия не знала,
/// где его искать. Теперь кнопка реально активирует триал через API.
class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key, required this.onLoggedOut});
  final VoidCallback onLoggedOut;

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  final _api = ApiClient.instance;
  // [ИСПРАВЛЕНО] Реального /balance эндпоинта на сервере нет — отдельного
  // getBalance() в новом ApiClient тоже нет. Баланс приходит вместе со
  // всем остальным профилем одним вызовом GET /user/profile
  // (см. services/api_client.dart -> getProfile()).
  Map<String, dynamic>? _profile;
  List<dynamic>? _keys;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([_api.getProfile(), _api.getKeys()]);
      setState(() {
        _profile = results[0] as Map<String, dynamic>;
        _keys = results[1] as List<dynamic>;
      });
    } catch (_) {
      // Тихий сбой здесь не критичен для навигации по меню — просто не
      // покажем баланс/число ключей, но список пунктов остаётся рабочим.
    }
  }

  void _go(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgCard,
        title: const Text('Выйти из аккаунта?'),
        content: const Text('Тебе нужно будет снова войти по email и паролю.',
            style: TextStyle(color: AppColors.textDim, fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Выйти', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _api.logout();
      widget.onLoggedOut();
    }
  }

  Future<void> _activateTrial() async {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgCard,
        title: const Text('Бесплатный период'),
        content: const Text(
          'Активировать бесплатный пробный период? Ключ появится сразу во всех доступных локациях '
          'в разделе «Мои ключи».',
          style: TextStyle(color: AppColors.textDim, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await _api.claimTrial();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Триал активирован — смотри «Мои ключи»')),
                  );
                  _go(const KeysScreen());
                }
              } on ApiException catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(e.message), backgroundColor: AppColors.danger),
                  );
                }
              }
            },
            child: const Text('Активировать'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // [ИСПРАВЛЕНО] Реальный /user/keys не отдаёт поле `active_in_panel` —
    // "активность" ключа определяется сроком действия (`expiry_date`),
    // как и на экране "Мои ключи" (см. keys_screen.dart -> _KeyCard).
    final activeKeys = _keys?.cast<Map<String, dynamic>>().where((k) {
      final expiryStr = k['expiry_date'] as String?;
      final expiry = expiryStr != null ? DateTime.tryParse(expiryStr) : null;
      return expiry != null && expiry.isAfter(DateTime.now());
    }).length;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppHeader(trailing: Icons.close_rounded, screenLabel: 'Меню'),
          NeonCard(
            child: Row(
              children: [
                RingIconBadge(icon: Icons.person_rounded, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Мой аккаунт', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(
                        _profile != null
                            ? 'Баланс: ${_profile!['balance']} ₽'
                                '${activeKeys != null ? ' · $activeKeys активных ключей' : ''}'
                            : 'Загрузка баланса…',
                        style: const TextStyle(fontSize: 11, color: AppColors.textDim),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          _MenuRow(icon: Icons.vpn_key_rounded, label: 'Мои ключи', onTap: () => _go(const KeysScreen())),
          _MenuRow(icon: Icons.account_balance_wallet_rounded, label: 'Пополнить баланс', onTap: () => _go(const TopUpScreen())),
          _MenuRow(icon: Icons.shopping_bag_rounded, label: 'Купить ключ / тарифы', onTap: () => _go(const PlansScreen())),
          _MenuRow(icon: Icons.public_rounded, label: 'Серверы', onTap: () => _go(const ServersScreen())),
          _MenuRow(icon: Icons.call_split_rounded, label: 'Split-туннелирование', onTap: () => _go(const SplitTunnelScreen())),
          _MenuRow(icon: Icons.card_giftcard_rounded, label: 'Бесплатный период', onTap: _activateTrial),
          _MenuRow(icon: Icons.group_rounded, label: 'Реферальная программа', onTap: () => _go(const ReferralScreen())),
          _MenuRow(icon: Icons.security_rounded, label: 'Безопасность (Kill Switch, DNS)', onTap: () => _go(const SecurityScreen())),
          _MenuRow(icon: Icons.settings_rounded, label: 'Настройки', onTap: () => _go(SettingsScreen(onLoggedOut: widget.onLoggedOut))),
          _MenuRow(icon: Icons.support_agent_rounded, label: 'Поддержка и контакты', onTap: () => _go(const SupportScreen())),
          const SizedBox(height: 16),
          Center(
            child: OutlinedButton.icon(
              onPressed: _logout,
              icon: const Icon(Icons.logout_rounded, size: 16, color: AppColors.danger),
              label: const Text('Выйти из аккаунта', style: TextStyle(color: AppColors.danger, fontSize: 12)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.danger),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label, required this.onTap, this.danger = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
          child: Row(
            children: [
              RingIconBadge(icon: icon, danger: danger, size: 40),
              const SizedBox(width: 12),
              Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
              const Icon(Icons.chevron_right_rounded, color: AppColors.textDim, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}
