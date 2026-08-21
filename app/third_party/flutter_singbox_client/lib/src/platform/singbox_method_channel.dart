import 'dart:async';
import 'package:flutter/services.dart';
import '../models/index.dart';
import 'singbox_platform_interface.dart';

class SingboxMethodChannel extends SingboxPlatformInterface {
  static const _channel = MethodChannel('flutter_singbox_client');

  static const _stateChannel = EventChannel('flutter_singbox_client/state');
  static const _trafficChannel = EventChannel('flutter_singbox_client/traffic');
  static const _logChannel = EventChannel('flutter_singbox_client/logs');
  static const _connectionChannel = EventChannel('flutter_singbox_client/connections');
  static const _groupChannel = EventChannel('flutter_singbox_client/groups');
  static const _clashModeChannel = EventChannel('flutter_singbox_client/clash_mode');
  static const _clashModesChannel = EventChannel('flutter_singbox_client/clash_modes');
  static const _alertChannel = EventChannel('flutter_singbox_client/alerts');
  static const _networkQualityChannel = EventChannel('flutter_singbox_client/network_quality');
  static const _stunChannel = EventChannel('flutter_singbox_client/stun');

  Stream<ServiceState>? _stateStream;
  Stream<TrafficStats>? _trafficStream;
  Stream<List<LogEntry>>? _coreLogStream;
  Stream<List<ConnectionInfo>>? _connStream;
  Stream<List<OutboundGroup>>? _groupStream;
  Stream<String>? _clashStream;
  Stream<List<String>>? _clashModesStream;
  Stream<String>? _faultStream;
  Stream<NetworkQualityProgress>? _networkQualityStream;
  Stream<StunProgress>? _stunStream;

  Future<T?> _invoke<T>(String method, [dynamic args]) async {
    return await _channel.invokeMethod<T>(method, args);
  }

  // ──── Lifecycle ────────────────────────────────────────────────────────────

  @override
  Future<void> initialize(EngineOptions options) async {
    await _invoke('initialize', options.toMap());
  }

  @override
  Future<void> dispose() async {
    _stateStream = null;
    _trafficStream = null;
    _coreLogStream = null;
    _connStream = null;
    _groupStream = null;
    _clashStream = null;
    _clashModesStream = null;
    _faultStream = null;
    _networkQualityStream = null;
    _stunStream = null;
  }

  @override
  Future<bool> requestVPNPermission() async {
    return await _invoke<bool>('requestVPNPermission') ?? false;
  }

  @override
  Future<void> connect(SessionOptions options) =>
      _invoke('connect', options.toMap());

  @override
  Future<void> disconnect() => _invoke('disconnect');

  @override
  Future<void> reloadConfig() => _invoke('reloadConfig');

  @override
  Future<ServiceState> getServiceState() async {
    final v = await _invoke<int>('getServiceState') ?? 0;
    return ServiceState.fromInt(v);
  }

  @override
  Future<String> getVersion() async {
    return await _invoke<String>('getVersion') ?? '';
  }

  @override
  Future<String> getCoreVersion() async {
    return await _invoke<String>('getCoreVersion') ?? '';
  }

  // ──── Config ───────────────────────────────────────────────────────────────

  @override
  Future<void> checkConfig(String configContent) async {
    await _invoke<void>('checkConfig', {'content': configContent});
  }

  @override
  Future<String> formatConfig(String configContent) async {
    return await _invoke<String>('formatConfig', {'content': configContent}) ?? configContent;
  }

  // ──── Outbounds / Groups ───────────────────────────────────────────────────

  @override
  Future<void> selectOutbound(String groupTag, String outboundTag) =>
      _invoke('selectOutbound', {'groupTag': groupTag, 'outboundTag': outboundTag});

  @override
  Future<void> urlTest(String groupTag) =>
      _invoke('urlTest', {'groupTag': groupTag});

  // ──── Clash Mode ───────────────────────────────────────────────────────────

  @override
  Future<void> setClashMode(String mode) =>
      _invoke('setClashMode', {'mode': mode});

  // ──── Connections ──────────────────────────────────────────────────────────

  @override
  Future<void> closeConnection(String connectionId) =>
      _invoke('closeConnection', {'id': connectionId});

