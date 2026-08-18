import 'package:flutter/foundation.dart';

/// Предпочитаемый сервер для ПОДКЛЮЧЕНИЯ (ConnectScreen) — не для покупки.
///
/// [ИЗМЕНЕНО v4] До этой версии сюда же писался host_name, который был
/// ОБЯЗАН попасть в /v1/orders при покупке — это устарело: покупка теперь
/// выдаёт ключ сразу на всех локациях бандла (см. plans_screen.dart и
/// backend/app/services/provisioning.py), выбор сервера для покупки не
/// нужен. Это состояние осталось только как клиентское предпочтение —
/// какую локацию показывать/использовать по умолчанию на экране
/// подключения — и не влияет на биллинг.
class SelectedServer {
  SelectedServer._();

  static final ValueNotifier<String?> hostName = ValueNotifier<String?>(null);
  static final ValueNotifier<String?> displayName = ValueNotifier<String?>(null);

  static void select(String hostName_, String displayName_) {
    hostName.value = hostName_;
    displayName.value = displayName_;
  }
}
