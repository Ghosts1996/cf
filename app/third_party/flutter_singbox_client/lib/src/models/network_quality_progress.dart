/// Progress event emitted during a network quality test.
///
/// Received via [SingboxClient.networkQualityProgressStream].
/// The test runs for up to 30 seconds and emits updates throughout.
/// Check [isRunning] to detect the final result emission:
/// ```dart
/// _sub = client.networkQualityProgressStream.listen((p) {
///   setState(() => _progress = p);
///   if (!p.isRunning) _sub = null;
/// });
/// ```
class NetworkQualityProgress {
  /// Whether the test is still running. `false` on the final result emission.
  final bool isRunning;

  /// Baseline round-trip latency with no competing traffic, in milliseconds.
  final int idleLatencyMs;

  /// Measured download throughput in bits per second.
  final int downloadCapacityBps;

  /// Measured upload throughput in bits per second.
  final int uploadCapacityBps;

  /// Number of download requests completed per minute.
  final int downloadRPM;

  /// Number of upload requests completed per minute.
  final int uploadRPM;

  /// Creates a [NetworkQualityProgress].
  const NetworkQualityProgress({
    required this.isRunning,
    required this.idleLatencyMs,
    required this.downloadCapacityBps,
    required this.uploadCapacityBps,
    required this.downloadRPM,
    required this.uploadRPM,
  });

  /// Deserializes a [NetworkQualityProgress] from a platform channel map.
  factory NetworkQualityProgress.fromMap(Map<Object?, Object?> map) {
    return NetworkQualityProgress(
      isRunning: map['isRunning'] as bool? ?? true,
      idleLatencyMs: (map['idleLatencyMs'] as num?)?.toInt() ?? 0,
      downloadCapacityBps: (map['downloadCapacityBps'] as num?)?.toInt() ?? 0,
      uploadCapacityBps: (map['uploadCapacityBps'] as num?)?.toInt() ?? 0,
      downloadRPM: (map['downloadRPM'] as num?)?.toInt() ?? 0,
      uploadRPM: (map['uploadRPM'] as num?)?.toInt() ?? 0,
    );
  }
}
