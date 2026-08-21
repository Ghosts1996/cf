/// Availability and enabled state of the system HTTP proxy.
///
/// Returned by [SingboxClient.getSystemProxyStatus].
/// System proxy requires VPN mode, Android 10+ (API 29+), and an HTTP inbound
/// in the active config. When any of these conditions are not met,
/// [available] is `false`.
class SystemProxyStatus {
  /// Whether the system proxy feature is available in the current session.
  ///
  /// `false` when running in proxy mode, on API < 29, or when the active
  /// config has no HTTP inbound.
  final bool available;

  /// Whether the system proxy is currently active.
  final bool enabled;

  /// Creates a [SystemProxyStatus].
  const SystemProxyStatus({
    required this.available,
    required this.enabled,
  });

  /// Deserializes a [SystemProxyStatus] from a platform channel map.
  factory SystemProxyStatus.fromMap(Map<Object?, Object?> map) {
    return SystemProxyStatus(
      available: map['available'] as bool? ?? false,
      enabled: map['enabled'] as bool? ?? false,
    );
  }
}
