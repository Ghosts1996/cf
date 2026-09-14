import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'local_prefs.dart';

/// Клиент к Flask-API бота (shopbot/src/shop_bot/webhook_server/api.py,
/// Blueprint '/api/v1'). Тот же хост, что и админ-панель — api.vpnonline.su.
class ApiClient {
  ApiClient._({required this.baseUrl, required this.apiKey});

  static ApiClient? _instance;

  /// Вызвать ОДИН раз при старте приложения (main.dart), до runApp —
  /// см. пример инициализации в конце файла.
  static void init({required String apiKey, String baseUrl = 'https://api.vpnonline.su/api/v1'}) {
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

  /// apiKey передаётся при сборке:
  /// `flutter build apk --dart-define=SHOPBOT_API_KEY=<ключ из .env>` — в этот
  /// файл он не пишется и в git не попадает. Полноценным секретом это его не
  /// делает: ключ физически лежит в APK и достаётся реверс-инжинирингом, как
  /// любой статический секрет в мобильном клиенте. Конкретного пользователя
  /// защищает токен сессии (Authorization: Bearer), который одним apiKey не
  /// подделать.

  final String baseUrl;
  final String apiKey;
  String? _token;

  // Один переиспользуемый http.Client на всё время работы приложения.
  // Статические http.get()/http.post() заводят новый IOClient на каждый
  // вызов — полный TLS-хендшейк без keep-alive, сотни лишних миллисекунд на
  // мобильной сети. Плюс каждый запрос обязан уложиться в _requestTimeout:
  // без него при слабом сигнале запрос висит до дефолтного таймаута ОС
  // (на Android/iOS это бывает больше минуты), и экран замирает в спиннере
  // именно тогда, когда сеть хуже всего.
  static final http.Client _client = http.Client();
  static const Duration _requestTimeout = Duration(seconds: 15);

  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'vpnonline_session_token_v1';

  // restoreSession() ниже только проверяет, что в защищённом хранилище лежит
  // непустая строка, и никогда не спрашивает сервер, жив ли токен. Токен,
  // подписанный другим Flask SECRET_KEY (переезд на другой сервер, ключ
  // пересоздан заново), даёт 401 "Invalid token signature" на каждый запрос,
  // и так и остаётся в хранилище навсегда: следующий запуск снова его
  // "одобряет", приложение снова открывает RootShell, кнопка "Повторить"
  // повторяет тот же мёртвый токен.
  //
  // Поэтому любой 401 трактуется как недействительная сессия: токен сразу
  // стирается, а слушатели (main.dart) переводят приложение на экран входа.
  // Счётчик, а не bool, — чтобы срабатывало каждый раз: ValueNotifier не
  // уведомляет при установке того же значения.
  static final ValueNotifier<int> sessionExpired = ValueNotifier<int>(0);

  // ══════════════════════════════════════════════════════════════════
  // Единый слой загрузки: дедупликация + память + диск
  // ══════════════════════════════════════════════════════════════════
  //
  // Экраны не делят между собой ничего — каждый в initState() сам идёт в
  // сеть. А RootShell (main.dart) монтирует все пять вкладок одним кадром
  // при холодном старте, и за первую секунду уходит:
  //
  //   ConnectScreen  -> getKeys()
  //   KeysScreen     -> getKeys()
  //   BalanceScreen  -> getProfile() + getKeys()
  //   ServersScreen  -> getHosts()  + getKeys()
  //   MenuScreen     -> getProfile() + getKeys()
  //
  // Семь запросов, из которых четыре — один и тот же GET /user/keys за один
  // и тот же ответ. На Wi-Fi это незаметно; на мобильной сети они делят
  // один канал, каждый со своим таймаутом, и вкладка висит в спиннере,
  // потому что её ответ стоит в очереди за тремя копиями самого себя.
  //
  // Поэтому здесь три уровня:
  //
  //  1. Дедупликация. Пока запрос за ресурс летит, все последующие вызовы
  //     получают ту же Future. Четыре одновременных getKeys() при старте —
  //     один сетевой запрос и четыре получателя ответа.
  //  2. Память. Ответ живёт _memoryTtl (20 секунд): переключение вкладок в
  //     эти секунды новых запросов не порождает. Дольше держать нельзя —
  //     баланс и срок ключа должны оставаться живыми данными.
  //  3. Диск. Последний успешный ответ сохраняется в SharedPreferences и
  //     отдаётся, когда сеть отвалилась (ApiException.statusCode == 0 —
  //     таймаут, нет соединения, туннель поднят, но трафик не идёт). Это и
  //     убирает "НЕТ КЛЮЧА" у человека с двумя активными ключами.
  //
  // С диска отвечаем только на сетевой сбой. 401, прочие 4xx и 5xx —
  // настоящие ответы сервера, они пробрасываются как есть, иначе приложение
  // показывало бы старые данные поверх реальной проблемы с аккаунтом.
  //
  // Сигнатуры getKeys()/getProfile()/getHosts()/getPlans() при этом не
  // менялись. Кому нужно знать, свежие данные или сохранённые, читает
  // keysFromCache/profileFromCache/hostsFromCache.

  static const _cacheKeys = 'keys';
  static const _cacheProfile = 'profile';
  static const _cacheHosts = 'hosts';
  static const _cachePlans = 'plans';

  static const Map<String, String> _diskKeyByCache = {
    _cacheKeys: PrefKeys.cachedKeysJson,
    _cacheProfile: PrefKeys.cachedProfileJson,
    _cacheHosts: PrefKeys.cachedHostsJson,
    _cachePlans: PrefKeys.cachedPlansJson,
  };

  static const Duration _memoryTtl = Duration(seconds: 20);

  final Map<String, Future<dynamic>> _inFlight = {};
  final Map<String, _CachedPayload> _memory = {};
  final Set<String> _servedFromDisk = {};

  /// true, если последний отданный ответ пришёл не от сервера, а из
  /// сохранённой копии. Экран может честно подписать данные вместо того,
  /// чтобы выдавать вчерашний баланс за сегодняшний.
  bool get keysFromCache => _servedFromDisk.contains(_cacheKeys);
  bool get profileFromCache => _servedFromDisk.contains(_cacheProfile);
  bool get hostsFromCache => _servedFromDisk.contains(_cacheHosts);

  /// Когда данные были реально получены (или сохранены, если отданы с
  /// диска). `null` — этого ресурса ещё не было ни разу.
  DateTime? get keysUpdatedAt => _memory[_cacheKeys]?.at;
  DateTime? get profileUpdatedAt => _memory[_cacheProfile]?.at;

  Future<T> _cached<T>(String cacheKey, Future<T> Function() fetch) {
    final inMemory = _memory[cacheKey];
    if (inMemory != null &&
        DateTime.now().difference(inMemory.at) < _memoryTtl) {
      return Future<T>.value(inMemory.data as T);
    }
    final running = _inFlight[cacheKey];
    if (running != null) return running.then((value) => value as T);
    final future = _fetchAndStore<T>(cacheKey, fetch);
    _inFlight[cacheKey] = future;
    return future;
  }

  Future<T> _fetchAndStore<T>(
      String cacheKey, Future<T> Function() fetch) async {
    try {
      final data = await fetch();
      _memory[cacheKey] = _CachedPayload(data, DateTime.now());
      _servedFromDisk.remove(cacheKey);
      unawaited(_writeDiskCache(cacheKey, data));
      return data;
    } on ApiException catch (e) {
      // Только сетевой сбой. Ответ сервера с кодом (401/403/404/5xx) —
      // настоящая ошибка, её подменять сохранёнными данными нельзя.
      if (e.statusCode != 0) rethrow;
      final fallback = _memory[cacheKey] ?? await _readDiskCache(cacheKey);
      if (fallback == null) rethrow;
      // Отметку времени НЕ обновляем: значение осталось старым, и уже
      // следующий вызов после истечения TTL снова пойдёт в сеть, а не
      // застрянет на сохранённой копии.
      _memory[cacheKey] = fallback;
      _servedFromDisk.add(cacheKey);
      return fallback.data as T;
    } finally {
      _inFlight.remove(cacheKey);
    }
  }

  Future<void> _writeDiskCache(String cacheKey, dynamic data) async {
    final diskKey = _diskKeyByCache[cacheKey];
    if (diskKey == null) return;
    try {
      await LocalPrefs.instance.setString(
        diskKey,
        jsonEncode({
          'at': DateTime.now().millisecondsSinceEpoch,
          'data': data,
        }),
      );
    } catch (_) {
      // Данные могли содержать значение, которое jsonEncode не переваривает,
      // либо диск недоступен. В худшем случае не будет офлайн-копии — это
      // не повод рушить уже успешно выполненный запрос.
    }
  }

  Future<_CachedPayload?> _readDiskCache(String cacheKey) async {
    final diskKey = _diskKeyByCache[cacheKey];
    if (diskKey == null) return null;
    try {
      final raw = await LocalPrefs.instance.getString(diskKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final at = (decoded['at'] as num?)?.toInt() ?? 0;
      if (at <= 0 || !decoded.containsKey('data')) return null;
      return _CachedPayload(
          decoded['data'], DateTime.fromMillisecondsSinceEpoch(at));
    } catch (_) {
      return null;
    }
  }

  /// Сбрасывает кэш перечисленных ресурсов — после операций, которые заведомо
  /// меняют данные на сервере (покупка, продление, докупка устройства,
  /// активация триала). Иначе экран ещё 20 секунд показывал бы старый баланс
  /// и старый срок ключа.
  void _invalidate(List<String> cacheKeys) {
    for (final cacheKey in cacheKeys) {
      _memory.remove(cacheKey);
      _servedFromDisk.remove(cacheKey);
    }
  }

  /// Полная очистка. Сохранённые ключи и баланс принадлежат конкретному
  /// аккаунту: если не стирать их при выходе, следующий вошедший на этом
  /// устройстве увидит на первом кадре чужие ключи (а `connection_string` в
  /// них — готовый доступ к VPN) и чужой баланс.
  Future<void> clearCaches() async {
    _memory.clear();
    _servedFromDisk.clear();
    _inFlight.clear();
    for (final diskKey in _diskKeyByCache.values) {
      try {
        await LocalPrefs.instance.setString(diskKey, '');
      } catch (_) {
        // Диск недоступен — продолжаем чистить остальные.
      }
    }
  }

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
    // См. докстринг clearCaches() — чужие ключи и баланс не должны
    // пережить выход из аккаунта.
    await clearCaches();
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-API-Key': apiKey,
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  /// Общая обёртка вокруг http.Client.get/post: единый таймаут на все
  /// запросы + перевод низкоуровневых сетевых исключений (нет интернета,
  /// не удалось разрешить DNS, обрыв соединения, таймаут) в понятный
  /// пользователю текст через [ApiException], вместо того чтобы экраны
  /// печатали в SnackBar сырое "SocketException: Failed host lookup...".
  Future<http.Response> _get(Uri url) => _send(() => _client.get(url, headers: _headers));

  Future<http.Response> _post(Uri url, {Object? body}) =>
      _send(() => _client.post(url, headers: _headers, body: body));

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(_requestTimeout);
    } on TimeoutException {
      throw ApiException(0, 'Сервер не отвечает — проверь интернет-соединение и попробуй ещё раз');
    } on SocketException {
      throw ApiException(0, 'Нет соединения с сервером — проверь интернет');
    } on HttpException {
      throw ApiException(0, 'Ошибка соединения с сервером');
    }
  }

