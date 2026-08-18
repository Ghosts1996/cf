import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';

/// Пополнение баланса — [НОВОЕ].
///
/// [ИСПРАВЛЕНО — реальная дыра в функционале, не косметика] `ApiClient`
/// уже содержал рабочий метод `billingTopup()` (POST /billing/topup,
/// реальный эндпоинт из api.py), но ни один экран его не вызывал: пункт
/// меню "Пополнить баланс" ошибочно вёл на PlansScreen — экран ПОКУПКИ
/// КЛЮЧА за баланс, а не пополнения самого баланса. Получалось, что
/// пополнить баланс в приложении было физически невозможно — только через
/// сайт/бота. Плюс `plans_screen.dart` вызывал несуществующий
/// `Navigator.pushNamed('/topup')` при ошибке "недостаточно средств" — тоже
/// приводило в никуда (крэш при нажатии). Оба места теперь ведут сюда.
class TopUpScreen extends StatefulWidget {
  const TopUpScreen({super.key});
  @override
  State<TopUpScreen> createState() => _TopUpScreenState();
}

class _TopUpScreenState extends State<TopUpScreen> {
  final _api = ApiClient.instance;
  final _amountCtrl = TextEditingController(text: '300');
  String _method = 'yookassa';
  bool _submitting = false;
  String? _error;

  static const _presets = [200.0, 500.0, 1000.0, 2000.0];

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  double? get _amount => double.tryParse(_amountCtrl.text.replaceAll(',', '.'));

  Future<void> _submit() async {
    final amount = _amount;
    if (amount == null || amount < 10) {
      setState(() => _error = 'Введи сумму от 10 ₽');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final payUrl = await _api.billingTopup(amount: amount, method: _method);
      final uri = Uri.parse(payUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Открыта страница оплаты — после оплаты баланс обновится автоматически')),
          );
          Navigator.of(context).pop();
        }
      } else if (mounted) {
        setState(() => _error = 'Не удалось открыть страницу оплаты');
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Не удалось создать платёж: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
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
              const Text('Пополнить баланс', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 14),
              NeonCard(
                child: TextField(
                  controller: _amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.text),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    suffixText: '₽',
                    suffixStyle: TextStyle(fontSize: 16, color: AppColors.textDim),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _presets
                    .map((p) => GestureDetector(
                          onTap: () => setState(() => _amountCtrl.text = p.toStringAsFixed(0)),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppColors.bgCard,
                              border: Border.all(color: AppColors.border),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text('${p.toStringAsFixed(0)} ₽', style: const TextStyle(fontSize: 12)),
                          ),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 18),
              const SectionTitle('Способ оплаты'),
              _PaymentOption(
                label: 'ЮKassa · СБП / карта',
                emoji: '₽',
                selected: _method == 'yookassa',
                onTap: () => setState(() => _method = 'yookassa'),
              ),
              const SizedBox(height: 8),
              _PaymentOption(
                label: 'CryptoBot',
                emoji: '₿',
                selected: _method == 'cryptobot',
                onTap: () => setState(() => _method = 'cryptobot'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
              ],
              const SizedBox(height: 20),
              Center(
                child: _submitting
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : PillButton(label: 'Пополнить', icon: '💳', filled: true, onTap: _submit),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaymentOption extends StatelessWidget {
  const _PaymentOption({required this.label, required this.emoji, required this.selected, required this.onTap});
  final String label;
  final String emoji;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return NeonCard(
      selected: selected,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.violet2),
            alignment: Alignment.center,
            child: Text(emoji, style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
          ),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          const Spacer(),
          if (selected) const Icon(Icons.check_circle_rounded, color: AppColors.violet2, size: 18),
        ],
      ),
    );
  }
}
