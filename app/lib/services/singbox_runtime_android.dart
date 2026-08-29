// [НОВОЕ — Windows real-VPN] См. докстринг в singbox_runtime.dart.
//
// Это ровно тот же `SingboxClient`, что вызывался раньше напрямую из
// tunnel_service.dart, — просто спрятанный за интерфейсом. Каждый метод
// здесь делает ОДНО: вызывает соответствующий метод настоящего плагина и
// возвращает результат. Никакой дополнительной логики, никаких изменений
// поведения на Android.
import 'package:flutter_singbox_client/flutter_singbox_client.dart';

import 'singbox_runtime.dart';

class AndroidSingboxRuntime implements SingboxRuntimeClient {
  final SingboxClient _client = SingboxClient();

  @override
  Future<void> initialize() => _client.initialize();

  @override
  Stream<dynamic> get serviceStateStream => _client.serviceStateStream;

  @override
  Stream<dynamic> get trafficStatsStream => _client.trafficStatsStream;

  @override
  Stream<dynamic> get faultStream => _client.faultStream;

  @override
  Future<dynamic> getServiceState() => _client.getServiceState();

  @override
  Future<dynamic> getTrafficStats() => _client.getTrafficStats();

  @override
  Future<void> checkConfig(String config) => _client.checkConfig(config);

  @override
  Future<void> connect(SessionOptions options) => _client.connect(options);

  @override
  Future<void> disconnect() => _client.disconnect();

  @override
  Future<bool> requestVPNPermission() => _client.requestVPNPermission();
}