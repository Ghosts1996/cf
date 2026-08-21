/// Controls which apps are included in or excluded from the VPN tunnel.
enum PerAppProxyMode {
  /// Only the listed packages are routed through the tunnel.
  include,

  /// All apps are routed through the tunnel **except** the listed packages.
  exclude,
}

/// Per-app proxy (split tunneling) configuration for [SessionOptions].
///
/// Pass as [SessionOptions.perAppProxy] to restrict which apps are routed
/// through the VPN tunnel. When `null` (the default), all apps are routed
/// normally and no per-app filtering is applied.
///
/// ```dart
/// // Exclude a single internal app from the tunnel
/// PerAppProxyOptions(
///   mode: PerAppProxyMode.exclude,
///   packages: ['com.mycompany.internalapp'],
/// )
///
/// // Route only specific apps through the VPN
/// PerAppProxyOptions(
///   mode: PerAppProxyMode.include,
///   packages: ['org.telegram.messenger', 'com.android.chrome'],
/// )
/// ```
class PerAppProxyOptions {
  /// Whether to include or exclude the listed [packages].
  final PerAppProxyMode mode;

  /// Android package names to include or exclude based on [mode].
  final List<String> packages;

  /// Creates a [PerAppProxyOptions].
  const PerAppProxyOptions({
    this.mode = PerAppProxyMode.exclude,
    this.packages = const [],
  });

  /// Serializes to the map passed over the platform channel.
  Map<String, dynamic> toMap() => {
        'perAppProxyEnabled': true,
        'perAppProxyMode': mode.name,
        'perAppProxyList': packages,
      };
}
