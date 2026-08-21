/// Live traffic and runtime statistics emitted by the Sing-box service.
///
/// Emitted by [SingboxClient.trafficStatsStream] at approximately 1 Hz
/// while the service is running.
///
/// Use [TrafficStats.zero] as a safe initial value before the first event:
/// ```dart
/// TrafficStats stats = TrafficStats.zero;
/// client.trafficStatsStream.listen((s) => setState(() => stats = s));
/// ```
class TrafficStats {
  /// Current upload throughput in bits per second.
  final int uplinkBps;

  /// Current download throughput in bits per second.
  final int downlinkBps;

  /// Total bytes uploaded since the service started.
  final int uplinkTotalBytes;

  /// Total bytes downloaded since the service started.
  final int downlinkTotalBytes;

  /// Go runtime heap in use, in bytes.
  final int memoryBytes;

  /// Number of active Go goroutines.
  final int goroutines;

  /// Number of active inbound connections.
  final int connectionsIn;

  /// Number of active outbound connections.
  final int connectionsOut;

  /// Creates a [TrafficStats] snapshot. All fields default to zero.
  const TrafficStats({
    this.uplinkBps = 0,
    this.downlinkBps = 0,
    this.uplinkTotalBytes = 0,
    this.downlinkTotalBytes = 0,
    this.memoryBytes = 0,
    this.goroutines = 0,
    this.connectionsIn = 0,
    this.connectionsOut = 0,
  });

  /// Deserializes a [TrafficStats] from a platform channel map.
  factory TrafficStats.fromMap(Map<Object?, Object?> map) {
    return TrafficStats(
      uplinkBps: (map['uplinkBps'] as num?)?.toInt() ?? 0,
      downlinkBps: (map['downlinkBps'] as num?)?.toInt() ?? 0,
      uplinkTotalBytes: (map['uplinkTotalBytes'] as num?)?.toInt() ?? 0,
      downlinkTotalBytes: (map['downlinkTotalBytes'] as num?)?.toInt() ?? 0,
      memoryBytes: (map['memoryBytes'] as num?)?.toInt() ?? 0,
      goroutines: (map['goroutines'] as num?)?.toInt() ?? 0,
      connectionsIn: (map['connectionsIn'] as num?)?.toInt() ?? 0,
      connectionsOut: (map['connectionsOut'] as num?)?.toInt() ?? 0,
    );
  }

  /// A zero-value instance suitable as an initial state before the first event.
  static const zero = TrafficStats();
}
