import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_vless_android/flutter_vless_android.dart';

/// Вспомогательный класс для хранения распарсенных данных VLESS
class _ParsedVless {
  final String remark;
  final String address;
  final int port;

  _ParsedVless({
    required this.remark,
    required this.address,
    required this.port,
  });
}

class TunnelException implements Exception {
  final String message;
  TunnelException(this.message);
  @override
  String toString() => message;
}

class TunnelService {
  // Синглтон для глобального доступа к сервису
  static final TunnelService instance = TunnelService._internal();
  TunnelService._internal();

  final _vlessPlugin = FlutterVlessAndroid();

  // Переменные состояния, необходимые для экранов настроек и интерфейса
  bool get isConnected => _isConnected;
  bool _isConnected = false;
  
  final ValueNotifier<String> localProxyAddress = ValueNotifier<String>("127.0.0.1:10808");

  /// Возвращает пинг текущего подключения
  Future<int> connectedDelayMs() async {
    try {
      final int delay = await _vlessPlugin.getConnectedDelay() ?? -1;
      return delay;
    } catch (e) {
      return -1;
    }
  }

  /// Отключение VPN-туннеля
  Future<void> disconnect() async {
    try {
      await _vlessPlugin.stopV2Ray();
      _isConnected = false;
    } catch (e) {
      throw TunnelException('Не удалось остановить туннель: $e');
    }
  }

  /// Открытие системных настроек VPN
  void openSystemVpnSettingsHint() {
    try {
      debugPrint("Вызов метода openSystemVpnSettingsHint");
    } catch (e) {
      debugPrint("Ошибка открытия настроек: $e");
    }
  }

  /// Вспомогательный асинхронный метод для поиска нужного сервера в списке (Исправленный синтаксис Future)
  Future<_ParsedVless?> findServerInList(List<_ParsedVless> servers, String targetName) async {
    final needle = targetName.trim().toLowerCase();
    
    // 1. Полнотекстовое совпадение
    for (var p in servers) {
      if (p.remark.trim().toLowerCase() == needle) {
        return p; // В асинной функции чистый объект автоматически обернется в Future
      }
    }
    
    // 2. Частичное совпадение по вхождению подстроки
    for (var p in servers) {
      final remark = p.remark.trim().toLowerCase();
      if (remark.contains(needle) || needle.contains(remark)) {
        return p;
      }
    }
    
    return null;
  }

  /// Метод исправления и нормализации конфигурации sing-box 1.14.0+
  String _hardenConfig(String rawConfig) {
    try {
      final Map<String, dynamic> config = jsonDecode(rawConfig);
      
      // Пересобираем блок dns под новые строгие требования ядра sing-box
      if (config.containsKey('dns')) {
        final dns = config['dns'];
        if (dns is Map<String, dynamic> && dns.containsKey('servers')) {
          final servers = dns['servers'];
          if (servers is List) {
            final List<Map<String, dynamic>> upgradedServers = [];
            for (var server in servers) {
              if (server is String) {
                upgradedServers.add({
                  'address': server,
                  'detour': 'direct'
                });
              } else if (server is Map<String, dynamic>) {
                upgradedServers.add(server);
              }
            }
            dns['servers'] = upgradedServers;
          }
        }
      }
      return jsonEncode(config);
    } catch (e) {
      return rawConfig; // Если на вход пришел не JSON, возвращаем как есть
    }
  }

  /// Запрос профиля с бэкенда бота
  Future<String> _fetchProfile(String apiBaseUrl, String apiKey) async {
    final url = Uri.parse('$apiBaseUrl/api/v1/user/keys');
    
    try {
      final res = await http.get(
        url,
        headers: {'Authorization': 'Bearer $apiKey'},
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final configString = data['connection_string'] as String?;
        
        if (configString == null || configString.isEmpty) {
          throw TunnelException('Для этого ключа нет ссылки на конфигурацию сервера.');
        }
        return configString;
      } else if (res.statusCode == 404) {
        throw TunnelException('Не удалось получить конфигурацию сервера. Проверь интернет-соединение.');
      } else {
        throw TunnelException('Сервер конфигурации недоступен (${res.statusCode}). Попробуй позже.');
      }
    } catch (e) {
      if (e is TunnelException) rethrow;
      throw TunnelException('Не удалось разобрать конфигурацию сервера.');
    }
  }

  /// Запуск VPN-туннеля
  Future<void> startTunnel(String apiBaseUrl, String apiKey) async {
    try {
      final rawConfig = await _fetchProfile(apiBaseUrl, apiKey);
      final secureConfig = _hardenConfig(rawConfig);

      final hasPermission = await _vlessPlugin.requestVpnPermission();
      if (!hasPermission) {
        throw TunnelException('Нужно разрешение на создание VPN-подключения — без него туннель не запустится.');
      }

      await _vlessPlugin.startV2Ray(
        config: secureConfig,
        notificationTitle: 'VPN онлайн',
        notificationMessage: 'Защищенное подключение активно',
      );
      _isConnected = true;
    } catch (e) {
      _isConnected = false;
      throw TunnelException(e.toString());
    }
  }
}