  // ------------------------------------------------------------- auth

  /// POST /auth/register/send-code {email}
  Future<void> registerSendCode(String email) async {
    final res = await _post(_u('/auth/register/send-code'), body: jsonEncode({'email': email}));
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
    final res = await _post(
      _u('/auth/register'),
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
  /// Отвечает {"ok": true} независимо от того, существует ли аккаунт —
  /// иначе по коду ответа можно перебором собирать зарегистрированные email.
  /// Полагаться на код ответа как на признак "email существует" нельзя.
  Future<void> resetPasswordSendCode(String email) async {
    final res = await _post(_u('/auth/reset-password/send-code'), body: jsonEncode({'email': email}));
    _checkOk(res);
  }

  /// POST /auth/reset-password/confirm {email, code, new_password}
  Future<void> resetPasswordConfirm({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final res = await _post(
      _u('/auth/reset-password/confirm'),
      body: jsonEncode({'email': email, 'code': code, 'new_password': newPassword}),
    );
    _checkOk(res);
  }

  /// POST /auth/login {email, password}
  Future<Map<String, dynamic>> login({required String email, required String password}) async {
    final res = await _post(
      _u('/auth/login'),
      body: jsonEncode({'email': email, 'password': password}),
    );
    _checkOk(res);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    await _setToken(data['token'] as String);
    return data['user'] as Map<String, dynamic>;
  }

  // ------------------------------------------------------------- profile / balance / referral

  /// GET /user/profile — баланс, реферальная статистика и ссылка на
  /// приглашение приходят одним вызовом; отдельных /referral и /balance на
  /// сервере нет.
  Future<Map<String, dynamic>> getProfile() =>
      _cached(_cacheProfile, _fetchProfile);

  Future<Map<String, dynamic>> _fetchProfile() async {
    final res = await _get(_u('/user/profile'));
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['user'] as Map<String, dynamic>;
  }

  /// POST /user/trial — активировать бесплатный пробный период.
  Future<Map<String, dynamic>> claimTrial() async {
    final res = await _post(_u('/user/trial'));
    _checkOk(res);
    _invalidate([_cacheKeys, _cacheProfile]);
    return (jsonDecode(res.body) as Map<String, dynamic>)['key'] as Map<String, dynamic>;
  }

  // ------------------------------------------------------------- keys

  /// GET /user/keys
  Future<List<dynamic>> getKeys() => _cached(_cacheKeys, _fetchKeys);

  Future<List<dynamic>> _fetchKeys() async {
    final res = await _get(_u('/user/keys'));
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['keys'] as List<dynamic>;
  }

  /// POST /key/upgrade-devices {key_id} — докупить слот устройства (+50 RUB,
  /// максимум 4 на ключ — лимиты те же, что реально заданы на сервере).
  Future<int> upgradeKeyDevices(int keyId) async {
    final res = await _post(_u('/key/upgrade-devices'), body: jsonEncode({'key_id': keyId}));
    _checkOk(res);
    _invalidate([_cacheKeys, _cacheProfile]);
    return (jsonDecode(res.body) as Map<String, dynamic>)['new_limit'] as int;
  }

  /// POST /key/create {plan_id} — списывает баланс и выдаёt ключ сразу на
  /// всех хостах (GLOBAL bundle), это уже так устроено на сервере.
  Future<Map<String, dynamic>> createKey(int planId) async {
    final res = await _post(_u('/key/create'), body: jsonEncode({'plan_id': planId}));
    _checkOk(res);
    _invalidate([_cacheKeys, _cacheProfile]);
    return (jsonDecode(res.body) as Map<String, dynamic>)['key'] as Map<String, dynamic>;
  }

  /// POST /key/extend {key_id, plan_id}
  Future<Map<String, dynamic>> extendKey({required int keyId, required int planId}) async {
    final res = await _post(_u('/key/extend'), body: jsonEncode({'key_id': keyId, 'plan_id': planId}));
    _checkOk(res);
    _invalidate([_cacheKeys, _cacheProfile]);
    return (jsonDecode(res.body) as Map<String, dynamic>)['key'] as Map<String, dynamic>;
  }

  // ------------------------------------------------------------- servers / plans

  /// GET /hosts — список локаций. Чувствительные поля (host_username,
  /// host_pass, ssh-доступ) сервер убирает сам, фильтровать на клиенте нечего.
  /// Новая локация из таблицы xui_hosts появляется здесь без изменений кода.
  ///
  /// `forceRefresh: true` минует кэш и всегда идёт в сеть. Нужен одному
  /// вызывающему — замеру задержки до backend на главном экране
  /// (connect_screen.dart::_measureLatency): он засекает время этого запроса,
  /// а закэшированный ответ возвращается мгновенно и превращался бы в
  /// "0 мс · отличный сигнал".
  Future<List<dynamic>> getHosts({bool forceRefresh = false}) {
    if (forceRefresh) {
      _invalidate([_cacheHosts]);
      return _fetchHosts().then((data) {
        _memory[_cacheHosts] = _CachedPayload(data, DateTime.now());
        unawaited(_writeDiskCache(_cacheHosts, data));
        return data;
      });
    }
    return _cached(_cacheHosts, _fetchHosts);
  }

  Future<List<dynamic>> _fetchHosts() async {
    final res = await _get(_u('/hosts'));
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['hosts'] as List<dynamic>;
  }

  /// GET /plans — Map<host_name, List<plan>>, включая ключ "GLOBAL": единый
  /// тариф на бандл из всех локаций, который и показывается на экране покупки.
  Future<Map<String, dynamic>> getPlans() => _cached(_cachePlans, _fetchPlans);

  Future<Map<String, dynamic>> _fetchPlans() async {
    final res = await _get(_u('/plans'));
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['plans'] as Map<String, dynamic>;
  }

  // ------------------------------------------------------------- billing

  /// POST /billing/topup {amount, method: 'yookassa'|'cryptobot'} -> pay_url
  Future<String> billingTopup({required double amount, required String method}) async {
    final res = await _post(
      _u('/billing/topup'),
      body: jsonEncode({'amount': amount, 'method': method}),
    );
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['pay_url'] as String;
  }

  void _checkOk(http.Response res) {
    if (res.statusCode == 401) {
      // Сессия мертва (просрочена или подписана другим ключом сервера,
      // см. докстринг у sessionExpired) — чистим токен сразу, не дожидаясь,
      // пока пользователь сам поймёт, что "Повторить" не поможет.
      _token = null;
      unawaited(_storage.delete(key: _tokenKey));
      // Сессия мертва — сохранённые данные этого аккаунта больше показывать
      // нельзя (см. докстринг clearCaches()).
      unawaited(clearCaches());
      sessionExpired.value++;
    }
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

/// Одна запись кэша: сами данные и момент, когда они были получены с
/// сервера. Отдельный класс, а не Map — чтобы `at` нельзя было случайно
/// потерять или перепутать с данными.
class _CachedPayload {
  const _CachedPayload(this.data, this.at);
  final dynamic data;
  final DateTime at;
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
/// Сборка: flutter build apk --release --dart-define=SHOPBOT_API_KEY=<ключ>