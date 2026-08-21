/// Controls the Go runtime soft memory cap applied when the service starts.
///
/// This is a Go runtime setting (`GOMEMLIMIT`-style), not an Android JVM heap
/// limit. Lowering the cap reduces peak RAM at the cost of more aggressive GC.
///
/// Pass an instance to [SessionOptions.memoryLimit] when connecting:
///
/// ```dart
/// await client.connect(SessionOptions(
///   config: configJson,
///   memoryLimit: MemoryLimitConfig(
///     enabled: true,
///     limitMb: 150,
///     killConnections: false,
///   ),
/// ));
/// ```
class MemoryLimitConfig {
  /// Whether the memory cap is active. When false, all other fields are ignored.
  final bool enabled;

  /// Soft memory cap in megabytes. Ignored when [enabled] is false.
  /// Typical values: 50–300 MB. Default: 50.
  final int limitMb;

  /// When true, active connections are dropped when the cap is reached.
  /// More aggressive but keeps memory tightly bounded.
  /// Ignored when [enabled] is false.
  final bool killConnections;

  const MemoryLimitConfig({
    this.enabled = false,
    this.limitMb = 50,
    this.killConnections = false,
  });

  Map<String, dynamic> toMap() => {
        'enableMemoryLimit': enabled,
        'memoryLimitMb': limitMb,
        'killConnectionsOnLimit': killConnections,
      };
}
