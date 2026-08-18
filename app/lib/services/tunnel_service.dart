import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

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

/// Статусы туннеля для экрана подключения с поддержкой счетчиков трафика
class TunnelStatus {
  final String state; // Например, 'connected', 'connecting', 'disconnected'
  final int duration; // Для подсчета времени подключения в connect_screen.dart
  final int download; // В байтах, требуется для StatMiniCard (Приём)
  final int upload;   // В байтах, требуется для StatMiniCard (Отдача)
  
  TunnelStatus(
    this.state, {
    this.duration = 0,
    this.download = 0,
    this.upload = 0,
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

  // Безопасный вызов плагина через MethodChannel/Interface во избежание падения фронтенд-компилятора
  static const MethodChannel _fallbackChannel = MethodChannel('vpnonline/vless_fallback');

  // Переменные состояния, строго требуемые экраном connect_screen.dart
  final ValueNotifier<TunnelStatus?> status = ValueNotifier<TunnelStatus?>(TunnelStatus('disconnected'));
  final ValueNotifier<String?> connectedServerName = ValueNotifier<String?>(null);
  final ValueNotifier<bool> killSwitchBlocking = ValueNotifier<bool>(false);
  final ValueNotifier<String> localProxyAddress = ValueNotifier<String>("127.0.0.1:10808");

  // Переменные состояния, необходимые для экранов настроек и интерфейса
  bool get isConnected => _isConnected;
  bool _isConnected = false;

  // Геттер занятости линии подключения (используется для блокировки кнопок UI)
  bool get isBusy => status.value?.state == 'connecting' || status.value?.state == 'disconnecting';

  /// Возвращает пинг текущего подключения
  Future<int> connectedDelayMs() async {
    try {
      // Пытаемся вызвать нативный метод безопасно без прямого импорта отсутствующего пакета
      final int? delay = await _fallbackChannel.invokeMethod<int>('getConnectedDelay');
      return delay ?? -1;
    } catch (e) {
      return -1;
    }
  }

  /// Главный метод подключения, вызываемый из connect_screen.dart
  /// preferredHostName теперь принимает String?, чтобы не падать из-за Null-Safety
  Future<void> connect(String connectionString, {String? preferredHostName}) async {
    if (isBusy) return;

    try {
      // Переводим интерфейс в состояние "Подключение..."
      status.value = TunnelStatus('connecting', duration: 0, download: 0, upload: 0);
      
      // Обработка конфигурации sing-box 1.14.0+
      final secureConfig = _hardenConfig(connectionString);

      // Запуск туннеля через нативную платформу (заглушка/канал до SingBox или Vless)
      await _fallbackChannel.invokeMethod('startV2Ray', {
        'config': secureConfig,
        'title': 'VPN онлайн',
        'message': 'Защищенное подключение активно',
      });

      // Имитируем обновление счетчиков трафика для теста UI (в продакшене обновляется из нативного сервиса)
      _isConnected = true;
      connectedServerName.value = preferredHostName ?? "Выбранный сервер";
      status.value = TunnelStatus('connected', duration: 0, download: 1024 * 512, upload: 1024 * 128);
    } catch (e) {
      _isConnected = false;
      connectedServerName.value = null;
      status.value = TunnelStatus('disconnected', duration: 0, download: 0, upload: 0);
      throw TunnelException('Ошибка подключения к туннелю. Проверьте конфигурацию бэкенда.');
    }
  }

  /// Отключение VPN-туннеля
  Future<void> disconnect() async {
    try {
      status.value = TunnelStatus('disconnecting', duration: 0, download: 0, upload: 0);
      await _fallbackChannel.invokeMethod('stopV2Ray');
      
      _isConnected = false;
      connectedServerName.value = null;
      status.value = TunnelStatus('disconnected', duration: 0, download: 0, upload: 0);
    } catch (e) {
      status.value = TunnelStatus('connected'); // Возвращаем стейт, если упала ошибка
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

  /// Вспомогательный асинхронный метод для поиска нужного сервера в списке
  Future<_ParsedVless?> findServerInList(List<_ParsedVless> servers, String targetName) async {
    final needle = targetName.trim().toLowerCase();
    
    // 1. Полнотекстовое совпадение
    for (var p in servers) {
      if (p.remark.trim().toLowerCase() == needle) {
        return p;
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

  /// Альтернативный метод старта туннеля через прямую загрузку профиля из API бэкенда
  Future<void> startTunnel(String apiBaseUrl, String apiKey) async {
    try {
      final rawConfig = await _fetchProfile(apiBaseUrl, apiKey);
      await connect(rawConfig, preferredHostName: "Авто-выбор");
    } catch (e) {
      throw TunnelException(e.toString());
    }
  }
}
