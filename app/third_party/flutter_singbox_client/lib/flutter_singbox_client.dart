/// flutter_singbox_client — Full Sing-box engine SDK for Flutter/Android.
///
/// Usage:
/// ```dart
/// import 'package:flutter_singbox_client/flutter_singbox_client.dart';
///
/// final client = SingboxClient();
/// await client.initialize();
/// await client.requestVPNPermission();
/// await client.connect(SessionOptions(...));
/// ```
library;

export 'src/singbox_client.dart';
export 'src/models/index.dart';
