import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'models/index.dart';
import 'platform/singbox_platform_interface.dart';
import 'platform/singbox_method_channel.dart';

/// The main entry point for the flutter_singbox_client SDK.
///
/// Create an instance wherever the client is needed and initialize once
/// at application startup:
/// ```dart
/// final client = SingboxClient();
/// await client.initialize();
/// ```
///
/// Multiple instances may be created freely — the underlying Sing-box engine
/// is process-scoped and initialized only once regardless of how many
/// [SingboxClient] objects exist. Subsequent [initialize] calls on any
/// instance are no-ops.
class SingboxClient {
  /// Creates a [SingboxClient].
  SingboxClient();

  // Memoized init future shared across all instances.
  // Using a Future rather than a bool flag prevents races: concurrent callers
  // all await the same in-flight work instead of each spawning their own.
  // Reset to null by dispose() so the engine can be re-initialized after
  // teardown (e.g. between integration tests).
  static Future<void>? _initFuture;

  SingboxPlatformInterface get _platform => SingboxPlatformInterface.instance;

  // ──── Initialization ───────────────────────────────────────────────────────

  /// Initializes the Sing-box engine. Safe to call multiple times — subsequent
  /// calls are no-ops that return immediately.
  ///
  /// [options] is optional; defaults are correct for all standard deployments.
  Future<void> initialize([EngineOptions options = const EngineOptions()]) =>
      _initFuture ??= _doInit(options);

  static Future<void> _doInit(EngineOptions options) async {
    SingboxPlatformInterface.instance = SingboxMethodChannel();

    // Fetch both directories in parallel — they are independent I/O calls.
    final results = await Future.wait([
      getApplicationCacheDirectory(),
      getTemporaryDirectory(),
    ]);
    final root = '${results[0].path}/flutter_singbox_client_engine';

    await SingboxPlatformInterface.instance.initialize(
      options.withPaths(
        basePath: root,
        workingPath: '$root/working',
        tempPath: results[1].path,
      ),
    );
  }

  /// Releases SDK resources. Resets the engine initialization state so that
  /// [initialize] can be called again if needed (e.g. during testing).
  Future<void> dispose() async {
    await _platform.dispose();
    _initFuture = null;
  }

  // ──── VPN Permission ──────────────────────────────────────────────────────

  /// Requests the Android VPN permission dialog.
  ///
  /// Returns `true` if the permission was granted, `false` if the user denied
  /// it or if the permission was already held. Call before [connect] when using
  /// [NetworkMode.vpn].
  Future<bool> requestVPNPermission() => _platform.requestVPNPermission();

  // ──── Service Lifecycle ───────────────────────────────────────────────────

  /// Starts the VPN or proxy service with the provided [options].
  ///
  /// Validate [SessionOptions.config] with [checkConfig] before calling this.
  /// Subscribe to [faultStream] before calling to catch startup failures.
  Future<void> connect(SessionOptions options) =>
      _platform.connect(options);

  /// Stops the running VPN or proxy service.
  Future<void> disconnect() => _platform.disconnect();

  /// Reloads the current configuration without a full service restart.
  ///
  /// Existing connections are preserved. The new config must be valid.
  Future<void> reloadConfig() => _platform.reloadConfig();

  /// Returns a point-in-time snapshot of the current [ServiceState].
  ///
  /// For continuous updates, subscribe to [serviceStateStream] instead.
  Future<ServiceState> getServiceState() => _platform.getServiceState();

  // ──── Version ─────────────────────────────────────────────────────────────

  /// Returns the flutter_singbox_client plugin version string.
  Future<String> getVersion() => _platform.getVersion();

  /// Returns the bundled Sing-box core version string (e.g. `'1.10.0'`).
  Future<String> getCoreVersion() => _platform.getCoreVersion();

  // ──── Config Validation ───────────────────────────────────────────────────

  /// Validates a Sing-box JSON config string by passing it to the Go core.
  ///
  /// Throws a `PlatformException` whose message is the Go core's exact error
  /// description when the config is invalid. Returns normally on success.
  Future<void> checkConfig(String configContent) =>
      _platform.checkConfig(configContent);

  /// Pretty-prints a Sing-box JSON config string.
  ///
  /// Returns the formatted JSON. Useful for storing a canonical form before
  /// calling [connect].
  Future<String> formatConfig(String configContent) =>
      _platform.formatConfig(configContent);

  // ──── Outbound Groups ─────────────────────────────────────────────────────

  /// Selects an outbound in a proxy group.
  ///
  /// Only works on groups where [OutboundGroup.selectable] is `true`.
  /// `urltest` groups manage their own selection automatically.
  Future<void> selectOutbound(String groupTag, String outboundTag) =>
      _platform.selectOutbound(groupTag, outboundTag);

  /// Runs a URL latency test for all outbounds in the group identified by [groupTag].
  ///
  /// Results are emitted on [outboundGroupStream].
  Future<void> urlTest(String groupTag) => _platform.urlTest(groupTag);

