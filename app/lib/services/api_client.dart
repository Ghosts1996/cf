import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Клиент к РЕАЛЬНОМУ API твоего сайта/бота (shopbot/src/shop_bot/
/// webhook_server/api.py, Blueprint '/api/v1'), а не к придуманному
/// бэкенду. Все пути и формы запросов/ответов ниже — проверено чтением
/// реального api.py из твоего бэкапа, а не предположение.
///
/// [ПОДТВЕРЖДЕНО ТОБОЙ] Flask-API (/api/v1/...) висит на том же хосте,
/// что и админ-панель — api.vpnonline.shop. Базовый URL ниже больше не
/// предположение.
class ApiClient {
  ApiClient._({required this.baseUrl, required this.apiKey});

  static ApiClient? _instance;

  /// Вызвать ОДИН раз при старте приложения (main.dart), до runApp —
  /// см. пример инициализации в конце файла.
  static void init({required String apiKey, String baseUrl = 'https://api.vpnonline.shop/api/v1'}) {
    _instance = ApiClient._(baseUrl: baseUrl, apiKey: apiKey);
  }

  /// Доступ из экранов: `ApiClient.instance.getKeys()` и т.д.
  static ApiClient get instance {
    final i = _instance;
    if (i == null) {
      throw StateError('ApiClient.init() не был вызван перед использованием — вызови его в main() до runApp().');
    }
    return i;
  }

  /// [ВАЖНО] apiKey передаётся при сборке через
  /// `flutter build apk --dart-define=SHOPBOT_API_KEY=<реальный ключ из .env>`
  /// — НЕ пишется буквально в этот файл и не коммитится в git. Это не
  /// делает ключ секретом в полном смысле: он всё равно физически попадёт
  /// в собранный APK и его можно достать реверс-инжинирингом (так работает
  /// любой статический секрет в мобильном клиенте). Настоящая защита
  /// конкретного пользователя — токен сессии (Authorization: Bearer),
  /// который знанием одного только apiKey не подделать. Подробнее — в
  /// комментарии к require_api_key в патче backend/api.py.

  final String baseUrl;
  final String apiKey;
  String? _token;

  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'vpnonline_session_token_v1';

  bool get isAuthenticated => _token != null;

  /// Восстановление сессии при старте приложения — из защищённого хранилища
  /// (Android Keystore / iOS Keychain), не из SharedPreferences.
  Future<bool> restoreSession() async {
    final saved = await _storage.read(key: _tokenKey);
    if (saved != null && saved.isNotEmpty) {
      _token = saved;
      return true;
    }
    return false;
  }

  Future<void> _setToken(String token) async {
    _token = token;
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<void> logout() async {
    _token = null;
    await _storage.delete(key: _tokenKey);
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-API-Key': apiKey,
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  // ------------------------------------------------------------- auth

  /// POST /auth/register/send-code {email}
  Future<void> registerSendCode(String email) async {
    final res = await http.post(_u('/auth/register/send-code'),
        headers: _headers, body: jsonEncode({'email': email}));
    _checkOk(res);
  }

  /// POST /auth/register {email, password, code, username?}
  /// Реальный ответ содержит token сразу — регистрация = вход одним шагом.
  Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    required String code,
    String? username,
  }) async {
    final res = await http.post(
      _u('/auth/register'),
      headers: _headers,
      body: jsonEncode({
        'email': email,
        'password': password,
        'code': code,
        if (username != null) 'username': username,
      }),
    );
    _checkOk(res);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    await _setToken(data['token'] as String);
    return data['user'] as Map<String, dynamic>;
  }

  /// POST /auth/reset-password/send-code {email}
  /// [ИСПРАВЛЕНО в патче backend] раньше отвечал 404 если email не найден —
  /// это давало возможность перебором узнавать зарегистрированные email
  /// (enumeration). После патча ответ всегда {"ok": true}, независимо от
  /// того, существует ли аккаунт — здесь ничего дополнительно делать не
  /// нужно, просто не полагайся на код ответа как признак "email существует".
  Future<void> resetPasswordSendCode(String email) async {
    final res = await http.post(_u('/auth/reset-password/send-code'),
        headers: _headers, body: jsonEncode({'email': email}));
    _checkOk(res);
  }

  /// POST /auth/reset-password/confirm {email, code, new_password}
  Future<void> resetPasswordConfirm({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final res = await http.post(
      _u('/auth/reset-password/confirm'),
      headers: _headers,
      body: jsonEncode({'email': email, 'code': code, 'new_password': newPassword}),
    );
    _checkOk(res);
  }

  /// POST /auth/login {email, password}
  Future<Map<String, dynamic>> login({required String email, required String password}) async {
    final res = await http.post(
      _u('/auth/login'),
      headers: _headers,
      body: jsonEncode({'email': email, 'password': password}),
    );
    _checkOk(res);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    await _setToken(data['token'] as String);
    return data['user'] as Map<String, dynamic>;
  }

  // ------------------------------------------------------------- profile / balance / referral

  /// GET /user/profile — баланс, реферальная статистика и ссылка на
  /// приглашение приходят ОДНИМ вызовом (так устроен реальный API, отдельного
  /// эндпоинта /referral или /balance на сервере нет — не выдумываем лишний).
  Future<Map<String, dynamic>> getProfile() async {
    final res = await http.get(_u('/user/profile'), headers: _headers);
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['user'] as Map<String, dynamic>;
  }

  /// POST /user/trial — активировать бесплатный пробный период.
  Future<Map<String, dynamic>> claimTrial() async {
    final res = await http.post(_u('/user/trial'), headers: _headers);
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['key'] as Map<String, dynamic>;
  }

  // ------------------------------------------------------------- keys

  /// GET /user/keys
  Future<List<dynamic>> getKeys() async {
    final res = await http.get(_u('/user/keys'), headers: _headers);
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['keys'] as List<dynamic>;
  }

  /// POST /key/upgrade-devices {key_id} — докупить слот устройства (+50 RUB,
  /// максимум 4 на ключ — лимиты те же, что реально заданы на сервере).
  Future<int> upgradeKeyDevices(int keyId) async {
    final res = await http.post(_u('/key/upgrade-devices'),
        headers: _headers, body: jsonEncode({'key_id': keyId}));
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['new_limit'] as int;
  }

  /// POST /key/create {plan_id} — списывает баланс и выдаёt ключ сразу на
  /// всех хостах (GLOBAL bundle), это уже так устроено на сервере.
  Future<Map<String, dynamic>> createKey(int planId) async {
    final res = await http.post(_u('/key/create'),
        headers: _headers, body: jsonEncode({'plan_id': planId}));
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['key'] as Map<String, dynamic>;
  }

  /// POST /key/extend {key_id, plan_id}
  Future<Map<String, dynamic>> extendKey({required int keyId, required int planId}) async {
    final res = await http.post(_u('/key/extend'),
        headers: _headers, body: jsonEncode({'key_id': keyId, 'plan_id': planId}));
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['key'] as Map<String, dynamic>;
  }

  // ------------------------------------------------------------- servers / plans

  /// GET /hosts — список локаций. Сервер уже сам убирает чувствительные
  /// поля (host_username/host_pass/ssh-доступ) перед ответом — это видно в
  /// самом api.py, ничего дополнительно фильтровать на клиенте не нужно.
  /// Новая локация, добавленная тобой в панель (таблица xui_hosts),
  /// появится здесь автоматически, без изменений кода — так уже работает
  /// сегодня на реальном сервере.
  Future<List<dynamic>> getHosts() async {
    final res = await http.get(_u('/hosts'), headers: _headers);
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['hosts'] as List<dynamic>;
  }

  /// GET /plans — вернёт Map<host_name, List<plan>>, включая специальный
  /// ключ "GLOBAL" (единый тариф на бандл из всех локаций — то, что мы
  /// показываем на главном экране покупки).
  Future<Map<String, dynamic>> getPlans() async {
    final res = await http.get(_u('/plans'), headers: _headers);
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['plans'] as Map<String, dynamic>;
  }

  // ------------------------------------------------------------- billing

  /// POST /billing/topup {amount, method: 'yookassa'|'cryptobot'} -> pay_url
  Future<String> billingTopup({required double amount, required String method}) async {
    final res = await http.post(
      _u('/billing/topup'),
      headers: _headers,
      body: jsonEncode({'amount': amount, 'method': method}),
    );
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['pay_url'] as String;
  }

  void _checkOk(http.Response res) {
    if (res.statusCode >= 400) {
      String message = 'Ошибка сервера (${res.statusCode})';
      try {
        final body = jsonDecode(res.body);
        if (body is Map && body['error'] != null) message = body['error'].toString();
      } catch (_) {
        // тело не JSON — оставляем общее сообщение
      }
      throw ApiException(res.statusCode, message);
    }
  }
}

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => message;
}

/// Пример инициализации в main.dart (до runApp):
///
/// void main() {
///   ApiClient.init(apiKey: const String.fromEnvironment('SHOPBOT_API_KEY'));
///   runApp(const VpnOnlineApp());
/// }
///
/// Сборка: flutter build apk --release --dart-define=SHOPBOT_API_KEY=<ключ из .env сервера>

