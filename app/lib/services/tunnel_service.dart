import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class ParsedVless {
  final String remark;
  final String address;
  final int port;

  ParsedVless({
    required this.remark,
    required this.address,
    required this.port,
  });
}

class TunnelStatus {
  final String state;
  final int duration;
  final int download;
  final int upload;

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
  static final TunnelService instance = TunnelService._internal();
  TunnelService._internal();

  static const MethodChannel _fallbackChannel = MethodChannel('vpnvless/fallback');

  final ValueNotifier<TunnelStatus?> status = ValueNotifier<TunnelStatus?>(TunnelStatus('disconnected'));
  final ValueNotifier<String?> connectedServerName = ValueNotifier<String?>(null);
  final ValueNotifier<bool> killSwitchBlocking = ValueNotifier<bool>(false);
  final ValueNotifier<String> localProxyAddress = ValueNotifier<String>("127.0.0.1:10808");

  bool get isConnected => _isConnected;
  bool _isConnected = false;

  bool get isBusy => status.value?.state == 'connecting' || status.value?.state == 'disconnecting';

  Future<int> connectedDelayMs() async {
    try {
      final int? delay = await _fallbackChannel.invokeMethod<int>('getConnectedDelay');
      return delay ?? -1;
    } catch (e) {
      return -1;
    }
  }

  Future<void> connect(String connectionString, {String? preferredHostName}) async {
    if (isBusy) return;

    try {
      status.value = TunnelStatus('connecting', duration: 0, download: 0, upload: 0);
      
      final secureConfig = _hardenConfig(connectionString);
      
      await _fallbackChannel.invokeMethod('startV2Ray', {
        'config': secureConfig,
        'title': 'VPN Service',
        'message': 'Preparing secure connection',
      });

      _isConnected = true;
      connectedServerName.value = preferredHostName ?? "Default Server";
      status.value = TunnelStatus('connected', duration: 0, download: 0, upload: 0);
    } catch (e) {
      _isConnected = false;
      connectedServerName.value = null;
      status.value = TunnelStatus('disconnected', duration: 0, download: 0, upload: 0);
      throw TunnelException('Connection failed. Please check your configuration.');
    }
  }

  Future<void> disconnect() async {
    try {
      status.value = TunnelStatus('disconnecting', duration: 0, download: 0, upload: 0);
      await _fallbackChannel.invokeMethod('stopV2Ray');
      
      _isConnected = false;
      connectedServerName.value = null;
      status.value = TunnelStatus('disconnected', duration: 0, download: 0, upload: 0);
    } catch (e) {
      status.value = TunnelStatus('connected');
      throw TunnelException('Error disconnecting: $e');
    }
  }

  void openSystemVpnSettingsHint() {
    try {
      debugPrint("Invoking openSystemVpnSettingsHint");
    } catch (e) {
      debugPrint("Error opening system VPN settings: $e");
    }
  }

  Future<ParsedVless?> findServerInList(
    List<ParsedVless> servers,
    String targetName,
  ) async {
    final needle = targetName.trim().toLowerCase();
    
    for (var p in servers) {
      if (p.remark.trim().toLowerCase() == needle) {
        return p;
      }
    }
    
    for (var p in servers) {
      final remark = p.remark.trim().toLowerCase();
      if (remark.contains(needle) || needle.contains(remark)) {
        return p;
      }
    }
    
    return null;
  }

  String _hardenConfig(String rawConfig) {
    try {
      Map<String, dynamic> config = jsonDecode(rawConfig);
      
      if (config.containsKey('dns')) {
        final dns = config['dns'];
        if (dns is Map<String, dynamic> && dns.containsKey('servers')) {
          final servers = dns['servers'];
          if (servers is List) {
            List<Map<String, dynamic>> upgradedServers = [];
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
      } else {
        config['dns'] = {
          'servers': [
            {'address': '8.8.8.8'},
            {'address': '1.1.1.1'},
          ]
        };
      }
      
      if (!config.containsKey('route')) {
        config['route'] = {
          "rules": [
            {
              "type": "field",
              "outbound": "direct",
              "domain": ["geosite:private"]
            },
            {
              "type": "field",
              "outbound": "direct",
              "ip": ["geoip:private"]
            }
          ]
        };
      }
      
      return jsonEncode(config);
    } catch (e) {
      return rawConfig;
    }
  }

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
          throw TunnelException('Subscription expired or not active.');
        }
        return configString;
      } else if (res.statusCode == 404) {
        throw TunnelException('Subscription not found. Please check your key.');
      } else {
        throw TunnelException('Server error (${res.statusCode}). Please try again later.');
      }
    } catch (e) {
      if (e is TunnelException) rethrow;
      throw TunnelException('Failed to fetch profile. Check your internet.');
    }
  }

  Future<void> startTunnel(String apiBaseUrl, String apiKey) async {
    try {
      final rawConfig = await _fetchProfile(apiBaseUrl, apiKey);
      await connect(rawConfig, preferredHostName: "Preferred Host");
    } catch (e) {
      throw TunnelException(e.toString());
    }
  }
}
