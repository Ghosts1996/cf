import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';
import '../services/locale_service.dart';
import 'topup_screen.dart';
import 'plans_screen.dart';
import 'keys_screen.dart';

/// Экран «Баланс» в нижнем меню — [НОВОЕ].
///
/// [ИСПРАВЛЕНО] Раньше на месте пункта нижнего меню "Баланс" открывался
/// `PlansScreen` (покупка ключа за баланс), а не сам баланс. Пополнить
/// баланс из этого пункта было невозможно, а ошибка
/// "HandshakeException: Connection terminated during handshake" на
/// скриншоте — это просто сбой сети при попытке PlansScreen сразу
/// загрузить /plans при открытии вкладки. Теперь на этом месте — экран
/// баланса: сумма на счету, количество ключей (активных из общего числа),
/// кнопка "Пополнить баланс" (ведёт на уже существующий рабочий
/// `TopUpScreen` с ЮKassa/CryptoBot, см. topup_screen.dart) и отдельная
/// кнопка "Купить ключ" для тех, кто зашёл сюда именно за покупкой —
/// сама покупка (`PlansScreen`) никуда не делась, просто теперь она не
/// единственное, что показывает эта вкладка.
class BalanceScreen extends StatefulWidget {
  const BalanceScreen({super.key});

  @override
  State<BalanceScreen> createState() => _BalanceScreenState();
}

class _BalanceScreenState extends State<BalanceScreen> {
  final _api = ApiClient.instance;
  Map<String, dynamic>? _profile;
  List<dynamic>? _keys;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([_api.getProfile(), _api.getKeys()]);
      if (!mounted) return;
      setState(() {
        _profile = results[0] as Map<String, dynamic>;
        _keys = results[1] as List<dynamic>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Не даём "битой" загрузке молча оставлять старые данные висеть
        // без объяснения — на этом экране баланс это главное, что нужно
        // видеть точно, а не "что получилось".
        _error = e is ApiException ? e.message : tr('Не удалось загрузить баланс');
        _loading = false;
      });
    }
  }

  void _go(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    // Та же логика "активного" ключа, что и в menu_screen.dart —
    // реальный /user/keys не отдаёт отдельного флага активности, статус
    // определяется сроком действия.
    final keys = _keys?.cast<Map<String, dynamic>>();
    final activeKeys = keys?.where((k) {
      final expiryStr = k['expiry_date'] as String?;
      final expiry = expiryStr != null ? DateTime.tryParse(expiryStr) : null;
      return expiry != null && expiry.isAfter(DateTime.now());
    }).length;
    final totalKeys = keys?.length;

    final balanceRaw = _profile?['balance'];
    final balanceLabel = balanceRaw != null ? '$balanceRaw ₽' : '—';

    return AnimatedBuilder(
      animation: LocaleService.instance,
      builder: (context, _) => RefreshIndicator(
      onRefresh: _load,
      color: AppColors.violet2,
      backgroundColor: AppColors.bgCard,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppHeader(screenLabel: tr('Баланс')),
            if (_loading && _profile == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else ...[
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: NeonCard(
                    selected: true,
                    selectedColor: AppColors.danger,
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(_error!, style: const TextStyle(fontSize: 12, color: AppColors.text)),
                        ),
                        TextButton(onPressed: _load, child: Text(tr('Повторить'))),
                      ],
                    ),
                  ),
                ),
              // Крупная карточка баланса.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: AppColors.violetGradient,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: AppColors.glow(AppColors.violet2, blur: 20, alpha: 0.3),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('БАЛАНС АККАУНТА'),
                      style: const TextStyle(fontSize: 11, color: Colors.white70, letterSpacing: 1.5, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(balanceLabel, style: orbitron(fontSize: 34, color: Colors.white)),
                    const SizedBox(height: 4),
                    if (_profile?['email'] != null)
                      Text(
                        '${_profile!['email']}',
                        style: const TextStyle(fontSize: 11, color: Colors.white70),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  StatMiniCard(
                    label: tr('Активных ключей'),
                    value: activeKeys != null ? '$activeKeys' : '—',
                  ),
                  const SizedBox(width: 10),
                  StatMiniCard(
                    label: tr('Всего ключей'),
                    value: totalKeys != null ? '$totalKeys' : '—',
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Center(
                child: PillButton(
                  label: tr('Пополнить баланс'),
                  icon: '💳',
                  filled: true,
                  onTap: () => _go(const TopUpScreen()),
                ),
              ),
              const SizedBox(height: 10),
              Center(
                child: PillButton(
                  label: tr('Купить / продлить ключ'),
                  icon: '🔑',
                  onTap: () => _go(const PlansScreen()),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: TextButton(
                  onPressed: () => _go(const KeysScreen()),
                  child: Text(tr('Мои ключи'), style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
                ),
              ),
            ],
          ],
        ),
      ),
      ),
    );
  }
}