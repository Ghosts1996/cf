// [НОВОЕ — Windows real-VPN] Абстракция над "движком" туннеля.
//
// Зачем этот файл вообще нужен, если раньше в tunnel_service.dart просто
// стояло `final SingboxClient _client = SingboxClient();`?
//
// `SingboxClient` из пакета flutter_singbox_client — это MethodChannel-обёртка
// над НАТИВНЫМ Android-плагином (Kotlin + libbox). У пакета сегодня нет
// нативной реализации под Windows — на Windows вызов любого метода
// `SingboxClient` падает `MissingPluginException`, потому что на той стороне
// платформенного канала просто некому ответить.
//
// Здесь этот класс НЕ пытается "почитить" сам пакет и не трогает Android-код.
// Вместо этого — один уровень косвенности:
//   - `SingboxRuntimeClient` — интерфейс с ровно тем набором методов/потоков,
//     которые реально вызываются в tunnel_service.dart (проверено по всем
//     местам использования `_client.*` в файле).
//   - `AndroidSingboxRuntime` (см. singbox_runtime_android.dart) — тонкая
//     обёртка, 1-в-1 форвардящая каждый вызов в тот самый `SingboxClient`,
//     что был раньше. Поведение на Android НЕ меняется ни на бит.
//   - `WindowsSingboxRuntime` (см. singbox_runtime_windows.dart) — реальная
//     Windows-реализация поверх процесса sing-box.exe (TUN-режим,
//     VLESS/Reality), см. докстринг в том файле.
//
// В tunnel_service.dart единственное изменение — какой класс создаётся в
// поле `_client` (было `SingboxClient()`, стало `createSingboxRuntime()`).
// Все остальные ~40 мест, где `_client.connect(...)`, `.disconnect()`,
// `.serviceStateStream` и т.д. — не тронуты вообще.
import 'dart:io' show Platform;

import 'package:flutter_singbox_client/flutter_singbox_client.dart'
    show SessionOptions;

import 'singbox_runtime_android.dart';
import 'singbox_runtime_windows.dart';

abstract class SingboxRuntimeClient {
  Future<void> initialize();

  Stream<dynamic> get serviceStateStream;
  Stream<dynamic> get trafficStatsStream;
  Stream<dynamic> get faultStream;

  Future<dynamic> getServiceState();
  Future<dynamic> getTrafficStats();

  Future<void> checkConfig(String config);
  Future<void> connect(SessionOptions options);
  Future<void> disconnect();

  Future<bool> requestVPNPermission();
}

SingboxRuntimeClient createSingboxRuntime() {
  if (Platform.isWindows) {
    return WindowsSingboxRuntime();
  }
  // Android (и любая другая платформа, где раньше стоял голый SingboxClient) —
  // поведение полностью прежнее.
  return AndroidSingboxRuntime();
}