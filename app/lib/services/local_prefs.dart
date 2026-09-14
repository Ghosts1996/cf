import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Обёртка над `shared_preferences` — единственное место, где живут
/// пользовательские настройки приложения.
///
/// Экраны не хранят состояние переключателей в полях State: такое поле
/// живёт, пока жив State-объект, и при уходе с экрана или перезапуске
/// приложения возвращается к значению по умолчанию. Здесь значения реально
/// пишутся на диск и читаются обратно при следующем открытии.
///
/// Сами по себе это только предпочтения — на трафик они влияют через
/// TunnelService.connect(), который читает их и собирает из них конфиг
/// sing-box (см. tunnel_service.dart).
class LocalPrefs {
  LocalPrefs._();
  static final LocalPrefs instance = LocalPrefs._();

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _sp async =>
      _prefs ??= await SharedPreferences.getInstance();

  // ── generic bool ──────────────────────────────────────────────────────
  Future<bool> getBool(String key, {bool fallback = false}) async {
    final sp = await _sp;
    return sp.getBool(key) ?? fallback;
  }

  Future<void> setBool(String key, bool value) async {
    final sp = await _sp;
    await sp.setBool(key, value);
  }

  /// Удаляет сохранённое значение — настройка возвращается к умолчанию из
  /// кода. Нужна разовым миграциям: иначе значение, записанное прошлой
  /// версией приложения, живёт на диске вечно и перекрывает новое умолчание.
  Future<void> remove(String key) async {
    final sp = await _sp;
    await sp.remove(key);
  }

  // ── generic int (например: количество попыток авто-переподключения) ──
  Future<int> getInt(String key, {int fallback = 0}) async {
    final sp = await _sp;
    return sp.getInt(key) ?? fallback;
  }

  Future<void> setInt(String key, int value) async {
    final sp = await _sp;
    await sp.setInt(key, value);
  }

  // ── generic string ────────────────────────────────────────────────────
  Future<String?> getString(String key) async {
    final sp = await _sp;
    return sp.getString(key);
  }

  Future<void> setString(String key, String value) async {
    final sp = await _sp;
    await sp.setString(key, value);
  }

  // ── string set (избранные сервера, package name-ы в обход VPN) ────────
  Future<Set<String>> getStringSet(String key) async {
    final sp = await _sp;
    return (sp.getStringList(key) ?? const []).toSet();
  }

  Future<void> setStringSet(String key, Set<String> value) async {
    final sp = await _sp;
    await sp.setStringList(key, value.toList());
  }

  // ── map<string,bool> (split-tunnel: packageName -> "в обход VPN") ─────
  Future<Map<String, bool>> getBoolMap(String key) async {
    final sp = await _sp;
    final raw = sp.getString(key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v == true));
    } catch (_) {
      return {};
    }
  }

  Future<void> setBoolMap(String key, Map<String, bool> value) async {
    final sp = await _sp;
    await sp.setString(key, jsonEncode(value));
  }
}

/// Ключи настроек — в одном месте, чтобы не разъезжались опечатками между
/// экранами (например 'kill_switch' в одном файле и 'killSwitch' в другом
/// незаметно создали бы ДВЕ независимые настройки вместо одной).
class PrefKeys {
  PrefKeys._();
  static const autoConnect = 'settings.auto_connect';
  // Момент старта работающего туннеля. Нужен, чтобы после пересоздания
  // Flutter Activity восстановить реальный счётчик сессии, если foreground
  // VpnService Android продолжал работать.
  static const tunnelConnectedAtMillis = 'vpn.tunnel_connected_at_millis';
  // JSON с тем, чем поднят текущий туннель: connection_string подписки,
  // предпочтённая локация и имя сервера, к которому реально подключились.
  // Пишется после успешного подключения, стирается в disconnect() —
  // см. TunnelService._persistSessionRoute().
  //
  // Нужен после перезапуска процесса приложения (свайп из списка задач при
  // работающем в фоне VpnService): без этих трёх значений на живом туннеле
  // не работают ни "Сменить сервер", ни авто-переподключение Kill Switch.
  //
  // Ссылка на подписку ложится на диск в открытом виде — как и ручной ключ
  // (manualConnectionString) с самого начала. Если это нежелательно, в
  // AndroidManifest.xml стоит выставить android:allowBackup="false": по
  // умолчанию содержимое SharedPreferences может уехать в облачный бэкап.
  static const tunnelSessionRouteJson = 'vpn.tunnel_session_route_json';
  static const smartWifi = 'settings.smart_wifi';
  static const killSwitch = 'settings.kill_switch';
  static const dnsProtection = 'settings.dns_protection';
  static const blockAds = 'settings.block_ads';
  static const dpiBypass = 'settings.dpi_bypass';
  // Переключает NetworkMode пакета flutter_singbox_client между 'vpn'
  // (системный туннель) и 'proxy' (локальные SOCKS/HTTP-порты без запроса
  // VPN-разрешения). См. tunnel_service.dart и settings_screen.dart.
  static const proxyOnlyMode = 'settings.proxy_only_mode';
  // Провайдер DNS-over-HTTPS для резолва внешних доменов внутри туннеля
  // (_buildSingBoxConfig). Одно из: 'cloudflare' | 'google' | 'adguard' |
  // 'quad9'.
  static const dnsServerProvider = 'settings.dns_server_provider';
  // Сколько раз подряд Kill Switch пытается восстановить туннель после
  // обрыва, прежде чем показать, что защита снята.
  static const reconnectAttempts = 'security.reconnect_attempts';
  static const favoriteServers = 'servers.favorites';
  static const autoBalance = 'servers.auto_balance';
  static const selectedServerId = 'servers.selected_id';
  static const splitTunnelBypass = 'split_tunnel.bypassed_packages';
  // 'exclude' — выбранные приложения идут в обход VPN, остальные через
  // туннель; 'include' — через VPN идут только выбранные. Читается в
  // tunnel_service.dart::_buildSingBoxConfig и переключает tun-инбаунд
  // между exclude_package и include_package.
  static const splitTunnelMode = 'split_tunnel.mode'; // 'exclude' | 'include'

