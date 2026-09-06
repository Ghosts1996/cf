import 'dart:async' show unawaited;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';
import '../services/locale_service.dart';
import 'topup_screen.dart';
import 'plans_screen.dart';
import 'keys_screen.dart';
import 'referral_screen.dart';

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
///
/// ─────────────────────────────────────────────────────────────────────
/// [РАСШИРЕНО] Экран показывал только сумму и две кнопки и выглядел
/// пустым. Добавлено то, ради чего пользователь сюда вообще заходит, и
/// СТРОГО на тех же двух запросах, что и раньше (`GET /user/profile` +
/// `GET /user/keys`) — ни одного нового обращения к серверу, чтобы не
/// утяжелять холодный старт (все пять вкладок монтируются сразу, см.
/// докстринг `_visited` в main.dart):
///
///  1. Состояние подписки: до какого числа действует ключ с наибольшим
///     остатком срока, сколько дней осталось, полоса остатка и кнопка
///     "Продлить". Она ведёт в тот же `PlansScreen`, но в режиме
///     продления КОНКРЕТНОГО ключа (`PlansScreen(extendKeyId: ...)` —
///     это уже существующий рабочий режим, см. plans_screen.dart), а не
///     покупки нового. Раньше продлить ключ можно было только с экрана
///     "Мои ключи", а с "Баланса" вообще не было видно, что подписка
///     заканчивается.
///  2. Предупреждение, когда до конца подписки осталось 3 дня и меньше —
///     самая частая причина обращения "у меня внезапно перестал работать
///     VPN".
///  3. Реферальный блок (ссылка + копирование + приглашено/заработано).
///     Поля `referral_link`, `referral_count`, `referral_balance_all`
///     приходят в ТОМ ЖЕ ответе `/user/profile`, который экран и так уже
///     запрашивает ради баланса — блок бесплатен по сети.
///  4. Обновление данных при возврате в приложение: пополнение уходит во
///     ВНЕШНИЙ браузер (ЮKassa/CryptoBot, см. topup_screen.dart), а сама
///     вкладка "Баланс" остаётся смонтированной в IndexedStack и после
///     возврата показывала старую сумму, пока пользователь не потянет
///     экран вниз вручную. Теперь баланс перечитывается сам.
///
/// Полей, которых нет в реальном API, здесь не выдумано: используются
/// только `balance`, `email`, `referral_link`, `referral_count`,
/// `referral_balance_all` из `/user/profile` и `key_id`, `expiry_date`,
/// `devices_limit` из `/user/keys` — ровно те же, что уже читают
/// menu_screen.dart, keys_screen.dart, referral_screen.dart и
/// connect_screen.dart.
class BalanceScreen extends StatefulWidget {
  const BalanceScreen({super.key});

  @override
  State<BalanceScreen> createState() => _BalanceScreenState();
}

