/// Lifecycle state of the Sing-box VPN or proxy service.
///
/// Emitted by [SingboxClient.serviceStateStream] on every transition.
enum ServiceState {
  /// Service is not running. Safe to call [SingboxClient.connect].
  stopped,

  /// Service is starting up. Do not call [connect] or [disconnect].
  starting,

  /// Service is running and fully connected.
  started,

  /// Service is shutting down. Do not call [connect] or [disconnect].
  stopping;

  /// Parses the integer value sent over the platform channel.
  static ServiceState fromInt(int value) {
    switch (value) {
      case 0:
        return stopped;
      case 1:
        return starting;
      case 2:
        return started;
      case 3:
        return stopping;
      default:
        return stopped;
    }
  }

  /// Serializes to the integer value expected by the platform channel.
  int toInt() => index;

  /// `true` when the service is in the [started] state.
  bool get isRunning => this == started;

  /// `true` when the service is [stopped] — safe to call [SingboxClient.connect].
  bool get isIdle => this == stopped;

  /// `true` when the service is [starting] or [stopping].
  bool get isTransitioning => this == starting || this == stopping;
}

/// Selects the Android service used to run the Sing-box core.
enum NetworkMode {
  /// Full device VPN tunnel via a TUN device. Routes all device traffic
  /// through the Sing-box Go core. Requires Android VPN permission.
  vpn,

  /// HTTP/SOCKS proxy only. No TUN device is opened. Apps must explicitly
  /// route through the proxy, or system proxy must be enabled separately.
  proxy;

  /// Parses the string value sent over the platform channel.
  static NetworkMode fromString(String value) {
    switch (value) {
      case 'vpn':
        return vpn;
      case 'proxy':
        return proxy;
      default:
        return vpn;
    }
  }

  /// Serializes to the string value expected by the platform channel.
  String toValue() => name;
}
