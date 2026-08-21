/// Current phase of a STUN NAT-type test.
enum StunPhase {
  /// Performing the initial STUN binding request.
  binding,

  /// Testing NAT mapping behaviour.
  natMapping,

  /// Testing NAT filtering behaviour.
  natFiltering,

  /// Test is complete.
  done,

  /// Phase could not be determined.
  unknown,
}

/// Progress event emitted during a STUN test.
///
/// Received via [SingboxClient.stunProgressStream].
/// Check [isRunning] to detect the final result emission:
/// ```dart
/// _sub = client.stunProgressStream.listen((p) {
///   setState(() => _progress = p);
///   if (!p.isRunning) _sub = null;
/// });
/// ```
class StunProgress {
  /// Whether the test is still running. `false` on the final result emission.
  final bool isRunning;

  /// Current test phase.
  final StunPhase phase;

  /// Detected public IP address and port (e.g. `'203.0.113.1:54321'`).
  final String externalAddress;

  /// Round-trip latency to the STUN server in milliseconds.
  final int latencyMs;

  /// NAT mapping description. Empty string until the phase completes.
  final String natMapping;

  /// NAT filtering description. Empty string until the phase completes.
  final String natFiltering;

  /// `false` if NAT type detection was inconclusive.
  final bool natTypeSupported;

  /// Creates a [StunProgress].
  const StunProgress({
    required this.isRunning,
    required this.phase,
    required this.externalAddress,
    required this.latencyMs,
    required this.natMapping,
    required this.natFiltering,
    required this.natTypeSupported,
  });

  /// Deserializes a [StunProgress] from a platform channel map.
  factory StunProgress.fromMap(Map<Object?, Object?> map) {
    return StunProgress(
      isRunning: map['isRunning'] as bool? ?? true,
      phase: _parsePhase(map['phase'] as String? ?? ''),
      externalAddress: map['externalAddress'] as String? ?? '',
      latencyMs: (map['latencyMs'] as num?)?.toInt() ?? 0,
      natMapping: map['natMapping'] as String? ?? '',
      natFiltering: map['natFiltering'] as String? ?? '',
      natTypeSupported: map['natTypeSupported'] as bool? ?? false,
    );
  }

  static StunPhase _parsePhase(String raw) {
    switch (raw) {
      case 'binding':
        return StunPhase.binding;
      case 'nat_mapping':
        return StunPhase.natMapping;
      case 'nat_filtering':
        return StunPhase.natFiltering;
      case 'done':
        return StunPhase.done;
      default:
        return StunPhase.unknown;
    }
  }
}
