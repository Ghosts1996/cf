import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// [ИСПРАВЛЕНО] Причина бага "тумблеры возвращаются в исходное положение":
/// каждый экран (SettingsScreen/SecurityScreen/ServersScreen/
/// SplitTunnelScreen) хранил состояние переключателей в обычном локальном
/// `bool` поле StatefulWidget-класса. Такое поле живёт только пока жив
/// State-объект конкретного экрана — стоит уйти с экрана (Navigator.pop)
/// или перезапустить приложение, State пересоздаётся заново со
/// стартовыми значениями по умолчанию (`true`/`false`, зашитыми в код) —
/// снаружи это выглядит так, будто "переключил, а оно откатилось назад".
///
/// Это не баг самого тумблера (NeonToggle — обычный controlled-виджет,
/// value/onChanged у него работают корректно) — не хватало ЕДИНОЙ точки
/// хранения, которая переживает и уход с экрана, и перезапуск приложения.
/// `LocalPrefs` — обёртка над `shared_preferences` (уже было в
/// зависимостях, использовался только для флага онбординга) ровно для
/// этого: значения реально пишутся на диск устройства и читаются обратно
/// при следующем открытии экрана/приложения.
///
/// [ВАЖНО — честно, без преувеличений] Kill Switch/DNS-защита/блокировка
/// рекламы — сами по себе UI-предпочтения, а не реализация на уровне ОС.
/// Как только `TunnelService.connect()` реально стартует туннель (см.
/// tunnel_service.dart), эти же сохранённые значения нужно будет передать
/// в конфиг sing-box как per-app routing (см. tunnel_service.dart, пакет
/// exclusions/DNS через объект конфигурации VLESS-профиля) — сохранение
/// самого выбора уже готово, подключение к реальной маршрутизации остаётся
/// на стороне tunnel_service.dart при следующей правке.
class LocalPrefs {
  LocalPrefs._();
  static final LocalPrefs instance = LocalPrefs._();

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _sp async => _prefs ??= await SharedPreferences.getInstance();

  // ── generic bool ──────────────────────────────────────────────────────
  Future<bool> getBool(String key, {bool fallback = false}) async {
    final sp = await _sp;
    return sp.getBool(key) ?? fallback;
  }

  Future<void> setBool(String key, bool value) async {
    final sp = await _sp;
    await sp.setBool(key, value);
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
  static const smartWifi = 'settings.smart_wifi';
  static const killSwitch = 'settings.kill_switch';
  static const dnsProtection = 'settings.dns_protection';
  static const blockAds = 'settings.block_ads';
  static const dpiBypass = 'settings.dpi_bypass';
  // [НОВОЕ] См. tunnel_service.dart и settings_screen.dart — переключает
  // NetworkMode пакета flutter_singbox_client между 'vpn' (системный
  // туннель, как сейчас) и 'proxy' (только локальные SOCKS/HTTP-порты,
  // без запроса VPN-разрешения — подтверждено официальным README пакета:
  // "Use NetworkMode.proxy when you only need HTTP/SOCKS proxy ports
  // without requesting VPN permission").
  static const proxyOnlyMode = 'settings.proxy_only_mode';
  static const favoriteServers = 'servers.favorites';
  static const autoBalance = 'servers.auto_balance';
  static const selectedServerId = 'servers.selected_id';
  static const splitTunnelBypass = 'split_tunnel.bypassed_packages';
  static const splitTunnelMode = 'split_tunnel.mode'; // 'exclude' | 'include'
}
