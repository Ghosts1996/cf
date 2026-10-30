// Мост к ядру Xray, которое работает рядом с sing-box.
//
// sing-box остаётся главным ядром: он держит VPN-интерфейс, маршруты и группу
// локаций. Серверы, которые он подключить не умеет (например, с
// «шифрованием VLESS» — `encryption=mlkem768x25519plus…`, оно есть только в
// Xray), приложение отдаёт Xray: тот слушает SOCKS-порт на 127.0.0.1, а
// sing-box ходит в этот порт как в обычный outbound. Так в приложении
// работают все серверы, которые работают в Happ, а плагин ядра не меняется.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract class XrayRuntime {
  /// Есть ли Xray в этой сборке и на этой платформе.
  Future<bool> available();

  /// Запускает Xray с конфигом (JSON); прежний процесс гасится. false —
  /// не поднялся (причина — в [readLog]).
  Future<bool> start(String config);

  /// Упал — поднять снова с последним конфигом. Возвращает `running`,
  /// `restarted`, `failed` или `idle` (Xray сейчас не нужен).
  Future<String> ensureRunning();

  /// Гасит Xray и забывает конфиг.
  Future<void> stop();

  /// Новое в журнале Xray с прошлого вызова.
  Future<String> readLog();

  static XrayRuntime forPlatform() {
    if (!kIsWeb && Platform.isAndroid) return AndroidXrayRuntime();
    return const NoXrayRuntime();
  }
}

/// Там, где Xray нет: всё, что ему предназначалось, остаётся
/// неподдерживаемым, как и раньше.
class NoXrayRuntime implements XrayRuntime {
  const NoXrayRuntime();

  @override
  Future<bool> available() async => false;

  @override
  Future<bool> start(String config) async => false;

  @override
  Future<String> ensureRunning() async => 'idle';

  @override
  Future<void> stop() async {}

  @override
  Future<String> readLog() async => '';
}

class AndroidXrayRuntime implements XrayRuntime {
  static const _channel = MethodChannel('vpnonline/xray');
  static const _timeout = Duration(seconds: 8);

  bool? _available;

  @override
  Future<bool> available() async {
    final cached = _available;
    if (cached != null) return cached;
    try {
      final value = await _channel.invokeMethod<bool>('available').timeout(_timeout);
      return _available = value ?? false;
    } catch (_) {
      return _available = false;
    }
  }

  @override
  Future<bool> start(String config) async {
    try {
      return await _channel
              .invokeMethod<bool>('start', {'config': config})
              .timeout(_timeout) ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String> ensureRunning() async {
    try {
      return await _channel
              .invokeMethod<String>('ensureRunning')
              .timeout(_timeout) ??
          'failed';
    } catch (_) {
      return 'failed';
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop').timeout(_timeout);
    } catch (_) {}
  }

  @override
  Future<String> readLog() async {
    try {
      return await _channel.invokeMethod<String>('readLog').timeout(_timeout) ??
          '';
    } catch (_) {
      return '';
    }
  }
}
