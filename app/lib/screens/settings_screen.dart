import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';
import '../services/local_prefs.dart';
import '../services/tunnel_service.dart';

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
/// ДОПУЩЕНИЕ (честно): Kill Switch и "умное подключение на Wi-Fi" сами по
/// себе — предпочтения пользователя, реальная защита на уровне ОС
/// подключается на стороне tunnel_service.dart при старте туннеля (см.
/// NATIVE_SETUP.md) — сохранение выбора здесь уже полностью рабочее,
/// связка с самим VPN-сервисом отдельный следующий шаг.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.onLoggedOut});
  final VoidCallback onLoggedOut;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _prefs = LocalPrefs.instance;

  bool _autoConnect = true;
  bool _smartWifi = true;
  bool _killSwitch = true;
  bool _dpiBypass = false;
  bool _proxyOnly = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _prefs.getBool(PrefKeys.autoConnect, fallback: true),
      _prefs.getBool(PrefKeys.smartWifi, fallback: true),
      _prefs.getBool(PrefKeys.killSwitch, fallback: true),
      // [ИСПРАВЛЕНО] По умолчанию выключено — пользователь включает сам
      // при необходимости (совпадает с fallback в tunnel_service.dart).
      _prefs.getBool(PrefKeys.dpiBypass, fallback: false),
      _prefs.getBool(PrefKeys.proxyOnlyMode, fallback: false),
    ]);
    if (!mounted) return;
    setState(() {
      _autoConnect = results[0];
      _smartWifi = results[1];
      _killSwitch = results[2];
      _dpiBypass = results[3];
      _proxyOnly = results[4];
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
        const SnackBar(content: Text('Изменение применится при следующем подключении — переподключись, чтобы включить сейчас')),
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
        const SnackBar(content: Text('Применится при следующем подключении — переподключись, чтобы сменить режим сейчас')),
      );
    }
  }

  Future<void> _setSmartWifi(bool v) async {
    setState(() => _smartWifi = v);
    await _prefs.setBool(PrefKeys.smartWifi, v);
  }

  Future<void> _setKillSwitch(bool v) async {
    setState(() => _killSwitch = v);
    await _prefs.setBool(PrefKeys.killSwitch, v);
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgCard,
        title: const Text('Очистить кэш?'),
        content: const Text(
          'Локальные данные приложения (кэш серверов, избранное) будут удалены. '
          'Вход в аккаунт при этом сохранится.',
          style: TextStyle(color: AppColors.textDim, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Очистить')),
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
        const SnackBar(content: Text('Кэш очищен')),
      );
    }
  }

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
      await ApiClient.instance.logout();
      widget.onLoggedOut();
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
              const Text('Настройки', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 10),
              if (!_loaded)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else ...[
                _SettingsRow(
                  label: 'Автоподключение при запуске',
                  trailing: NeonToggle(value: _autoConnect, onChanged: _setAutoConnect),
                ),
                _SettingsRow(
                  label: 'Умное подключение на публичном Wi-Fi',
                  trailing: NeonToggle(value: _smartWifi, onChanged: _setSmartWifi),
                ),
                _SettingsRow(
                  label: 'Kill Switch',
                  trailing: NeonToggle(value: _killSwitch, onChanged: _setKillSwitch),
                ),
                _SettingsRow(
                  label: 'Обход DPI (фрагментация TLS)',
                  trailing: NeonToggle(value: _dpiBypass, onChanged: _setDpiBypass),
                ),
                _SettingsRow(
                  label: 'Режим прокси (без VPN-разрешения)',
                  trailing: NeonToggle(value: _proxyOnly, onChanged: _setProxyOnly),
                ),
                if (_proxyOnly)
                  ValueListenableBuilder<String?>(
                    valueListenable: TunnelService.instance.localProxyAddress,
                    builder: (context, address, _) => Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Text(
                        address != null
                            ? 'Активен: $address — укажи этот адрес в настройках прокси нужного приложения'
                            : 'Порт появится здесь после подключения (127.0.0.1:2080, SOCKS5 и HTTP)',
                        style: const TextStyle(fontSize: 10, color: AppColors.textDim),
                      ),
                    ),
                  ),
                _SettingsRow(
                  label: 'Язык',
                  trailing: const Text('Русский', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
                ),
                _SettingsRow(
                  label: 'Очистить кэш',
                  onTap: _clearCache,
                  trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textDim),
                ),
              ],
              const SizedBox(height: 8),
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
                ),
                child: const Text(
                  'На Android Kill Switch реально переподключает туннель при обрыве, а "умное подключение на '
                  'Wi-Fi" и "автоподключение при запуске" пока только сохраняют твой выбор — сама логика '
                  'автозапуска на этих событиях ОС ещё не подключена. На платформах без нативного VPN-туннеля '
                  '(см. NATIVE_SETUP.md) все три пункта пока только сохраняют выбор.',
                  style: TextStyle(fontSize: 11, color: AppColors.textDim, height: 1.4),
                ),
              ),
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.violet2.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.violet2.withValues(alpha: 0.3)),
                ),
                child: const Text(
                  'Разбивает первый TLS-пакет соединения на несколько мелких частей — помогает, если '
                  'провайдер режет именно Reality-соединения по сигнатуре. Не поможет, если блокировка '
                  'идёт по IP-адресу сервера, и немного увеличивает время установки соединения — включай, '
                  'если обычное подключение не проходит или регулярно рвётся.',
                  style: TextStyle(fontSize: 11, color: AppColors.textDim, height: 1.4),
                ),
              ),
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.violet2.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.violet2.withValues(alpha: 0.3)),
                ),
                child: const Text(
                  'Режим прокси НЕ подменяет прокси во всей системе — Android не даёт обычному приложению '
                  'сделать это незаметно. Это локальный SOCKS5/HTTP-порт на телефоне, который нужно вручную '
                  'указать в настройках конкретного приложения или браузера. VPN-разрешение при этом не '
                  'запрашивается. Kill Switch и обход по приложениям (split-tunnel) в этом режиме не действуют — '
                  'они завязаны на системный VPN-интерфейс, которого тут нет.',
                  style: TextStyle(fontSize: 11, color: AppColors.textDim, height: 1.4),
                ),
              ),
              const SizedBox(height: 22),
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
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.label, required this.trailing, this.onTap});
  final String label;
  final Widget trailing;
  final VoidCallback? onTap;

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
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
            trailing,
          ],
        ),
      ),
    );
  }
}
