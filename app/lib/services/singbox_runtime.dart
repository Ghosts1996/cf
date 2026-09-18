// Абстракция над движком туннеля.
//
// SingboxClient из flutter_singbox_client — MethodChannel-обёртка над
// нативным Android-плагином; на Windows любой его вызов падает с
// MissingPluginException. Поэтому tunnel_service.dart работает не с ним
// напрямую, а с этим интерфейсом:
//   - AndroidSingboxRuntime форвардит вызовы в SingboxClient;
//   - WindowsSingboxRuntime поднимает отдельный процесс sing-box.exe
//     в TUN-режиме.
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

  /// Поток журнала самого ядра пачками записей. Нужен для диагностики:
  /// причина «туннель поднят, а трафика нет» видна только здесь.
  Stream<dynamic> get coreLogStream;

  Future<dynamic> getServiceState();
  Future<dynamic> getTrafficStats();

  Future<void> checkConfig(String config);
  Future<void> connect(SessionOptions options);
  Future<void> disconnect();

  Future<bool> requestVPNPermission();

  /// Переключает активный outbound внутри группы-`selector` у работающего
  /// ядра, не останавливая туннель. Ради этого в конфиг и добавляется
  /// группа `proxy` (см. TunnelService._buildSingBoxConfig).
  ///
  /// Там, где переключение не поддерживается, реализация обязана бросить
  /// исключение: вызывающий (switchPreferredHost) ловит его и уходит на
  /// обычное переподключение. Тихий no-op выглядел бы для пользователя как
  /// успешная смена сервера, которой не было.
  Future<void> selectOutbound(String groupTag, String outboundTag);

  /// Просит работающее ядро прогнать проверку задержки по всем участникам
  /// группы: настоящее VLESS-рукопожатие до каждого сервера, а не TCP-стук
  /// в порт. Результаты приходят в [outboundGroupStream].
  Future<void> urlTest(String groupTag);

  /// Состояние групп outbound'ов: какой участник выбран сейчас и какая у
  /// каждого измеренная задержка (`urlTestDelayMs`). Обновляется после
  /// [urlTest] и при смене выбранного участника.
  Stream<dynamic> get outboundGroupStream;
}

SingboxRuntimeClient createSingboxRuntime() {
  if (Platform.isWindows) {
    return WindowsSingboxRuntime();
  }
  return AndroidSingboxRuntime();
}