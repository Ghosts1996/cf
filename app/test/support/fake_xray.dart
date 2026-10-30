import 'dart:convert';
import 'dart:io';

import 'package:vpnonline_app/services/xray_runtime.dart';

/// Заглушка ядра Xray: по конфигу открывает те SOCKS-порты, что в нём
/// указаны (приложение ждёт, пока они начнут слушаться), и запоминает всё,
/// что с ней делали.
class FakeXray implements XrayRuntime {
  FakeXray({this.isAvailable = true, this.startSucceeds = true});

  bool isAvailable;
  bool startSucceeds;
  final List<String> configs = [];
  int stops = 0;
  final List<ServerSocket> _listening = [];

  bool get running => _listening.isNotEmpty;

  @override
  Future<bool> available() async => isAvailable;

  @override
  Future<bool> start(String config) async {
    await _close();
    configs.add(config);
    if (!startSucceeds) return false;
    final decoded = jsonDecode(config) as Map<String, dynamic>;
    for (final inbound in decoded['inbounds'] as List) {
      final port = (inbound as Map<String, dynamic>)['port'] as int;
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      socket.listen((client) => client.destroy());
      _listening.add(socket);
    }
    return true;
  }

  @override
  Future<String> ensureRunning() async => running ? 'running' : 'idle';

  @override
  Future<void> stop() async {
    stops++;
    await _close();
  }

  @override
  Future<String> readLog() async =>
      startSucceeds ? '' : 'Failed to start: app/proxyman/inbound: failed';

  Future<void> _close() async {
    for (final socket in _listening) {
      await socket.close();
    }
    _listening.clear();
  }
}
