import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';
import '../services/local_prefs.dart';
import '../services/tunnel_service.dart';
import '../services/locale_service.dart';
import '../l10n/app_language.dart';

/// Настройки — сведено по SCREEN 7 макета (.settings-row + .toggle).
///
/// [ИСПРАВЛЕНО] Раньше все три тумблера были обычным `bool` полем State —
/// значение "забывалось" при выходе с экрана и при перезапуске приложения
/// (подробный разбор причины — см. services/local_prefs.dart). Теперь
/// каждый тумблер читает стартовое значение из `LocalPrefs` при открытии
/// экрана и сразу пишет туда же при каждом переключении — значение
/// переживает и уход с экрана, и полный перезапуск приложения.
///
/// [ИСПРАВЛЕНО] Кнопка "Выйти из аккаунта" была `onPressed: () {}` —
/// не делала вообще ничего. Теперь реально чистит токен и возвращает на
/// экран входа (тот же путь, что и кнопка выхода в MenuScreen).
///
/// [ИСПРАВЛЕНО] Все три тумблера из предупреждения внизу экрана ("Автопод-
/// ключение при запуске", "Умное подключение на Wi-Fi", Kill Switch) теперь
/// реально работают, а не только сохраняют значение:
///  - Kill Switch — переподключение туннеля при обрыве уже было реализовано
///    в tunnel_service.dart.
///  - "Автоподключение при запуске" уже было реализовано в
///    connect_screen.dart (_loadKeyState) — при старте приложения реально
///    поднимает туннель, если тумблер включён и есть ключ.
///  - "Умное подключение на Wi-Fi" раньше было чисто декоративным — теперь
///    connect_screen.dart слушает смену сети через connectivity_plus и при
///    переходе на Wi-Fi запускает подключение (см. _onConnectivityChanged).
///    Честное ограничение: ОС не даёт приложению отличить "публичный" Wi-Fi
///    от домашнего/рабочего без спецправ, поэтому срабатывает на любой Wi-Fi.
///
/// [ИСПРАВЛЕНО] Выключение Kill Switch отсюда не сбрасывало "Строгий режим"
/// (тумблер на экране "Безопасность", тот же persist-ключ security_screen
/// требует для себя, что строгий режим не бывает включён без обычного Kill
/// Switch) — теперь оба экрана сбрасывают строгий режим одинаково, см.
/// _setKillSwitch ниже.
///
/// [НОВОЕ] У каждого пункта настроек теперь есть короткая подсказка под
/// названием — что конкретно делает переключатель и когда применяется
/// (сразу или при следующем подключении), а не только три общих
/// предупреждения одним блоком внизу экрана.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.onLoggedOut});
  final VoidCallback onLoggedOut;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _prefs = LocalPrefs.instance;

  // [ИЗМЕНЕНО] Дефолты подогнаны под макет: автоподключение/Kill Switch/
  // режим прокси — выключены; Умное подключение на публичном Wi-Fi и Обход
  // DPI — включены по умолчанию.
  bool _autoConnect = false;
  bool _smartWifi = true;
  bool _killSwitch = false;
  // [НОВОЕ] Не показывается на этом экране отдельным пунктом (сам тумблер
  // строгого режима живёт на экране "Безопасность"), но нужен здесь, чтобы
  // при выключении Kill Switch с этого экрана можно было честно сбросить
  // и его — см. _setKillSwitch ниже.
  bool _strictKillSwitch = false;
  bool _dpiBypass = true;
  bool _proxyOnly = false;
  // [НОВОЕ] Выбор DNS-over-HTTPS резолвера. Реально прокидывается в конфиг
  // sing-box через TunnelService.connect()/_buildSingBoxConfig, а не
  // просто хранится "для галочки" — см. tunnel_service.dart.
  String _dnsProvider = 'cloudflare';
  // [НОВОЕ] Свой DNS-сервер (см. PrefKeys.customDnsServer) — как "Custom DNS"
  // в Hiddify. Используется, когда _dnsProvider == 'custom'.
  final _customDnsController = TextEditingController();
  // [НОВОЕ] Разрешить IPv6 в туннеле — см. PrefKeys.ipv6Enabled и
  // подробный докстринг в tunnel_service.dart::_buildSingBoxConfig.
  bool _ipv6Enabled = false;
  bool _loaded = false;

  static const _dnsProviderLabels = {
    'cloudflare': 'Cloudflare (1.1.1.1)',
    'google': 'Google (8.8.8.8)',
    'adguard': 'AdGuard (94.140.14.14)',
    'quad9': 'Quad9 (9.9.9.9)',
    'custom': 'Свой DNS…',
  };

  @override
  void dispose() {
    _customDnsController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _prefs.getBool(PrefKeys.autoConnect, fallback: false),
      _prefs.getBool(PrefKeys.smartWifi, fallback: true),
      _prefs.getBool(PrefKeys.killSwitch, fallback: false),
      // [ИЗМЕНЕНО] fallback приведён в соответствие с макетом — включено
      // по умолчанию (совпадает со стартовым полем _dpiBypass выше).
      _prefs.getBool(PrefKeys.dpiBypass, fallback: true),
      _prefs.getBool(PrefKeys.proxyOnlyMode, fallback: false),
      _prefs.getBool(PrefKeys.ipv6Enabled, fallback: false),
      // [НОВОЕ] См. поле _strictKillSwitch выше — нужно знать текущее
      // значение до первого переключения Kill Switch на этом экране.
      _prefs.getBool(PrefKeys.strictKillSwitch, fallback: false),
    ]);
    final savedDnsProvider = await _prefs.getString(PrefKeys.dnsServerProvider);
    final savedCustomDns = await _prefs.getString(PrefKeys.customDnsServer);
    if (!mounted) return;
    setState(() {
      _autoConnect = results[0];
      _smartWifi = results[1];
      _killSwitch = results[2];
      _dpiBypass = results[3];
      _proxyOnly = results[4];
      _ipv6Enabled = results[5];
      _strictKillSwitch = results[6];
      _dnsProvider = (savedDnsProvider != null && _dnsProviderLabels.containsKey(savedDnsProvider))
          ? savedDnsProvider
          : 'cloudflare';
      _customDnsController.text = savedCustomDns ?? '';
      _loaded = true;
    });
  }

  // [НОВОЕ] Обход DPI — реальная настройка (см. tunnel_service.dart ->
  // _hardenConfig -> sockopt.fragment), не декоративный тумблер. Влияет
  // только на СЛЕДУЮЩЕЕ подключение — на уже поднятый туннель повлиять
  // нельзя, поэтому если турннель сейчас активен, честно предупреждаем,
  // что нужно переподключиться, а не создаём иллюзию мгновенного эффекта.
  Future<void> _setDpiBypass(bool v) async {
    setState(() => _dpiBypass = v);
    await _prefs.setBool(PrefKeys.dpiBypass, v);
    if (mounted && TunnelService.instance.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Изменение применится при следующем подключении — переподключись, чтобы включить сейчас'))),
      );
    }
  }

  Future<void> _setAutoConnect(bool v) async {
    setState(() => _autoConnect = v);
    await _prefs.setBool(PrefKeys.autoConnect, v);
  }

  // [НОВОЕ] "Режим прокси" — переключает флаттеровский пакет между
  // NetworkMode.vpn (системный туннель, как сейчас) и NetworkMode.proxy
  // (только локальные SOCKS5+HTTP порты на 127.0.0.1:2080, БЕЗ запроса
  // VPN-разрешения — подтверждено официальным README flutter_singbox_client:
  // "Use NetworkMode.proxy when you only need HTTP/SOCKS proxy ports
  // without requesting VPN permission").
  //
  // [ЧЕСТНО] Это НЕ системный прокси на весь телефон — Android не даёт
  // обычному приложению (без прав администратора устройства) незаметно
  // подменить прокси во всех сетевых настройках. Это локальный порт,
  // который нужно вручную указать в конкретном приложении/браузере,
  // умеющем работать через SOCKS5/HTTP-прокси. Kill Switch и
  // split-tunneling (эксклюзия приложений) физически не могут работать в
  // этом режиме — они завязаны на системный VPN-интерфейс, которого тут
  // нет, поэтому тумблер отключает их несовместимость честно, а не молча.
  Future<void> _setProxyOnly(bool v) async {
    setState(() => _proxyOnly = v);
    await _prefs.setBool(PrefKeys.proxyOnlyMode, v);
    if (mounted && TunnelService.instance.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Применится при следующем подключении — переподключись, чтобы сменить режим сейчас'))),
      );
    }
  }

  Future<void> _setSmartWifi(bool v) async {
    setState(() => _smartWifi = v);
    await _prefs.setBool(PrefKeys.smartWifi, v);
  }

  /// [НОВОЕ] Реальная настройка — сохраняет провайдера DNS-over-HTTPS и
  /// применяется при следующем подключении (см. _buildSingBoxConfig в
  /// tunnel_service.dart). Если туннель сейчас активен, честно
  /// предупреждаем, что нужно переподключиться, а не создаём иллюзию
  /// мгновенного эффекта (та же логика, что у _setDpiBypass выше).
  Future<void> _setDnsProvider(String? v) async {
    if (v == null) return;
    setState(() => _dnsProvider = v);
    await _prefs.setString(PrefKeys.dnsServerProvider, v);
    if (mounted && TunnelService.instance.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Применится при следующем подключении — переподключись, чтобы сменить DNS сейчас'))),
      );
    }
  }

  /// [НОВОЕ] Сохраняет пользовательский DNS-адрес по мере ввода (когда
  /// выбран провайдер 'custom') — реально прокидывается в конфиг sing-box
  /// на следующем подключении, см. tunnel_service.dart::_buildSingBoxConfig
  /// (resolvedDnsServer).
  Future<void> _setCustomDnsServer(String v) async {
    await _prefs.setString(PrefKeys.customDnsServer, v);
    if (mounted && TunnelService.instance.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Применится при следующем подключении — переподключись, чтобы сменить DNS сейчас'))),
      );
    }
  }

  /// [НОВОЕ] IPv6 в туннеле — см. PrefKeys.ipv6Enabled.
  Future<void> _setIpv6Enabled(bool v) async {
    setState(() => _ipv6Enabled = v);
    await _prefs.setBool(PrefKeys.ipv6Enabled, v);
    if (mounted && TunnelService.instance.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Применится при следующем подключении — переподключись, чтобы включить сейчас'))),
      );
    }
  }

  // [ИСПРАВЛЕНО] Выключение Kill Switch отсюда не трогало
  // security.strict_kill_switch — если пользователь включал "Строгий
  // режим" на экране "Безопасность", а потом выключал обычный Kill Switch
  // здесь, в настройках, в хранилище оставалась пара killSwitch=false +
  // strictKillSwitch=true. TunnelService это не ломало (строгий режим
  // всё равно не запускается без обычного — см. tunnel_service.dart:435),
  // но при следующем открытии экрана "Безопасность" тумблер "Строгий
  // режим" показывался включённым вопреки собственному правилу этого же
  // экрана ("строгий режим не может быть включён без обычного Kill
  // Switch"). Теперь оба переключателя одного и того же экрана
  // "Безопасность" синхронизированы вне зависимости от того, с какого
  // экрана их меняли — см. security_screen.dart::_killSwitch onChanged.
  Future<void> _setKillSwitch(bool v) async {
    setState(() {
      _killSwitch = v;
      if (!v) _strictKillSwitch = false;
    });
    await _prefs.setBool(PrefKeys.killSwitch, v);
    if (!v) await _prefs.setBool(PrefKeys.strictKillSwitch, false);
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgCard,
        title: Text(tr('Очистить кэш?')),
        content: Text(
          tr('Локальные данные приложения (кэш серверов, избранное) будут удалены. '
          'Вход в аккаунт при этом сохранится.'),
          style: const TextStyle(color: AppColors.textDim, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Отмена'))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Очистить'))),
        ],
      ),
    );
    if (confirmed != true) return;
    // [НОВОЕ] Раньше пункт вообще ничего не делал (просто chevron без
    // onTap). Чистим только клиентский кэш-стейт (избранные сервера,
    // выбор split-tunnel) — токен входа НЕ трогаем, это не "выход",
    // а именно очистка локального кэша.
    await Future.wait([
      _prefs.setStringSet(PrefKeys.favoriteServers, {}),
      _prefs.setBool(PrefKeys.autoBalance, false),
      _prefs.setBoolMap(PrefKeys.splitTunnelBypass, {}),
    ]);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Кэш очищен'))),
      );
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgCard,
        title: Text(tr('Выйти из аккаунта?')),
        content: Text(tr('Тебе нужно будет снова войти по email и паролю.'),
            style: const TextStyle(color: AppColors.textDim, fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Отмена'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Выйти'), style: const TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ApiClient.instance.logout();
      widget.onLoggedOut();
    }
  }

  // [НОВОЕ] Модуль переводчика — кнопка "Язык". Раньше строка была просто
  // текстом ('Русский') без onTap — теперь открывает список языков из
  // AppLanguage (см. lib/l10n/app_language.dart) и переключает через
  // LocaleService.setLanguage. Список экрана перерисовывается сам —
  // build() ниже обёрнут в AnimatedBuilder, слушающий LocaleService.
  Future<void> _pickLanguage() async {
    final chosen = await showDialog<AppLanguage>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgCard,
        title: Text(tr('Язык')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final lang in AppLanguage.values)
              RadioListTile<AppLanguage>(
                value: lang,
                groupValue: LocaleService.instance.language,
                activeColor: AppColors.violet2,
                title: Text(lang.label),
                onChanged: (v) => Navigator.pop(context, v),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Отмена'))),
        ],
      ),
    );
    if (chosen != null) {
      await LocaleService.instance.setLanguage(chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    // [НОВОЕ] Модуль переводчика — этот экран слушает LocaleService
    // напрямую (а не только через глобальный AnimatedBuilder в main.dart),
    // потому что именно тут находится кнопка "Язык": пользователь должен
    // увидеть результат выбора мгновенно, на этом же экране, не выходя из
    // него — иначе после выбора языка строка "Язык" продолжала бы
    // показывать старое название до следующего открытия экрана.
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
              Text(tr('Настройки'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 10),
              if (!_loaded)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else ...[
                _SettingsRow(
                  label: tr('Автоподключение при запуске'),
                  hint: tr('Поднимает VPN сразу при открытии приложения, если уже есть сохранённый ключ'),
                  trailing: NeonToggle(value: _autoConnect, onChanged: _setAutoConnect),
                ),
                _SettingsRow(
                  label: tr('Умное подключение на публичном Wi-Fi'),
                  hint: tr('Включает VPN при переходе на любую Wi-Fi-сеть — ОС не даёт отличить '
                      'публичную от домашней без спецправ'),
                  trailing: NeonToggle(value: _smartWifi, onChanged: _setSmartWifi),
                ),
                _SettingsRow(
                  label: tr('Kill Switch'),
                  hint: tr('Автоматически переподключает туннель при обрыве связи. Тот же '
                      'переключатель, что и в разделе «Безопасность»'),
                  trailing: NeonToggle(value: _killSwitch, onChanged: _setKillSwitch),
                ),
                _SettingsRow(
                  label: tr('Обход DPI (фрагментация TLS)'),
                  hint: tr('Дробит первый TLS-пакет на части — помогает, если провайдер режет '
                      'Reality-соединения по сигнатуре. Применится при следующем подключении'),
                  trailing: NeonToggle(value: _dpiBypass, onChanged: _setDpiBypass),
                ),
                _SettingsRow(
                  label: tr('Режим прокси (без VPN-разрешения)'),
                  hint: tr('Локальный SOCKS5/HTTP-порт на телефоне вместо системного VPN — Kill '
                      'Switch и split-tunnel в этом режиме не работают'),
                  trailing: NeonToggle(value: _proxyOnly, onChanged: _setProxyOnly),
                ),
                if (_proxyOnly)
                  ValueListenableBuilder<String?>(
                    valueListenable: TunnelService.instance.localProxyAddress,
                    builder: (context, address, _) => Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Text(
                        address != null
                            ? '${tr('Активен:')} $address — ${tr('укажи этот адрес в настройках прокси нужного приложения')}'
                            : tr('Порт появится здесь после подключения (127.0.0.1:2080, SOCKS5 и HTTP)'),
                        style: const TextStyle(fontSize: 10, color: AppColors.textDim),
                      ),
                    ),
                  ),
                _SettingsRow(
                  label: tr('Язык'),
                  // [ИСПРАВЛЕНО] Раньше строка выглядела как настройка (с
                  // активным видом), но выбора языка в приложении не
                  // существовало — локализации в коде не было вообще, весь
                  // интерфейс жёстко на русском. Теперь кнопка реально
                  // работает — см. _pickLanguage выше и модуль переводчика
                  // в lib/l10n/ + lib/services/locale_service.dart.
                  hint: tr('Меняет язык интерфейса приложения'),
                  onTap: _pickLanguage,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(LocaleService.instance.language.label,
                          style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right_rounded, color: AppColors.textDim, size: 18),
                    ],
                  ),
                ),
                _SettingsRow(
                  label: tr('DNS-сервер'),
                  hint: tr('DNS-over-HTTPS резолвер для доменов внутри туннеля. Применится при '
                      'следующем подключении'),
                  trailing: DropdownButton<String>(
                    value: _dnsProvider,
                    underline: const SizedBox.shrink(),
                    dropdownColor: AppColors.bgCard,
                    style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                    items: _dnsProviderLabels.entries
                        .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                        .toList(),
                    onChanged: _setDnsProvider,
                  ),
                ),
                // [НОВОЕ] Поле для своего DNS-адреса, показывается только
                // когда выбран 'custom' в списке выше.
                if (_dnsProvider == 'custom')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: TextField(
                      controller: _customDnsController,
                      onChanged: _setCustomDnsServer,
                      style: const TextStyle(fontSize: 12, color: AppColors.text),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: tr('Например: 9.9.9.11'),
                        hintStyle: const TextStyle(color: AppColors.textDim, fontSize: 12),
                        filled: true,
                        fillColor: AppColors.bgCard,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: AppColors.border),
                        ),
                      ),
                    ),
                  ),
                // [НОВОЕ] IPv6 — см. _setIpv6Enabled выше.
                _SettingsRow(
                  label: tr('Разрешить IPv6 в туннеле'),
                  hint: tr('Пропускает IPv6-трафик через VPN в дополнение к IPv4. Применится при '
                      'следующем подключении'),
                  trailing: NeonToggle(value: _ipv6Enabled, onChanged: _setIpv6Enabled),
                ),
                _SettingsRow(
                  label: tr('Очистить кэш'),
                  hint: tr('Удаляет избранные серверы и локальный выбор split-туннелирования. '
                      'Вход в аккаунт сохранится'),
                  onTap: _clearCache,
                  trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textDim),
                ),
              ],
              const SizedBox(height: 22),
              Center(
                child: OutlinedButton.icon(
                  onPressed: _logout,
                  icon: const Icon(Icons.logout_rounded, size: 16, color: AppColors.danger),
                  label: Text(tr('Выйти из аккаунта'), style: const TextStyle(color: AppColors.danger, fontSize: 12)),
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
      ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  // [НОВОЕ] Необязательная подсказка под названием пункта — раньше у
  // строк на этом экране (в отличие от security_screen.dart) не было
  // никакого объяснения, что конкретно делает переключатель, только три
  // общих предупреждения внизу экрана. Теперь у каждого пункта — короткое
  // честное описание того, что он реально делает.
  const _SettingsRow({required this.label, required this.trailing, this.onTap, this.hint});
  final String label;
  final Widget trailing;
  final VoidCallback? onTap;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFF1A1230))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: const TextStyle(fontSize: 12)),
                  if (hint != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      hint!,
                      style: const TextStyle(fontSize: 10, color: AppColors.textDim, height: 1.3),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            trailing,
          ],
        ),
      ),
    );
  }
}