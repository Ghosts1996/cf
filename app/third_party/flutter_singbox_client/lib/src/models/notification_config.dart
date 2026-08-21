/// Controls how the foreground service notification is displayed.
///
/// All fields are optional. Unset fields fall back to SDK defaults.
/// Pass an instance to [SessionOptions.notification] when connecting:
///
/// ```dart
/// await client.connect(SessionOptions(
///   config: configJson,
///   notification: NotificationConfig(
///     title: 'My VPN',
///     channelName: 'VPN Service',
///     showTrafficStats: true,
///     showStopButton: true,
///     stopButtonLabel: 'Disconnect',
///   ),
/// ));
/// ```
class NotificationConfig {
  /// Notification title (shown at the top of the notification).
  /// Default: "Singbox".
  final String? title;

  /// Android notification channel display name (visible in system Settings).
  /// Default: "VPN Service".
  final String? channelName;

  /// When true, the notification body is replaced with live upload/download
  /// speeds (e.g. "↑ 1.2 MB/s  ↓ 3.4 MB/s") on every stats tick (~1 s).
  /// When false, only the title is shown.
  /// Default: false.
  final bool showTrafficStats;

  /// When true, a stop button is shown in the notification.
  /// Tapping it stops the service.
  /// Default: false.
  final bool showStopButton;

  /// Label for the stop button. Only used when [showStopButton] is true.
  /// Default: "Stop".
  final String? stopButtonLabel;

  const NotificationConfig({
    this.title,
    this.channelName,
    this.showTrafficStats = false,
    this.showStopButton = false,
    this.stopButtonLabel,
  });

  Map<String, dynamic> toMap() => {
        if (title != null) 'title': title,
        if (channelName != null) 'channelName': channelName,
        'showTrafficStats': showTrafficStats,
        'showStopButton': showStopButton,
        if (stopButtonLabel != null) 'stopButtonLabel': stopButtonLabel,
      };
}
