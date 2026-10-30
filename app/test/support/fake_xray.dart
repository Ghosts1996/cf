import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vpnonline_app/services/xray_runtime.dart';

/// Заглушка ядра Xray: по конфигу открывает те SOCKS-порты, что в нём
/// указаны (приложение ждёт, пока они начнут слушаться), и запоминает всё,
/// что с ней делали.
///
/// Серверы, чьи адреса перечислены в [answering], «работают»: их SOCKS-вход
/// проходит рукопожатие с логином и паролем и отвечает на HTTP-запросы
/// `204`. Остальные входы рвут соединение сразу.
class FakeXray implements XrayRuntime {
  FakeXray({
    this.isAvailable = true,
    this.startSucceeds = true,
    Set<String>? answering,
  }) : answering = answering ?? <String>{};

  bool isAvailable;
  bool startSucceeds;
  final Set<String> answering;
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
    final outbounds = (decoded['outbounds'] as List).cast<Map<String, dynamic>>();
    final inbounds = (decoded['inbounds'] as List).cast<Map<String, dynamic>>();
    for (var i = 0; i < inbounds.length; i++) {
      final port = inbounds[i]['port'] as int;
      final settings = outbounds[i]['settings'] as Map<String, dynamic>;
      final server = ((settings['vnext'] ?? settings['servers']) as List).first
          as Map<String, dynamic>;
      final works = answering.contains(server['address']);
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      socket.listen((client) =>
          works ? unawaited(_serveSocks(client)) : client.destroy());
      _listening.add(socket);
    }
    return true;
  }

  /// SOCKS5 с логином/паролем и HTTP-ответ 204 на каждый запрос.
  static Future<void> _serveSocks(Socket client) async {
    final buffer = <int>[];
    final more = StreamController<void>.broadcast();
    client.listen((data) {
      buffer.addAll(data);
      more.add(null);
    }, onDone: () => more.close(), onError: (_) => more.close());
    Future<List<int>> read(int n) async {
      while (buffer.length < n) {
        await more.stream.first;
      }
      final out = buffer.sublist(0, n);
      buffer.removeRange(0, n);
      return out;
    }

    try {
      final greeting = await read(2);
      await read(greeting[1]);
      client.add([5, 2]);
      final auth = await read(2);
      await read(auth[1]);
      final passLength = (await read(1))[0];
      await read(passLength);
      client.add([1, 0]);
      final request = await read(5);
      await read(request[4] + 2);
      client.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
      while (true) {
        while (!utf8.decode(buffer, allowMalformed: true).contains('\r\n\r\n')) {
          await more.stream.first;
        }
        final text = utf8.decode(buffer, allowMalformed: true);
        final end = text.indexOf('\r\n\r\n') + 4;
        buffer.removeRange(0, utf8.encode(text.substring(0, end)).length);
        client.add(utf8.encode('HTTP/1.1 204 No Content\r\n\r\n'));
      }
    } catch (_) {
      client.destroy();
    }
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
