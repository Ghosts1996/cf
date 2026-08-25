import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';
import 'topup_screen.dart';

/// Экран оформления подписки.
///
/// [ИСПРАВЛЕНО — архитектурная ошибка, не только вид]
/// Предыдущая версия давала выбрать "способ оплаты" (ЮKassa/CryptoBot)
/// прямо на этом экране и передавала его в несуществующий /orders.
/// В реальном API (`api.py`) покупка/продление ключа (`/key/create`,
/// `/key/extend`) вообще не принимает способ оплаты — они просто проверяют
/// и атомарно списывают БАЛАНС аккаунта. Способ оплаты (ЮKassa/CryptoBot)
/// нужен только на отдельном шаге — пополнении баланса (`/billing/topup`).
/// Поэтому: если баланса хватает — кнопка сразу выдаёт ключ; если не
/// хватает — показываем понятную ошибку и предлагаем пополнить баланс, а
/// не тихо ведём на несуществующий платёж.
///
/// Раньше также не было разницы между "купить новый ключ" и "продлить
/// существующий" — теперь это разные вызовы API (`createKey` /
/// `extendKey`), выбираемые параметром [extendKeyId].
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
      // [ИСПРАВЛЕНО] Проверка `mounted` после `await` — без неё уход с
      // экрана до ответа `/plans` приводил к падению `setState()` на уже
      // отключённом виджете.
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
      // [ИСПРАВЛЕНО] Не было проверки `mounted` после `await` — уход с
      // экрана (Navigator.pop) до ответа `/plans` приводил к падению
      // "setState() called after dispose()", особенно на медленной сети.
      if (!mounted) return;
      setState(() { _error = e.message; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Не удалось загрузить тарифы: $e'; _loading = false; });
    }
  }

  // [ИСПРАВЛЕНО] Поле `months` в реальном тарифе (`plans.months` в БД,
  // `/plans` в api.py) называется "months", но фактически используется
  // бэкендом как ДНИ — проверено по самому коду начисления:
  // `api.py` -> `api_create_key()`:
  //   expiry_ms = int((datetime.now().timestamp() + (months * 86400)) * 1000)
  // 86400 — число секунд В ОДНИХ СУТКАХ, не в месяце (было бы ~2 592 000
  // для 30-дневного месяца). То же самое в `api_extend_key()`:
  //   new_expiry = current_expiry + timedelta(days=months)
  // — `months` передаётся именно в параметр `days=`. Название поля в БД
  // вводит в заблуждение (это исторический артефакт схемы), но по факту
  // тариф "7" — это 7 ДНЕЙ, а не 7 месяцев. Здесь это никак не лечится —
  // сама схема/имя колонки `plans.months` не менялись (это уже правка
  // бэкенда, не приложения, и она никак не влияла бы на уже проданные
  // тарифы с их текущими значениями), поменяно только подписанное на
  // экране слово, чтобы оно совпадало с реальным смыслом числа.
  String _pluralDays(int n) {
    final mod100 = n % 100;
    final mod10 = n % 10;
    if (mod100 >= 11 && mod100 <= 14) return 'дней';
    if (mod10 == 1) return 'день';
    if (mod10 >= 2 && mod10 <= 4) return 'дня';
    return 'дней';
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
          SnackBar(content: Text(_isExtend ? 'Ключ продлён' : 'Ключ выдан — смотри вкладку «Ключи»')),
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
                    label: 'Пополнить',
                    // [ИСПРАВЛЕНО] pushNamed('/topup') вёл на несуществующий
                    // именованный маршрут — крэш при нажатии. Ведём на
                    // реальный TopUpScreen (см. topup_screen.dart).
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
          SnackBar(content: Text('Не удалось оформить: $e'), backgroundColor: AppColors.danger),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // [ИСПРАВЛЕНО] PlansScreen открывается ТОЛЬКО как отдельный
    // MaterialPageRoute (с ConnectScreen, KeysScreen, BalanceScreen,
    // MenuScreen) и никогда не встроен во вкладку с готовым Scaffold —
    // без своего Scaffold текст вне NeonCard попадал под аварийный
    // DefaultTextStyle Flutter с жёлтым двойным подчёркиванием
    // (нет Material-предка). См. тот же паттерн в servers_screen.dart.
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppHeader(screenLabel: _isExtend ? 'Продление ключа' : 'Оформление подписки'),
          const Text(
            'Единый VPN-ключ даёт доступ ко всем локациям сразу — выбирать сервер не нужно. '
            'Оплата — с баланса аккаунта.',
            style: TextStyle(color: AppColors.textDim, fontSize: 11),
          ),
          // [ИСПРАВЛЕНО] Раньше здесь не было отступа вообще — карточки
          // тарифов рисовались вплотную к описанию сверху и на некоторых
          // экранах/масштабах шрифта визуально наезжали на последнюю
          // строку текста.
          const SizedBox(height: 18),
          if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(child: Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 12))),
                  TextButton(onPressed: _load, child: const Text('Повторить')),
                ],
              ),
            ),
          if (_plans != null && _plans!.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('Тарифы пока не настроены в панели бота (нет тарифов для host "GLOBAL").',
                  style: TextStyle(color: AppColors.textDim)),
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
                          ? 'Продлить — ${(_plans![_selected] as Map<String, dynamic>)['price']} ₽'
                          : 'Получить ключ — ${(_plans![_selected] as Map<String, dynamic>)['price']} ₽',
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
              Text('≈ ${perDay.toStringAsFixed(0)} ₽ / день',
                  style: const TextStyle(fontSize: 10, color: AppColors.textDim)),
            ],
          ),
          Text('${plan['price']}', style: orbitron(fontSize: 16, color: AppColors.violetGlow)),
        ],
      ),
    );
  }
}