  // ── Пункты экранов "Безопасность" и "Настройки" ──────────────────────

  // Строгий Kill Switch — не переподключение, а блокировка трафика. Когда
  // авто-переподключение исчерпало попытки (reconnectAttempts) и туннель так
  // и не поднялся, TunnelService поднимает служебную VPN-сессию с конфигом
  // route.final = 'block': системный маршрут остаётся захваченным, пока
  // пользователь не нажмёт "Отключить" или связь не восстановится.
  static const strictKillSwitch = 'security.strict_kill_switch';

  // Обход локальной сети (LAN). Выключено по умолчанию: весь трафик, включая
  // LAN, идёт через VPN. Когда включено — роутер, принтер, NAS и прочие
  // устройства сети видны напрямую. См. route.rules -> ip_is_private.
  static const bypassLan = 'security.bypass_lan';

  // Мультиплексирование (Mux) — несколько логических потоков поверх одного
  // TCP-соединения до сервера. Снижает задержку хендшейка, когда соединений
  // много сразу, но может просаживать пиковую скорость на быстрых каналах,
  // поэтому по умолчанию выключено. Уходит в outbound.multiplex.
  static const muxEnabled = 'security.mux_enabled';

  // Протокол мультиплексирования при muxEnabled == true:
  // 'h2mux' | 'smux' | 'yamux', по умолчанию h2mux.
  static const muxProtocol = 'security.mux_protocol';

  // Fake IP — домены резолвятся в адреса из служебного диапазона, а
  // настоящий домен подставляется обратно через sniffing. Помогает с
  // приложениями, которые агрессивно кешируют DNS, но те, что сами проверяют
  // валидность IP, могут вести себя странно — поэтому выключено по умолчанию.
  static const fakeIpDns = 'security.fake_ip_dns';

  // IPv6-трафик внутри туннеля. Выключено по умолчанию: ipv4_only чинил
  // реальный "0 МБ трафика" на части мобильных сетей, подробности в
  // tunnel_service.dart::_buildSingBoxConfig.
  static const ipv6Enabled = 'security.ipv6_enabled';

  // Разовая миграция совместимости. Мультиплексор, Fake IP и фрагментация
  // TLS какое-то время включались по умолчанию; с Xray-сервером (вся линейка
  // x-ui) каждая из трёх ломает трафик при внешне поднятом туннеле. Ключ
  // помечает, что сохранённые значения этих трёх настроек один раз сброшены
  // к новым умолчаниям. Осознанный выбор пользователя после миграции больше
  // не трогается.
  static const compatDefaultsApplied = 'settings.compat_defaults_v1';

  // Кастомный DNS-сервер при dnsServerProvider == 'custom'. Хранит IP-адрес
  // (например 9.9.9.11), используется так же, как остальные пресеты.
  static const customDnsServer = 'security.custom_dns_server';

  // Ручной ключ или подписка, вставленные на экране "Мои ключи"
  // (vless://... или http(s)-ссылка). Если задан, ConnectScreen подключается
  // по нему в приоритете перед ключами из личного кабинета — см.
  // _resolveConnectionString.
  static const manualConnectionString = 'keys.manual_connection_string';