class _BalanceScreenState extends State<BalanceScreen>
    with WidgetsBindingObserver {
  final _api = ApiClient.instance;
  Map<String, dynamic>? _profile;
  List<dynamic>? _keys;
  bool _loading = true;
  String? _error;
  // Когда данные на экране были в последний раз получены с сервера —
  // подпись под суммой. Без неё непонятно, актуальный это баланс или тот,
  // что загрузился при запуске приложения час назад.
  DateTime? _loadedAt;
  // [НОВОЕ] true, если на экране данные из локального кэша, а не свежий
  // ответ сервера. См. _restoreFromCache().
  bool _fromCache = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  /// [ИЗМЕНЕНО] Офлайн-копия профиля и ключей больше НЕ читается и не
  /// пишется здесь: этим занимается единый слой загрузки внутри
  /// `ApiClient` (см. подробный разбор в api_client.dart). Он же
  /// дедуплицирует `getProfile()`/`getKeys()`, которые этот экран
  /// отправляет одновременно с MenuScreen и ConnectScreen при холодном
  /// старте. Экрану остаётся показать, свежие данные или сохранённые.

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// См. пункт 4 в докстринге класса: оплата происходит во внешнем
  /// браузере, поэтому момент возврата в приложение — единственный
  /// надёжный сигнал "возможно, баланс уже изменился".
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) return;
    if (_loading) return;
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([_api.getProfile(), _api.getKeys()]);
      if (!mounted) return;
      final profile = results[0] as Map<String, dynamic>;
      final keys = results[1] as List<dynamic>;
      final servedFromCache = _api.profileFromCache || _api.keysFromCache;
      setState(() {
        _profile = profile;
        _keys = keys;
        _fromCache = servedFromCache;
        // Когда данные сохранённые, показываем момент их СОХРАНЕНИЯ, а не
        // текущее время — иначе подпись "обновлено в 19:40" врала бы о
        // свежести вчерашнего баланса.
        _loadedAt = servedFromCache
            ? (_api.profileUpdatedAt ?? _api.keysUpdatedAt ?? DateTime.now())
            : DateTime.now();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Не даём "битой" загрузке молча оставлять старые данные висеть
        // без объяснения — на этом экране баланс это главное, что нужно
        // видеть точно, а не "что получилось".
        // Если на экране уже есть сохранённые данные — это не авария, а
        // предупреждение: показываем мягкий текст вместо сырой сетевой
        // ошибки поверх нормально заполненного экрана.
        _error = _profile != null
            ? tr('Не удалось обновить — показаны сохранённые данные')
            : (e is ApiException ? e.message : tr('Не удалось загрузить баланс'));
        _loading = false;
      });
    }
  }

  void _go(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  /// Срок действия ключа. `null`, если поля нет или оно нечитаемо — тот же
  /// разбор, что в connect_screen.dart::_expiryOf и keys_screen.dart.
  DateTime? _expiryOf(Map<String, dynamic> key) {
    final expiryStr = key['expiry_date'] as String?;
    return expiryStr != null ? DateTime.tryParse(expiryStr) : null;
  }

  bool _isActive(Map<String, dynamic> key) {
    final expiry = _expiryOf(key);
    return expiry != null && expiry.isAfter(DateTime.now());
  }

  /// Сколько суток осталось, с округлением вверх: если до конца подписки
  /// 30 часов, честнее показать "2 дня", а не "1" (`inDays` отбросил бы
  /// остаток). Ноль означает "заканчивается сегодня".
  int _daysLeft(DateTime expiry) {
    final minutes = expiry.difference(DateTime.now()).inMinutes;
    if (minutes <= 0) return 0;
    return (minutes / (60 * 24)).ceil();
  }

  String _formatDate(DateTime value) {
    final d = value.day.toString().padLeft(2, '0');
    final m = value.month.toString().padLeft(2, '0');
    return '$d.$m.${value.year}';
  }

  String _formatTime(DateTime value) {
    final h = value.hour.toString().padLeft(2, '0');
    final m = value.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// Правильное русское окончание для числа дней — иначе на экране
  /// оказывается "осталось 3 дней" или "осталось 1 дней".
  String _daysWord(int days) {
    final hundredRemainder = days % 100;
    if (hundredRemainder >= 11 && hundredRemainder <= 14) return tr('дней');
    switch (days % 10) {
      case 1:
        return tr('день');
      case 2:
      case 3:
      case 4:
        return tr('дня');
      default:
        return tr('дней');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Та же логика "активного" ключа, что и в menu_screen.dart —
    // реальный /user/keys не отдаёт отдельного флага активности, статус
    // определяется сроком действия.
    final keys = _keys?.cast<Map<String, dynamic>>();
    final activeList = keys?.where(_isActive).toList();
    final activeKeys = activeList?.length;
    final totalKeys = keys?.length;

    // Ключ, который "держит" подписку дольше всех — тот же выбор, что
    // делает connect_screen.dart при подключении (там сортировка по
    // убыванию expiry_date и берётся первый). Показывать здесь другой
    // ключ было бы рассогласованием между экранами.
    Map<String, dynamic>? mainKey;
    DateTime? mainExpiry;
    if (activeList != null && activeList.isNotEmpty) {
      final sorted = [...activeList]..sort((a, b) {
          final ea = _expiryOf(a);
          final eb = _expiryOf(b);
          if (ea == null && eb == null) return 0;
          if (ea == null) return 1;
          if (eb == null) return -1;
          return eb.compareTo(ea);
        });
      mainKey = sorted.first;
      mainExpiry = _expiryOf(mainKey);
    }
    final mainKeyId = (mainKey?['key_id'] as num?)?.toInt();
    final mainDevicesLimit = (mainKey?['devices_limit'] as num?)?.toInt();
    // Считаем всё, что зависит от срока, ОДИН раз и здесь, а не внутри
    // дерева виджетов: так `mainExpiry` не приходится разыменовывать в
    // collection-if (промоушен локальной nullable-переменной там работает,
    // но полагаться на него незачем), и `_daysLeft()` не вызывается по
    // два раза подряд с чуть разным DateTime.now() — иначе число в бейдже
    // и слово-окончание рядом с ним теоретически могли разъехаться.
    final int? mainDaysLeft =
        mainExpiry != null ? _daysLeft(mainExpiry) : null;
    final String? mainExpiryLabel =
        mainExpiry != null ? _formatDate(mainExpiry) : null;

    final balanceRaw = _profile?['balance'];
    final balanceLabel = balanceRaw != null ? '$balanceRaw ₽' : '—';
    final referralLink = _profile?['referral_link'] as String?;

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
                    Row(
                      children: [
                        Text(
                          tr('БАЛАНС АККАУНТА'),
                          style: const TextStyle(fontSize: 11, color: Colors.white70, letterSpacing: 1.5, fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        // Маленький индикатор фонового обновления: данные
                        // на экране уже есть, но идёт повторная загрузка
                        // (потянули вниз или вернулись в приложение).
                        if (_loading)
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.6, color: Colors.white70),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(balanceLabel, style: orbitron(fontSize: 34, color: Colors.white)),
                    const SizedBox(height: 4),
                    if (_profile?['email'] != null)
                      Text(
                        '${_profile!['email']}',
                        style: const TextStyle(fontSize: 11, color: Colors.white70),
                      ),
                    if (_loadedAt != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        _fromCache
                            ? '${tr('сохранено в')} ${_formatTime(_loadedAt!)} · ${tr('данные могут быть неактуальны')}'
                            : '${tr('обновлено в')} ${_formatTime(_loadedAt!)}',
                        style: const TextStyle(fontSize: 10, color: Colors.white54),
                      ),
                    ],
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
                  const SizedBox(width: 10),
                  StatMiniCard(
                    label: tr('Устройств'),
                    value: mainDevicesLimit != null ? '$mainDevicesLimit' : '—',
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // ── Состояние подписки ────────────────────────────────────
              if (mainDaysLeft != null && mainExpiryLabel != null)
                _SubscriptionCard(
                  keyId: mainKeyId,
                  daysLeft: mainDaysLeft,
                  daysWord: _daysWord(mainDaysLeft),
                  expiryLabel: mainExpiryLabel,
                  onExtend: () => _go(PlansScreen(extendKeyId: mainKeyId)),
                )
              else if (_keys != null)
                NeonCard(
                  selected: true,
                  selectedColor: AppColors.danger,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.vpn_key_off_rounded, size: 18, color: AppColors.danger),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(tr('Нет активной подписки'),
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        tr('Чтобы подключиться к VPN, нужен действующий ключ. Один ключ работает сразу на всех локациях.'),
                        style: const TextStyle(fontSize: 11, color: AppColors.textDim, height: 1.4),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
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
              // ── Реферальная программа ─────────────────────────────────
              if (referralLink != null && referralLink.isNotEmpty) ...[
                SectionTitle(tr('Приглашай и зарабатывай')),
                NeonCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('За покупки приглашённых друзей бонус начисляется на твой баланс.'),
                        style: const TextStyle(fontSize: 11, color: AppColors.textDim, height: 1.4),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0A0614),
                          border: Border.all(color: AppColors.border),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          referralLink,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppColors.violetGlow, fontSize: 11),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: referralLink));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(tr('Ссылка скопирована'))),
                                );
                              },
                              icon: const Icon(Icons.copy_rounded, size: 15),
                              label: Text(tr('Скопировать'), style: const TextStyle(fontSize: 12)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _go(const ReferralScreen()),
                              icon: const Icon(Icons.groups_rounded, size: 15),
                              label: Text(tr('Подробнее'), style: const TextStyle(fontSize: 12)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          StatMiniCard(
                            label: tr('Приглашено'),
                            value: '${_profile!['referral_count'] ?? 0}',
                          ),
                          const SizedBox(width: 10),
                          StatMiniCard(
                            label: tr('Заработано'),
                            value: '${_profile!['referral_balance_all'] ?? 0} ₽',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
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

/// Карточка "сколько ещё работает подписка".
///
/// Полоса остатка намеренно считается от 30 дней, а не от реальной
/// длительности купленного тарифа: `/user/keys` отдаёт только
/// `expiry_date`, даты ПОКУПКИ там нет — значит настоящий процент
/// остатка вычислить не из чего, и придумывать его я не стал. 30 дней
/// здесь — это шкала, а не заявление о длительности тарифа: точное число
/// оставшихся дней всегда подписано рядом цифрой, поэтому полоса ничего
/// не искажает, а лишь даёт быстрый визуальный сигнал.
class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({
    required this.keyId,
    required this.daysLeft,
    required this.daysWord,
    required this.expiryLabel,
    required this.onExtend,
  });

  final int? keyId;
  final int daysLeft;
  final String daysWord;
  final String expiryLabel;
  final VoidCallback onExtend;

  static const _scaleDays = 30;

  @override
  Widget build(BuildContext context) {
    final expiringSoon = daysLeft <= 3;
    final accent = expiringSoon
        ? AppColors.danger
        : (daysLeft <= 7 ? AppColors.warning : AppColors.success);
    final progress = (daysLeft / _scaleDays).clamp(0.0, 1.0).toDouble();

    return NeonCard(
      selected: expiringSoon,
      selectedColor: AppColors.danger,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RingIconBadge(
                icon: Icons.workspace_premium_rounded,
                danger: expiringSoon,
                size: 34,
              ),  // не const: danger зависит от daysLeft
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      keyId != null ? '${tr('Подписка')} · ${tr('ключ')} #$keyId' : tr('Подписка'),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${tr('действует до')} $expiryLabel',
                      style: const TextStyle(fontSize: 11, color: AppColors.textDim),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              NeonBadge(
                daysLeft <= 0 ? tr('сегодня') : '$daysLeft $daysWord',
                color: accent,
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: const Color(0xFF1C1330),
              valueColor: AlwaysStoppedAnimation<Color>(accent),
            ),
          ),
          if (expiringSoon) ...[
            const SizedBox(height: 10),
            Text(
              daysLeft <= 0
                  ? tr('Подписка заканчивается сегодня — продли ключ, иначе VPN перестанет подключаться.')
                  : tr('Подписка скоро закончится — продли ключ заранее, чтобы VPN не отключился.'),
              style: const TextStyle(fontSize: 11, color: AppColors.danger, height: 1.4),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onExtend,
              child: Text(tr('Продлить этот ключ')),
            ),
          ),
        ],
      ),
    );
  }
}