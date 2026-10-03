// Клиент встроенного HTTP-API ядра (Clash API) на 127.0.0.1.
//
// На Android приложение управляет ядром через командный канал libbox:
// переключает сервер внутри группы, просит замер задержки, закрывает
// соединения. У sing-box.exe на Windows такого канала нет, и всё это там
// просто не работало: туннель вставал на первый сервер списка и, если тот
// был мёртв, так на нём и оставался — «подключено, а интернета нет». Те же
// три действия есть в Clash API, который на Windows и так включён ради
// счётчиков трафика.
import 'dart:convert';

import 'package:http/http.dart' as http;

class ClashApiClient {
  ClashApiClient({required this.port, http.Client? client})
      : _http = client ?? http.Client();

  final int port;
  final http.Client _http;

  Uri _uri(String path, [Map<String, String>? query]) => Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: path,
      queryParameters: query);

  /// Делает [tag] активным участником группы-селектора [group].
  Future<void> select(String group, String tag) async {
    final res = await _http
        .put(_uri('/proxies/${Uri.encodeComponent(group)}'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'name': tag}))
        .timeout(const Duration(seconds: 5));
    if (res.statusCode >= 300) {
      throw StateError(
          'Ядро не переключило $group на $tag: ${res.statusCode} ${res.body}');
    }
  }

  /// Участники группы — в том порядке, в каком они в конфиге.
  Future<List<String>> members(String group) async {
    final res = await _http
        .get(_uri('/proxies/${Uri.encodeComponent(group)}'))
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) return const <String>[];
    final body = jsonDecode(res.body);
    final all = body is Map ? body['all'] : null;
    return all is List ? all.map((e) => '$e').toList() : const <String>[];
  }

  /// Задержка одного участника через ядро; null — не ответил.
  Future<int?> delay(String tag,
      {required String url,
      Duration timeout = const Duration(seconds: 5)}) async {
    try {
      final res = await _http
          .get(_uri('/proxies/${Uri.encodeComponent(tag)}/delay',
              {'url': url, 'timeout': '${timeout.inMilliseconds}'}))
          .timeout(timeout + const Duration(seconds: 2));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      final value = body is Map ? body['delay'] : null;
      return value is num && value > 0 ? value.toInt() : null;
    } catch (_) {
      return null;
    }
  }

  /// Замер задержки всех участников группы, каждого отдельно и разом.
  ///
  /// Не через `/group/{name}/delay`: пока группа делает собственную
  /// проверку (а сразу после старта ядра она её делает всегда), этот вызов
  /// молча отдаёт пустой ответ — проверено на настоящем sing-box. Ответившие
  /// — в карте, не ответившие в неё не попадают.
  Future<Map<String, int>> groupDelay(String group,
      {required String url,
      Duration timeout = const Duration(seconds: 5)}) async {
    final tags = await members(group);
    final results = await Future.wait(
        tags.map((t) => delay(t, url: url, timeout: timeout)));
    return {
      for (var i = 0; i < tags.length; i++)
        if (results[i] != null) tags[i]: results[i]!,
    };
  }

  /// Закрывает все открытые соединения ядра.
  Future<void> closeAllConnections() async {
    await _http
        .delete(_uri('/connections'))
        .timeout(const Duration(seconds: 5));
  }

  void close() => _http.close();
}
