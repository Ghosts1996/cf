import 'package:flutter/foundation.dart';

/// Предпочитаемый сервер для подключения (ConnectScreen).
///
/// Это клиентское предпочтение — какую локацию показывать и использовать по
/// умолчанию. На покупку и биллинг не влияет: ключ выдаётся сразу на все
/// локации бандла.
class SelectedServer {
  SelectedServer._();

  static final ValueNotifier<String?> hostName = ValueNotifier<String?>(null);
  static final ValueNotifier<String?> displayName = ValueNotifier<String?>(null);

  static void select(String hostName_, String displayName_) {
    hostName.value = hostName_;
    displayName.value = displayName_;
  }
}
