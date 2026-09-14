// Реализация SingboxRuntimeClient поверх штатного плагина: каждый метод
// просто форвардит вызов в SingboxClient.
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

  @override
  Future<void> selectOutbound(String groupTag, String outboundTag) =>
      _client.selectOutbound(groupTag, outboundTag);

  @override
  Future<void> urlTest(String groupTag) => _client.urlTest(groupTag);

  @override
  Stream<dynamic> get outboundGroupStream => _client.outboundGroupStream;
}