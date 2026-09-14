import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';
import '../services/locale_service.dart';

/// Реферальная программа.
///
/// Отдельного эндпоинта GET /referral на сервере нет — всё нужное отдаёт
/// `GET /user/profile` (api_client.dart -> getProfile()): `referral_link`,
/// `referral_count`, `referral_balance_all`. Проценты начисления сервер
/// клиенту не возвращает (они живут в bot_settings), поэтому конкретная
/// цифра в тексте не показывается.
class ReferralScreen extends StatefulWidget {
  const ReferralScreen({super.key});
  @override
  State<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends State<ReferralScreen> {
  final _api = ApiClient.instance;
  Map<String, dynamic>? _profile;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profile = await _api.getProfile();
      if (!mounted) return;
      setState(() => _profile = profile);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '${tr('Не удалось загрузить реферальные данные:')} $e');
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
              Text(tr('Реферальная программа'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              Text(
                tr('Приглашай друзей своей ссылкой — за их покупки на твой баланс начисляется бонус '
                '(процент настроен в боте, актуальную ставку уточняй в поддержке).'),
                style: const TextStyle(color: AppColors.textDim, fontSize: 12),
              ),
              const SizedBox(height: 16),
              if (_error != null)
                Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 12))
              else if (_profile == null)
                const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
              else ...[
                NeonCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr('Твоя ссылка'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0A0614),
                          border: Border.all(color: AppColors.border),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          _profile!['referral_link'] as String? ?? '—',
                          style: const TextStyle(color: AppColors.violetGlow, fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            final link = _profile!['referral_link'] as String?;
                            if (link == null) return;
                            Clipboard.setData(ClipboardData(text: link));
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(content: Text(tr('Ссылка скопирована'))));
                          },
                          icon: const Icon(Icons.copy_rounded, size: 16),
                          label: Text(tr('Скопировать')),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    StatMiniCard(label: tr('Приглашено'), value: '${_profile!['referral_count'] ?? 0}'),
                    const SizedBox(width: 10),
                    StatMiniCard(
                      label: tr('Заработано'),
                      value: '${_profile!['referral_balance_all'] ?? 0} ₽',
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      ),
    );
  }
}