  // Срок хранения локальных логов в днях: 1 | 7 | 30. Записи старше
  // стираются автоматически, по умолчанию AppLogService.defaultRetentionDays.
  static const logRetentionDays = 'security.log_retention_days';

  // Выбранный язык интерфейса (ISO 639-1). Читается один раз в main() до
  // runApp(), пишется из кнопки "Язык" через LocaleService.setLanguage.
  static const appLanguage = 'settings.app_language';

  // Офлайн-кэш подписки. _loadProfiles() качает подписку по сети, а
  // распарсенные профили держатся только в памяти — перезапуск процесса
  // стирает их. Если в этот момент сеть ещё не готова (первые секунды после
  // холодного старта), пользователь видит "Не удалось загрузить конфигурацию
  // подписки", хотя туннель предыдущей сессии продолжает работать в фоне.
  // Три ключа ниже хранят сырое тело последней успешно скачанной подписки.
  static const cachedSubscriptionSource = 'vpn.cached_subscription_source';
  static const cachedSubscriptionBody = 'vpn.cached_subscription_body';
  static const cachedSubscriptionAtMillis =
      'vpn.cached_subscription_at_millis';

  // Офлайн-кэш списка ключей (`GET /user/keys`, см.
  // connect_screen.dart::_loadKeyState): главный экран сразу показывает
  // последний известный ключ, не дожидаясь ответа сервера, и не теряет его
  // без интернета.
  //
  // Ниже — кэш последнего `/user/profile` (баланс, email, реферальные поля),
  // чтобы экран "Баланс" не превращался в прочерки при сбое сети.
  //
  // И флаг "пускать ли трафик самого приложения мимо туннеля". Пока туннель
  // поднят, запросы приложения идут через него же; если туннель поднялся, но
  // пакеты не ходят, приложение слепнет вместе с телефоном: /user/keys не
  // отвечает, экран пишет "НЕТ КЛЮЧА" при активных ключах, все локации
  // показываются недоступными. Зрелые VPN-клиенты держат своё управляющее
  // соединение вне туннеля, поэтому по умолчанию включено. Цена — провайдер
  // видит обращения к api.vpnonline.su в обход туннеля; сам VPN-трафик это
  // не раскрывает.
  static const excludeAppFromTunnel = 'security.exclude_app_from_tunnel';
  // Сохранённые результаты проверки серверов (servers_screen.dart). Формат:
  // {"at": millis, "results": {host_name: {"ok": bool, "ms": int?,
  // "error": String?}}}. Нужен, чтобы при открытии "Выбора сервера" сразу
  // показать последний известный результат — новая проверка занимает секунды
  // на каждую локацию.
  static const cachedRealCheckJson = 'servers.real_check_results';
  static const cachedProfileJson = 'vpn.cached_profile_json';
  static const cachedHostsJson = 'vpn.cached_hosts_json';
  static const cachedPlansJson = 'vpn.cached_plans_json';
  static const cachedKeysJson = 'vpn.cached_keys_json';
  static const cachedKeysAtMillis = 'vpn.cached_keys_at_millis';
}

/// Хранилище ручного ключа, добавленного на экране "Мои ключи".
///
/// Отдельный класс, а не просто LocalPrefs.getString/setString, потому что
/// значение должно реактивно долетать до ConnectScreen: KeysScreen пишет
/// через [set]/[clear], ConnectScreen слушает [notifier] и сразу видит
/// новое значение, даже когда оба экрана в одном Navigator-стеке.
class ManualKeyStore {
  ManualKeyStore._();
  static final ManualKeyStore instance = ManualKeyStore._();

  final ValueNotifier<String?> notifier = ValueNotifier<String?>(null);

  // Кэшируем сам Future первой загрузки, а не флаг "загружено". С флагом,
  // выставляемым синхронно в начале ensureLoaded(), второй конкурентный
  // вызов (ConnectScreen и ServersScreen при быстром переключении вкладок
  // сразу после старта) возвращался мгновенно и получал null вместо
  // сохранённого ключа: чтение из SharedPreferences к тому моменту ещё не
  // завершилось.
  Future<void>? _loadFuture;

  String? get value => notifier.value;

  Future<void> ensureLoaded() {
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    final saved =
        await LocalPrefs.instance.getString(PrefKeys.manualConnectionString);
    notifier.value =
        (saved == null || saved.trim().isEmpty) ? null : saved.trim();
  }

  Future<void> set(String rawValue) async {
    final trimmed = rawValue.trim();
    await LocalPrefs.instance
        .setString(PrefKeys.manualConnectionString, trimmed);
    notifier.value = trimmed.isEmpty ? null : trimmed;
  }

  Future<void> clear() async {
    await LocalPrefs.instance.setString(PrefKeys.manualConnectionString, '');
    notifier.value = null;
  }
}