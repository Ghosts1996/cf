import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import '../models/index.dart';

abstract class SingboxPlatformInterface extends PlatformInterface {
  SingboxPlatformInterface() : super(token: _token);
  static final Object _token = Object();

  static SingboxPlatformInterface? _instance;

  static SingboxPlatformInterface get instance {
    if (_instance == null) throw StateError('SingboxPlatformInterface not initialized');
    return _instance!;
  }

  static set instance(SingboxPlatformInterface inst) {
    PlatformInterface.verifyToken(inst, _token);
    _instance = inst;
  }

  // ──── Lifecycle ────────────────────────────────────────────────────────────

  Future<void> initialize(EngineOptions options);

  Future<void> dispose();

  Future<bool> requestVPNPermission();

  Future<void> connect(SessionOptions options);

  Future<void> disconnect();

  Future<void> reloadConfig();

  Future<ServiceState> getServiceState();

  Future<String> getVersion();

  Future<String> getCoreVersion();

  // ──── Config ───────────────────────────────────────────────────────────────

  /// Validates [configContent]. Returns normally on success.
  /// Throws [PlatformException] with code `INVALID_CONFIG` and the engine's
  /// error message on failure.
  Future<void> checkConfig(String configContent);

  Future<String> formatConfig(String configContent);

  // ──── Outbounds / Groups ───────────────────────────────────────────────────

  Future<void> selectOutbound(String groupTag, String outboundTag);

  Future<void> urlTest(String groupTag);

  // ──── Clash Mode ───────────────────────────────────────────────────────────

  Future<void> setClashMode(String mode);

  // ──── Connections ──────────────────────────────────────────────────────────

  Future<void> closeConnection(String connectionId);

  Future<void> closeAllConnections();

  // ──── Traffic / Stats ──────────────────────────────────────────────────────

  Future<TrafficStats> getTrafficStats();

  // ──── System Proxy ─────────────────────────────────────────────────────────

  Future<SystemProxyStatus> getSystemProxyStatus();

  Future<void> setSystemProxyEnabled(bool enabled);

  // ──── Network Testing ──────────────────────────────────────────────────────

  /// Starts a STUN test against [server] (defaults to the libbox default server
  /// when empty). Progress and the final result are emitted on [stunProgressStream].
  Future<void> startStunTest([String server = '']);

  Future<void> stopStunTest();

  /// Starts a network quality test. Progress and the final result are emitted
  /// on [networkQualityProgressStream]. Call [stopNetworkQualityTest] to cancel.
  Future<void> startNetworkQualityTest();

  Future<void> stopNetworkQualityTest();

  // ──── Event Streams ────────────────────────────────────────────────────────

  Stream<ServiceState> get serviceStateStream;

  Stream<TrafficStats> get trafficStatsStream;

  Stream<List<LogEntry>> get coreLogStream;

  Stream<List<ConnectionInfo>> get connectionStream;

  Stream<List<OutboundGroup>> get outboundGroupStream;

  Stream<String> get clashModeStream;

  Stream<List<String>> get clashModesStream;

  Stream<String> get faultStream;

  Stream<NetworkQualityProgress> get networkQualityProgressStream;

  Stream<StunProgress> get stunProgressStream;
}
