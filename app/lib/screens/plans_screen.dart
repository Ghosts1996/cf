import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';
import '../services/locale_service.dart';
import 'topup_screen.dart';

/// Экран оформления подписки.
///
/// Способ оплаты здесь не выбирается: `/key/create` и `/key/extend` только
/// списывают баланс аккаунта. ЮKassa/CryptoBot нужны на отдельном шаге —
/// пополнении баланса (`/billing/topup`). Не хватает денег — показываем
/// ошибку и предлагаем пополнить.
///
/// Покупка нового ключа и продление существующего — разные вызовы API,
/// выбираются параметром [extendKeyId].
class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key, this.extendKeyId});

  /// Если задан — экран работает в режиме "продлить этот ключ"
  /// (`POST /key/extend`), иначе — "купить новый" (`POST /key/create`).
  final int? extendKeyId;

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  final _api = ApiClient.instance;
  List<dynamic>? _plans; // список тарифов из ключа "GLOBAL" в /plans
  int _selected = 0;
  String? _error;
  bool _loading = true;
  bool _submitting = false;

  bool get _isExtend => widget.extendKeyId != null;

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
      // Реальный /plans отдаёт Map<host_name, List<plan>>, а не плоский
      // список. "GLOBAL" — единый бандл-тариф на все локации сразу
      // (см. api.py: api_plans() и то, как /key/create всегда использует
      // host_name="GLOBAL").
      final plansByHost = await _api.getPlans();
      if (!mounted) return;
      final globalPlans = (plansByHost['GLOBAL'] as List<dynamic>?) ?? [];
      globalPlans.sort((a, b) =>
          ((a as Map<String, dynamic>)['months'] as num).compareTo((b as Map<String, dynamic>)['months'] as num));
      setState(() {
        _plans = globalPlans;
        _selected = globalPlans.length > 1 ? 1 : 0;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() { _error = e.message; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = '${tr('Не удалось загрузить тарифы:')} $e'; _loading = false; });
    }
  }

  // Поле `months` в тарифе на деле хранит ДНИ — так его считает бэкенд:
  //   api_create_key(): expiry_ms = ... + months * 86400
  //   api_extend_key(): new_expiry = current_expiry + timedelta(days=months)
  // 86400 — секунд в сутках, не в месяце. Имя колонки в БД историческое,
  // здесь подписываем число правильным словом.
  String _pluralDays(int n) {
    final mod100 = n % 100;
    final mod10 = n % 10;
    if (mod100 >= 11 && mod100 <= 14) return tr('дней');
    if (mod10 == 1) return tr('день');
    if (mod10 >= 2 && mod10 <= 4) return tr('дня');
    return tr('дней');
  }

  String _periodLabel(num days) {
    final d = days.toInt();
    return '$d ${_pluralDays(d)}';
  }

  double _pricePerDay(Map<String, dynamic> plan) {
    final price = (plan['price'] as num).toDouble();
    final days = (plan['months'] as num).toDouble();
    return days > 0 ? price / days : price;
  }

  Future<void> _submit() async {
    if (_plans == null || _plans!.isEmpty) return;
    final plan = _plans![_selected] as Map<String, dynamic>;
    final planId = (plan['plan_id'] as num).toInt();
    setState(() => _submitting = true);
    try {
      if (_isExtend) {
        await _api.extendKey(keyId: widget.extendKeyId!, planId: planId);
      } else {
        await _api.createKey(planId);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_isExtend ? tr('Ключ продлён') : tr('Ключ выдан — смотри вкладку «Ключи»'))),
        );
        Navigator.of(context).pop();
      }
    } on ApiException catch (e) {
      if (mounted) {
        final insufficientBalance = e.message.contains('Недостаточ');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message),
            backgroundColor: AppColors.danger,
            action: insufficientBalance
                ? SnackBarAction(
                    label: tr('Пополнить'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const TopUpScreen()),
                    ),
                  )
                : null,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${tr('Не удалось оформить:')} $e'), backgroundColor: AppColors.danger),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Свой Scaffold: экран открывается и отдельным MaterialPageRoute (из меню,
    // баланса, "Купить новый ключ"), где Material-предка иначе нет и текст
    // рисуется с аварийным жёлтым подчёркиванием. Внутри RootShell вложенный
    // Scaffold безопасен — AppBar тут не используется.
    return AnimatedBuilder(
      animation: LocaleService.instance,
      builder: (context, _) => Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppHeader(screenLabel: _isExtend ? tr('Продление ключа') : tr('Оформление подписки')),
          Text(
            tr('Единый VPN-ключ даёт доступ ко всем локациям сразу — выбирать сервер не нужно. '
            'Оплата — с баланса аккаунта.'),
            style: const TextStyle(color: AppColors.textDim, fontSize: 11),
          ),
          const SizedBox(height: 18),
          if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(child: Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 12))),
                  TextButton(onPressed: _load, child: Text(tr('Повторить'))),
                ],
              ),
            ),
          if (_plans != null && _plans!.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(tr('Тарифы пока не настроены в панели бота (нет тарифов для host "GLOBAL").'),
                  style: const TextStyle(color: AppColors.textDim)),
            ),
          if (_plans != null)
            for (var i = 0; i < _plans!.length; i++) ...[
              _PlanCard(
                plan: _plans![i] as Map<String, dynamic>,
                selected: _selected == i,
                periodLabel: _periodLabel((_plans![i] as Map<String, dynamic>)['months'] as num),
                perDay: _pricePerDay(_plans![i] as Map<String, dynamic>),
                onTap: () => setState(() => _selected = i),
              ),
              const SizedBox(height: 10),
            ],
          if (_plans != null && _plans!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Center(
              child: _submitting
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : PillButton(
                      label: _isExtend
                          ? '${tr('Продлить —')} ${(_plans![_selected] as Map<String, dynamic>)['price']} ₽'
                          : '${tr('Получить ключ —')} ${(_plans![_selected] as Map<String, dynamic>)['price']} ₽',
                      icon: '🔒',
                      filled: true,
                      onTap: _submit,
                    ),
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

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.selected,
    required this.periodLabel,
    required this.perDay,
    required this.onTap,
  });

  final Map<String, dynamic> plan;
  final bool selected;
  final String periodLabel;
  final double perDay;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return NeonCard(
      selected: selected,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(periodLabel, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              const SizedBox(height: 2),
              Text('≈ ${perDay.toStringAsFixed(0)} ₽ / ${tr('день')}',
                  style: const TextStyle(fontSize: 10, color: AppColors.textDim)),
            ],
          ),
          Text('${plan['price']}', style: orbitron(fontSize: 16, color: AppColors.violetGlow)),
        ],
      ),
    );
  }
}