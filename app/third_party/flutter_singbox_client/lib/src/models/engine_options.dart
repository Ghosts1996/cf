/// Options for initializing the Sing-box engine.
///
/// All fields have sensible defaults — the minimal call is simply
/// `await client.initialize()` with no arguments. Override fields only when
/// you need to change storage paths or the IPC port.
///
/// ```dart
/// await client.initialize(
///   const EngineOptions(
///     commandServerPort: 10087, // only if 10086 conflicts
///   ),
/// );
/// ```
class EngineOptions {
  /// Engine base directory for coordination and runtime files.
  ///
  /// Defaults to `<cacheDir>/flutter_singbox_client_engine`.
  final String? basePath;

  /// Engine working directory for geo rule sets, DNS cache, and resolved config.
  ///
  /// Defaults to `<basePath>/working`.
  final String? workingPath;

  /// Scratch directory used during engine setup.
  ///
  /// Defaults to the system temporary directory.
  final String? tempPath;

  /// Localhost port used for IPC between the Kotlin plugin and the Go core.
  ///
  /// This is internal SDK communication — it is unrelated to VPN/proxy ports
  /// or user traffic. Default: `10086`. Change only if the port conflicts with
  /// another service on the device.
  final int commandServerPort;

  /// Optional authentication token for the internal IPC server.
  ///
  /// Leave empty (the default) unless you need to harden the IPC channel.
  final String commandServerSecret;

  /// Creates an [EngineOptions]. All fields have safe defaults.
  const EngineOptions({
    this.basePath,
    this.workingPath,
    this.tempPath,
    this.commandServerPort = 10086,
    this.commandServerSecret = '',
  });

  /// Returns a copy with any `null` path fields filled from the provided defaults.
  EngineOptions withPaths({
    required String basePath,
    required String workingPath,
    required String tempPath,
  }) =>
      EngineOptions(
        basePath: this.basePath ?? basePath,
        workingPath: this.workingPath ?? workingPath,
        tempPath: this.tempPath ?? tempPath,
        commandServerPort: commandServerPort,
        commandServerSecret: commandServerSecret,
      );

  /// Serializes to the map passed over the platform channel.
  Map<String, dynamic> toMap() => {
        'basePath': basePath!,
        'workingPath': workingPath!,
        'tempPath': tempPath!,
        'commandServerPort': commandServerPort,
        'commandServerSecret': commandServerSecret,
      };
}