  @override
  Future<void> closeAllConnections() => _invoke('closeAllConnections');

  // ──── Traffic ──────────────────────────────────────────────────────────────

  @override
  Future<TrafficStats> getTrafficStats() async {
    final raw = await _invoke<Map<Object?, Object?>>('getTrafficStats');
    return raw != null ? TrafficStats.fromMap(raw) : TrafficStats.zero;
  }

  // ──── System Proxy ─────────────────────────────────────────────────────────

  @override
  Future<SystemProxyStatus> getSystemProxyStatus() async {
    final raw = await _invoke<Map<Object?, Object?>>('getSystemProxyStatus');
    return raw != null
        ? SystemProxyStatus.fromMap(raw)
        : const SystemProxyStatus(available: false, enabled: false);
  }

  @override
  Future<void> setSystemProxyEnabled(bool enabled) =>
      _invoke('setSystemProxyEnabled', {'enabled': enabled});

  // ──── Network Testing ──────────────────────────────────────────────────────

  @override
  Future<void> startStunTest([String server = '']) =>
      _invoke('startStunTest', {'server': server});

  @override
  Future<void> stopStunTest() => _invoke('stopStunTest');

  @override
  Future<void> startNetworkQualityTest() => _invoke('startNetworkQualityTest');

  @override
  Future<void> stopNetworkQualityTest() => _invoke('stopNetworkQualityTest');

  // ──── Streams ──────────────────────────────────────────────────────────────

  @override
  Stream<ServiceState> get serviceStateStream {
    _stateStream ??= _stateChannel
        .receiveBroadcastStream()
        .map((e) => ServiceState.fromInt(e as int));
    return _stateStream!;
  }

  @override
  Stream<TrafficStats> get trafficStatsStream {
    _trafficStream ??= _trafficChannel
        .receiveBroadcastStream()
        .map((e) => TrafficStats.fromMap(e as Map<Object?, Object?>));
    return _trafficStream!;
  }

  @override
  Stream<List<LogEntry>> get coreLogStream {
    _coreLogStream ??= _logChannel.receiveBroadcastStream().map((e) {
      final list = (e as List<Object?>).cast<Map<Object?, Object?>>();
      return list.map(LogEntry.fromMap).toList();
    });
    return _coreLogStream!;
  }

  @override
  Stream<List<ConnectionInfo>> get connectionStream {
    _connStream ??= _connectionChannel.receiveBroadcastStream().map((e) {
      final list = (e as List<Object?>).cast<Map<Object?, Object?>>();
      return list.map(ConnectionInfo.fromMap).toList();
    });
    return _connStream!;
  }

  @override
  Stream<List<OutboundGroup>> get outboundGroupStream {
    _groupStream ??= _groupChannel.receiveBroadcastStream().map((e) {
      final list = (e as List<Object?>).cast<Map<Object?, Object?>>();
      return list.map(OutboundGroup.fromMap).toList();
    });
    return _groupStream!;
  }

  @override
  Stream<String> get clashModeStream {
    _clashStream ??= _clashModeChannel
        .receiveBroadcastStream()
        .map((e) => e as String);
    return _clashStream!;
  }

  @override
  Stream<List<String>> get clashModesStream {
    _clashModesStream ??= _clashModesChannel.receiveBroadcastStream().map((e) {
      return (e as List<Object?>).cast<String>();
    });
    return _clashModesStream!;
  }

  @override
  Stream<String> get faultStream {
    _faultStream ??= _alertChannel
        .receiveBroadcastStream()
        .map((e) => e as String);
    return _faultStream!;
  }

  @override
  Stream<NetworkQualityProgress> get networkQualityProgressStream {
    _networkQualityStream ??= _networkQualityChannel
        .receiveBroadcastStream()
        .map((e) => NetworkQualityProgress.fromMap(e as Map<Object?, Object?>));
    return _networkQualityStream!;
  }

  @override
  Stream<StunProgress> get stunProgressStream {
    _stunStream ??= _stunChannel
        .receiveBroadcastStream()
        .map((e) => StunProgress.fromMap(e as Map<Object?, Object?>));
    return _stunStream!;
  }
}
