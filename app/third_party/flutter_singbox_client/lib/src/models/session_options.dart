import 'service_state.dart';
import 'notification_config.dart';
import 'per_app_proxy_options.dart';
import 'memory_limit_config.dart';

/// All configuration needed to start the VPN or proxy service.
///
/// Pass to [SingboxClient.connect]. Every field is read at connect time —
/// the SDK has no persistent state, so the full options must be supplied
/// on every call.
///
/// ```dart
/// await client.connect(SessionOptions(
///   config: configJson,
///   networkMode: NetworkMode.vpn,
///   killSwitch: true,
///   notification: NotificationConfig(title: 'My VPN', showTrafficStats: true),
/// ));
/// ```
class SessionOptions {
  /// Sing-box JSON configuration string.
  ///
  /// Validate with [SingboxClient.checkConfig] before passing here.
  final String config;

  /// Selects the Android service used to run the core.
  ///
  /// [NetworkMode.vpn] opens a TUN device and requires VPN permission.
  /// [NetworkMode.proxy] runs a plain foreground service with no TUN device.
  /// Default: [NetworkMode.vpn].
  final NetworkMode networkMode;

  /// When `true`, apps may opt out of the VPN tunnel on a per-connection basis.
  ///
  /// VPN mode only. Automatically suppressed when [killSwitch] is `true`.
  /// Default: `false`.
  final bool allowBypass;

  /// When `true`, registers the Sing-box HTTP inbound as the device system proxy.
  ///
  /// VPN mode only. Requires Android 10+ (API 29+) and an HTTP inbound in [config].
  /// Default: `false`.
  final bool systemProxyEnabled;

  /// Per-app proxy (split tunneling) filter.
  ///
  /// VPN mode only. When `null`, all apps are routed through the tunnel normally.
  final PerAppProxyOptions? perAppProxy;

  /// Foreground service notification appearance.
  ///
  /// When `null`, SDK defaults are used.
  final NotificationConfig? notification;

  /// Go runtime soft memory cap.
  ///
  /// When `null`, no memory limit is applied.
  final MemoryLimitConfig? memoryLimit;

  /// When `true`, blocks all traffic at the OS level while the tunnel is down.
  ///
  /// VPN mode only, API 26+. When enabled, [allowBypass] is suppressed.
  /// Default: `false`.
  final bool killSwitch;

  /// Creates a [SessionOptions].
  const SessionOptions({
    required this.config,
    this.networkMode = NetworkMode.vpn,
    this.allowBypass = false,
    this.systemProxyEnabled = false,
    this.perAppProxy,
    this.notification,
    this.memoryLimit,
    this.killSwitch = false,
  });

  /// Serializes to the map passed over the platform channel.
  Map<String, dynamic> toMap() => {
        'config': config,
        'networkMode': networkMode.toValue(),
        'allowBypass': allowBypass,
        'systemProxyEnabled': systemProxyEnabled,
        if (perAppProxy != null) ...perAppProxy!.toMap(),
        if (perAppProxy == null) ...{
          'perAppProxyEnabled': false,
          'perAppProxyMode': 'exclude',
          'perAppProxyList': <String>[],
        },
        if (notification != null) 'notification': notification!.toMap(),
        ...(memoryLimit ?? const MemoryLimitConfig()).toMap(),
        'killSwitch': killSwitch,
      };
}
