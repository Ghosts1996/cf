import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/local_prefs.dart';
import '../services/tunnel_service.dart';
import '../services/app_log_service.dart';
import 'logs_viewer_screen.dart';

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
/// [НОВОЕ] Набор пунктов расширен до уровня функционала Hiddify (по
/// согласованию с разработчиком): строгий Kill Switch (физическая
/// блокировка трафика, а не только авто-переподключение — см.
/// tunnel_service.dart::_engageHardKillSwitch), обход локальной сети (LAN),
/// мультиплексирование соединений (Mux) и Fake IP DNS. Каждый пункт реально
/// прокидывается в конфиг sing-box при следующем подключении — см.
/// TunnelService.connect()/_buildSingBoxConfig, никаких заглушек.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});
  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  final _prefs = LocalPrefs.instance;

  // [ИЗМЕНЕНО] Дефолты подогнаны под макет: Kill Switch/Строгий режим/Обход
  // LAN/Агрессивное переподключение — выключены; Защита от DNS-протечек,
  // Fake IP, Блокировка рекламы и Mux — включены по умолчанию (Mux с
  // протоколом SMux).
  bool _killSwitch = false;
  bool _strictKillSwitch = false;
  bool _dnsProtection = true;
  bool _blockAds = true;
  bool _bypassLan = false;
  bool _muxEnabled = true;
  String _muxProtocol = 'smux';
  bool _fakeIpDns = true;
  // [НОВОЕ] "Агрессивное переподключение" — настраиваемое число попыток
  // восстановления соединения. false = 3 попытки (мягко,
  // экономит батарею при долгом отсутствии сети), true = 8 попыток
  // (пытается дольше на нестабильных сетях). Реально читается
  // TunnelService.connect() при каждом подключении — см. tunnel_service.dart.
  bool _aggressiveReconnect = false;
  bool _loaded = false;

  // [НОВОЕ] Срок хранения локальных логов приложения — см.
  // services/app_log_service.dart и раздел "Хранение логов" ниже.
  int _logRetentionDays = AppLogService.defaultRetentionDays;

  static const _muxProtocolLabels = {
    'h2mux': 'H2Mux',
    'smux': 'SMux',
    'yamux': 'YAMux',
  };

  static const _logRetentionLabels = {
    1: '1 день',
    7: '7 дней',
    30: '30 дней',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      // [ИЗМЕНЕНО] fallback приведён в соответствие с макетом — те же
      // значения, что и в стартовых полях State выше, чтобы UI не
      // расходился с реальным конфигом при первом запуске (до того как
      // пользователь что-то сохранил в SharedPreferences).
      _prefs.getBool(PrefKeys.killSwitch, fallback: false),
      _prefs.getBool(PrefKeys.strictKillSwitch, fallback: false),
      _prefs.getBool(PrefKeys.dnsProtection, fallback: true),
      _prefs.getBool(PrefKeys.blockAds, fallback: true),
      _prefs.getInt(PrefKeys.reconnectAttempts, fallback: 3),
      _prefs.getBool(PrefKeys.bypassLan, fallback: false),
      _prefs.getBool(PrefKeys.muxEnabled, fallback: true),
      _prefs.getBool(PrefKeys.fakeIpDns, fallback: true),
    ]);
    final savedMuxProtocol = await _prefs.getString(PrefKeys.muxProtocol);
    // [НОВОЕ] Отдельным запросом, как и savedMuxProtocol выше — не трогает
    // типы/индексы в results, чтобы ничего не сломать в существующей
    // Future.wait-цепочке.
    final savedLogRetentionDays = await AppLogService.instance.getRetentionDays();
    if (!mounted) return;
    setState(() {
      _killSwitch = results[0] as bool;
      _strictKillSwitch = results[1] as bool;
      _dnsProtection = results[2] as bool;
      _blockAds = results[3] as bool;
      _aggressiveReconnect = (results[4] as int) > 3;
      _bypassLan = results[5] as bool;
      _muxEnabled = results[6] as bool;
      _fakeIpDns = results[7] as bool;
      _muxProtocol = (savedMuxProtocol != null && _muxProtocolLabels.containsKey(savedMuxProtocol))
          ? savedMuxProtocol
          : 'smux';
      _logRetentionDays = _logRetentionLabels.containsKey(savedLogRetentionDays)
          ? savedLogRetentionDays
          : AppLogService.defaultRetentionDays;
      _loaded = true;
    });
  }

  /// [НОВОЕ] Меняет срок хранения локальных логов — применяется сразу же к
  /// уже накопленным записям (см. AppLogService.setRetentionDays), а не
  /// только к новым.
  Future<void> _setLogRetentionDays(int? days) async {
    if (days == null) return;
    setState(() => _logRetentionDays = days);
    await AppLogService.instance.setRetentionDays(days);
  }

  /// [НОВОЕ] Кнопка "Удалить все логи" — с подтверждением, как и другие
  /// необратимые действия в приложении (см. "Выйти из аккаунта" в
  /// menu_screen.dart/settings_screen.dart, "Очистить кэш" в
  /// settings_screen.dart).
  Future<void> _deleteAllLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgCard,
        title: const Text('Удалить все логи?'),
        content: const Text(
          'Локальный журнал событий приложения (подключения, ошибки) будет удалён полностью. '
          'Действие необратимо.',
          style: TextStyle(color: AppColors.textDim, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await AppLogService.instance.clearAll();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Логи удалены')),
      );
    }
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

  /// [НОВОЕ] Строгий Kill Switch — см. подробный докстринг
  /// PrefKeys.strictKillSwitch и TunnelService._engageHardKillSwitch.
  /// Требует, чтобы обычный Kill Switch (переподключение) тоже был включён —
  /// строгий режим включается уже ПОСЛЕ того, как обычные попытки
  /// переподключения исчерпались, поэтому без базового тумблера ему просто
  /// нечего "продолжать".
  Future<void> _setStrictKillSwitch(bool v) async {
    if (v && !_killSwitch) {
      setState(() {
        _killSwitch = true;
        _strictKillSwitch = true;
      });
      await Future.wait([
        _prefs.setBool(PrefKeys.killSwitch, true),
        _prefs.setBool(PrefKeys.strictKillSwitch, true),
      ]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Kill Switch включён автоматически — строгий режим работает поверх него')),
        );
      }
      return;
    }
    setState(() => _strictKillSwitch = v);
    await _prefs.setBool(PrefKeys.strictKillSwitch, v);
  }

  Future<void> _setMuxEnabled(bool v) async {
    setState(() => _muxEnabled = v);
    await _prefs.setBool(PrefKeys.muxEnabled, v);
    _notifyReconnectNeeded();
  }

  Future<void> _setMuxProtocol(String? v) async {
    if (v == null) return;
    setState(() => _muxProtocol = v);
    await _prefs.setString(PrefKeys.muxProtocol, v);
    _notifyReconnectNeeded();
  }

  Future<void> _setBypassLan(bool v) async {
    setState(() => _bypassLan = v);
    await _prefs.setBool(PrefKeys.bypassLan, v);
    _notifyReconnectNeeded();
  }

  Future<void> _setFakeIpDns(bool v) async {
    setState(() => _fakeIpDns = v);
    await _prefs.setBool(PrefKeys.fakeIpDns, v);
    _notifyReconnectNeeded();
  }

  void _notifyReconnectNeeded() {
    if (!mounted || !TunnelService.instance.isConnected) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Применится при следующем подключении — переподключись, чтобы включить сейчас')),
    );
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
              else ...[
                // [НОВОЕ] Живой индикатор, когда строгий Kill Switch реально
                // держит трафик заблокированным прямо сейчас (см.
                // TunnelService.hardKillSwitchActive).
                ValueListenableBuilder<bool>(
                  valueListenable: TunnelService.instance.hardKillSwitchActive,
                  builder: (context, active, _) {
                    if (!active) return const SizedBox.shrink();
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.danger.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.block_rounded, size: 18, color: AppColors.danger),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Kill Switch активен: сервер недоступен, интернет физически заблокирован до восстановления туннеля',
                              style: TextStyle(fontSize: 11, color: AppColors.text, height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                NeonCard(
                  child: Column(
                    children: [
                      _Row(
                        icon: Icons.shield_rounded,
                        title: 'Kill Switch',
                        subtitle: 'Автоматически переподключает туннель при обрыве',
                        trailing: NeonToggle(
                          value: _killSwitch,
                          onChanged: (v) async {
                            setState(() {
                              _killSwitch = v;
                              if (!v) _strictKillSwitch = false;
                            });
                            await _prefs.setBool(PrefKeys.killSwitch, v);
                            if (!v) await _prefs.setBool(PrefKeys.strictKillSwitch, false);
                          },
                        ),
                      ),
                      const Divider(height: 20),
                      // [НОВОЕ] Настоящий Kill Switch как в Hiddify — не
                      // просто переподключение, а физическая блокировка
                      // трафика, когда переподключиться не вышло. См.
                      // tunnel_service.dart::_engageHardKillSwitch.
                      _Row(
                        icon: Icons.gpp_bad_rounded,
                        title: 'Строгий режим (блокировать трафик)',
                        subtitle: _strictKillSwitch
                            ? 'Если переподключиться не удалось — интернет физически блокируется'
                            : 'Выключено: при неудаче просто останется обычный интернет',
                        trailing: NeonToggle(
                          value: _strictKillSwitch,
                          onChanged: _setStrictKillSwitch,
                        ),
                      ),
                      const SizedBox(height: 10),
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
                                  'Дополнительно: включить блокировку без VPN на уровне системы Android',
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
                            _notifyReconnectNeeded();
                          },
                        ),
                      ),
                      const Divider(height: 20),
                      // [НОВОЕ] Fake IP — режим DNS-резолва, как в Hiddify.
                      _Row(
                        icon: Icons.alt_route_rounded,
                        title: 'Fake IP (DNS)',
                        subtitle: 'Резолв доменов через служебные адреса — быстрее и без утечки таймингов',
                        trailing: NeonToggle(value: _fakeIpDns, onChanged: _setFakeIpDns),
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
                            _notifyReconnectNeeded();
                          },
                        ),
                      ),
                      const Divider(height: 20),
                      // [ИСПРАВЛЕНО] Обход локальной сети (LAN) — по
                      // умолчанию выключено, включается вручную (как и все
                      // остальные тумблеры на этом экране).
                      _Row(
                        icon: Icons.lan_rounded,
                        title: 'Обход локальной сети',
                        subtitle: _bypassLan
                            ? 'Устройства в LAN (роутер, принтер, NAS) доступны напрямую'
                            : 'LAN тоже идёт через VPN — доступ к сети сервера',
                        trailing: NeonToggle(value: _bypassLan, onChanged: _setBypassLan),
                      ),
                      const Divider(height: 20),
                      // [НОВОЕ] Mux — мультиплексирование соединений.
                      _Row(
                        icon: Icons.merge_type_rounded,
                        title: 'Mux (мультиплексирование)',
                        subtitle: 'Несколько потоков через одно соединение — быстрее открытие сайтов',
                        trailing: NeonToggle(value: _muxEnabled, onChanged: _setMuxEnabled),
                      ),
                      if (_muxEnabled) ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            const SizedBox(width: 48),
                            const Text('Протокол:', style: TextStyle(fontSize: 11, color: AppColors.textDim)),
                            const Spacer(),
                            DropdownButton<String>(
                              value: _muxProtocol,
                              underline: const SizedBox.shrink(),
                              dropdownColor: AppColors.bgCard,
                              style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                              items: _muxProtocolLabels.entries
                                  .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                                  .toList(),
                              onChanged: _setMuxProtocol,
                            ),
                          ],
                        ),
                      ],
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
                // [НОВОЕ] Хранение логов — срок автоудаления (1/7/30 дней)
                // и ручное удаление всех записей. См. AppLogService.
                const SectionTitle('Хранение логов'),
                NeonCard(
                  child: Column(
                    children: [
                      _Row(
                        icon: Icons.auto_delete_rounded,
                        title: 'Срок хранения логов',
                        subtitle:
                            'Записи старше срока (${_logRetentionLabels[_logRetentionDays]}) удаляются автоматически',
                        trailing: DropdownButton<int>(
                          value: _logRetentionDays,
                          underline: const SizedBox.shrink(),
                          dropdownColor: AppColors.bgCard,
                          style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                          items: _logRetentionLabels.entries
                              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                              .toList(),
                          onChanged: _setLogRetentionDays,
                        ),
                      ),
                      const Divider(height: 20),
                      _Row(
                        icon: Icons.summarize_rounded,
                        title: 'Сохранено записей',
                        subtitle: 'События подключения и ошибки за выбранный период',
                        trailing: ValueListenableBuilder<int>(
                          valueListenable: AppLogService.instance.entryCount,
                          builder: (context, count, _) => Text(
                            '$count',
                            style: orbitron(fontSize: 14, color: AppColors.violetGlow),
                          ),
                        ),
                      ),
                      const Divider(height: 20),
                      // [НОВОЕ] Кнопка "Просмотреть логи" — ведёт на
                      // LogsViewerScreen, который читает те же записи через
                      // AppLogService.instance.getAll() и показывает их
                      // списком в стиле остальных экранов приложения.
                      Center(
                        child: PillButton(
                          label: 'Просмотреть логи',
                          icon: '🗒️',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const LogsViewerScreen()),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Center(
                        child: OutlinedButton.icon(
                          onPressed: _deleteAllLogs,
                          icon: const Icon(Icons.delete_forever_rounded, size: 16, color: AppColors.danger),
                          label: const Text('Удалить все логи',
                              style: TextStyle(color: AppColors.danger, fontSize: 12)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: AppColors.danger),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
                ),
                child: const Text(
                  'На Android эти переключатели реально влияют на трафик: DNS-защита, Fake IP, обход LAN, '
                  'Mux и блокировка рекламы встроены в конфиг туннеля при следующем подключении, Kill Switch — '
                  'это автовосстановление соединения, а строгий режим — физическая блокировка трафика, если '
                  'восстановиться не удалось. На платформах без нативного VPN-туннеля (см. NATIVE_SETUP.md) '
                  'выбор сохраняется, но пока ни на что не влияет.',
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