  // ──── Clash Mode ──────────────────────────────────────────────────────────

  /// Switches the active Clash mode.
  ///
  /// Requires a `clash_api` block with named modes in the active config.
  Future<void> setClashMode(String mode) => _platform.setClashMode(mode);

  // ──── Connections ─────────────────────────────────────────────────────────

  /// Closes the connection identified by [connectionId].
  Future<void> closeConnection(String connectionId) =>
      _platform.closeConnection(connectionId);

  /// Closes all active connections.
  Future<void> closeAllConnections() => _platform.closeAllConnections();

  // ──── Traffic Stats ───────────────────────────────────────────────────────

  /// Returns a point-in-time [TrafficStats] snapshot.
  ///
  /// For live updates at ~1 Hz, subscribe to [trafficStatsStream] instead.
  Future<TrafficStats> getTrafficStats() => _platform.getTrafficStats();

  // ──── System Proxy ────────────────────────────────────────────────────────

  /// Returns the current [SystemProxyStatus].
  ///
  /// [SystemProxyStatus.available] is `false` when running in proxy mode,
  /// on API < 29, or when the active config has no HTTP inbound.
  Future<SystemProxyStatus> getSystemProxyStatus() =>
      _platform.getSystemProxyStatus();

  /// Enables or disables the system HTTP proxy at runtime without restarting.
  ///
  /// VPN mode only, Android Q+ (API 29+). Has no effect when
  /// [SystemProxyStatus.available] is `false`.
  Future<void> setSystemProxyEnabled(bool enabled) =>
      _platform.setSystemProxyEnabled(enabled);

  // ──── Network Testing ─────────────────────────────────────────────────────

  /// Starts a STUN test. Subscribe to [stunProgressStream] before calling this.
  ///
  /// [server] is an optional `host:port` STUN server address. Defaults to the
  /// libbox built-in server when omitted or empty.
  Future<void> startStunTest([String server = '']) => _platform.startStunTest(server);

  /// Cancels a running STUN test.
  Future<void> stopStunTest() => _platform.stopStunTest();

  /// Starts a network quality test. Subscribe to [networkQualityProgressStream]
  /// before calling this to receive live progress and the final result.
  Future<void> startNetworkQualityTest() => _platform.startNetworkQualityTest();

  /// Cancels a running network quality test.
  Future<void> stopNetworkQualityTest() => _platform.stopNetworkQualityTest();

  // ──── Event Streams ───────────────────────────────────────────────────────

  /// Broadcast stream of [ServiceState] transitions.
  ///
  /// Emits on every state change. Subscribe once and hold the subscription
  /// for the lifetime of your state object.
  Stream<ServiceState> get serviceStateStream => _platform.serviceStateStream;

  /// Broadcast stream of [TrafficStats] snapshots at approximately 1 Hz.
  ///
  /// Only emits while the service is running.
  Stream<TrafficStats> get trafficStatsStream => _platform.trafficStatsStream;

  /// Broadcast stream of batched [LogEntry] lists from the Go core.
  ///
  /// High volume — continuous during operation. Cap the buffer in your listener
  /// to avoid unbounded memory growth. Do not show raw entries to end users;
  /// use [faultStream] for user-facing errors.
  Stream<List<LogEntry>> get coreLogStream => _platform.coreLogStream;

  /// Broadcast stream of full [ConnectionInfo] list updates.
  ///
  /// Emits on every connection open or close event.
  Stream<List<ConnectionInfo>> get connectionStream =>
      _platform.connectionStream;

  /// Broadcast stream of [OutboundGroup] list updates.
  ///
  /// Emits once on connect and again on every latency update or selection change.
  Stream<List<OutboundGroup>> get outboundGroupStream =>
      _platform.outboundGroupStream;

  /// Broadcast stream of the currently active Clash mode string.
  ///
  /// Emits on connect and on every mode change.
  Stream<String> get clashModeStream => _platform.clashModeStream;

  /// Broadcast stream of available Clash mode names from the loaded config.
  ///
  /// Emits once on connect. Empty when the config has no `clash_api` block.
  Stream<List<String>> get clashModesStream => _platform.clashModesStream;

  /// Broadcast stream of critical service error messages.
  ///
  /// Every emission means the VPN/proxy is not running. Always surface these
  /// to the user (snackbar, dialog, or status banner).
  Stream<String> get faultStream => _platform.faultStream;

  /// Broadcast stream of [NetworkQualityProgress] events during a quality test.
  ///
  /// Subscribe before calling [startNetworkQualityTest].
  Stream<NetworkQualityProgress> get networkQualityProgressStream =>
      _platform.networkQualityProgressStream;

  /// Broadcast stream of [StunProgress] events during a STUN test.
  ///
  /// Subscribe before calling [startStunTest].
  Stream<StunProgress> get stunProgressStream => _platform.stunProgressStream;
}
