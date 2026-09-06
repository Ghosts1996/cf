import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'local_prefs.dart';

/// Клиент к РЕАЛЬНОМУ API твоего сайта/бота (shopbot/src/shop_bot/
/// webhook_server/api.py, Blueprint '/api/v1'), а не к придуманному
/// бэкенду. Все пути и формы запросов/ответов ниже — проверено чтением
/// реального api.py из твоего бэкапа, а не предположение.
///
/// [ПОДТВЕРЖДЕНО ТОБОЙ] Flask-API (/api/v1/...) висит на том же хосте,
/// что и админ-панель — api.vpnonline.su (домен сменился с
/// api.vpnonline.shop). Базовый URL ниже больше не предположение.
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

  // [ИСПРАВЛЕНО — главная причина "приложение очень долго грузится" на
  // мобильном интернете] Раньше КАЖДЫЙ запрос уходил через статические
  // функции http.get()/http.post() — а это значит, что: 1) на каждый
  // запрос пакет http создавал НОВЫЙ IOClient (новое TLS-соединение,
  // полный handshake каждый раз, без keep-alive) — на мобильной сети с
  // высоким пингом это лишние сотни миллисекунд на КАЖДЫЙ вызов; 2) ни у
  // одного запроса не было .timeout(...), поэтому при слабом сигнале/
  // потере пакетов запрос мог зависнуть на неопределённое время — вплоть
  // до дефолтного таймаута ОС (у Android/iOS это может быть больше
  // минуты), и экран с спиннером "виснет" именно тогда, когда сеть хуже
  // всего, то есть ровно тогда, когда пользователь это и замечает.
  // Теперь один переиспользуемый http.Client живёт всё время работы
  // приложения (keep-alive соединение переиспользуется между запросами),
  // и каждый запрос обязан уложиться в _requestTimeout — иначе кидается
  // понятная ApiException, а не бесконечный спиннер.
  static final http.Client _client = http.Client();
  static const Duration _requestTimeout = Duration(seconds: 15);

  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'vpnonline_session_token_v1';

  // [НОВОЕ — исправляет "Unauthorized: Invalid token signature" после смены
  // домена api.vpnonline.shop -> api.vpnonline.su] Причина бага была не в
  // самом запросе и не в домене — оба уже указывали на api.vpnonline.su
  // (см. baseUrl выше). Проблема в том, что restoreSession() ниже ТОЛЬКО
  // проверяет, что в защищённом хранилище лежит непустая строка-токен, и
  // никогда не спрашивает сервер, действителен ли он. Токены, выданные ДО
  // переезда backend'а на новый домен/сервер, подписаны старым Flask
  // SECRET_KEY (см. get_serializer() в backend-patch/api.py) — если на новом
  // сервере ключ другой (пересоздан заново, а не скопирован из старого
  // .env), сервер отвечает 401 "Invalid token signature" на КАЖДЫЙ запрос
  // с этим токеном, а старый токен как лежал в хранилище, так и остаётся
  // там навсегда: при следующем запуске restoreSession() снова "одобряет"
  // тот же мёртвый токен, приложение снова открывает RootShell, и на
  // экранах "Баланс"/"Ключи" бесконечно висит эта же ошибка — кнопка
  // "Повторить" не может помочь, потому что повторяет тот же самый
  // невалидный токен. Это ровно то, что видно на скриншотах.
  //
  // Фикс: любой ответ сервера 401 теперь трактуется как "сессия
  // недействительна" — токен сразу стирается из хранилища, а слушатели
  // (см. main.dart) переводят приложение на экран входа вместо того, чтобы
  // бесконечно показывать сырую ошибку поверх мёртвой сессии. Значение —
  // счётчик, а не bool, чтобы срабатывать каждый раз даже при одинаковом
  // предыдущем состоянии (ValueNotifier не уведомляет при установке того же
  // значения).
  static final ValueNotifier<int> sessionExpired = ValueNotifier<int>(0);

  // ══════════════════════════════════════════════════════════════════
  // [НОВОЕ] ЕДИНЫЙ СЛОЙ ЗАГРУЗКИ: дедупликация + память + диск
  // ══════════════════════════════════════════════════════════════════
  //
  // Что было не так со структурой загрузки данных.
  //
  // Экраны в этом приложении не делят между собой ничего: каждый при своём
  // initState() сам идёт в сеть за тем, что ему нужно. А `RootShell`
  // (main.dart) намеренно монтирует ВСЕ ПЯТЬ вкладок одним кадром при
  // холодном старте. Складываем и получаем, что реально уходит в сеть за
  // одну секунду после запуска:
  //
  //   ConnectScreen  -> getKeys()
  //   KeysScreen     -> getKeys()
  //   BalanceScreen  -> getProfile() + getKeys()
  //   ServersScreen  -> getHosts()  + getKeys()
  //   MenuScreen     -> getProfile() + getKeys()
  //
  // Это СЕМЬ запросов, из которых ЧЕТЫРЕ — буквально один и тот же
  // `GET /user/keys`, отправленный четыре раза подряд за один и тот же
  // ответ. На Wi-Fi разницы не видно. На мобильной сети они конкурируют за
  // один канал, каждый со своим таймаутом в 15 секунд, и любая вкладка
  // может висеть в спиннере просто потому, что её ответ застрял в очереди
  // за тремя копиями самого себя. Это и есть "долго грузится" и "всё
  // висит" — причина не в скорости сервера, а в том, что запросов в
  // четыре раза больше, чем нужно.
  //
  // Как сделано теперь. Один слой на весь клиент, три уровня:
  //
  //  1. ДЕДУПЛИКАЦИЯ. Пока запрос за ресурс уже летит, все последующие
  //     вызовы получают ТУ ЖЕ САМУЮ Future, а не заводят вторую. Четыре
  //     одновременных `getKeys()` при старте превращаются в один сетевой
  //     запрос и четыре получателя его ответа.
  //  2. ПАМЯТЬ. Ответ живёт `_memoryTtl` (20 секунд). Переключение вкладок
  //     и повторный заход на экран в эти секунды не порождают новых
  //     запросов вообще. Дольше держать нельзя: баланс и срок ключа должны
  //     оставаться живыми данными, а не показанием двухминутной давности.
  //  3. ДИСК. Последний УСПЕШНЫЙ ответ сохраняется в SharedPreferences.
  //     Если сеть отвалилась (`ApiException.statusCode == 0` — таймаут,
  //     нет соединения, туннель поднят, но трафик через него не идёт),
  //     возвращается сохранённое значение вместо ошибки. Именно это
  //     убирает "НЕТ КЛЮЧА / оформить подписку" у человека с двумя
  //     активными ключами и прочерки на экране "Баланс".
  //
  // ВАЖНО, чем НЕ подменяется ошибка: с диска отвечаем ТОЛЬКО на сетевой
  // сбой. 401 (сессия мертва), 4xx и 5xx — настоящие ответы сервера, они
  // пробрасываются как раньше, иначе приложение показывало бы старые данные
  // поверх реальной проблемы с аккаунтом.
  //
  // Экраны при этом не переписывались: сигнатуры `getKeys()`/`getProfile()`/
  // `getHosts()`/`getPlans()` не изменились ни на символ. Кто хочет знать,
  // свежие данные или сохранённые, — читает `keysFromCache`/
  // `profileFromCache`/`hostsFromCache` (см. connect_screen.dart и
  // balance_screen.dart, они это показывают пользователю честной подписью).

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

  /// Сбрасывает кэш перечисленных ресурсов — вызывается после операций,
  /// которые ЗАВЕДОМО меняют данные на сервере (покупка, продление,
  /// докупка устройства, активация триала). Без этого экран показывал бы
  /// старый баланс и старый срок ключа ещё 20 секунд после покупки.
  void _invalidate(List<String> cacheKeys) {
    for (final cacheKey in cacheKeys) {
      _memory.remove(cacheKey);
      _servedFromDisk.remove(cacheKey);
    }
  }

  /// Полная очистка. [ВАЖНО — это про безопасность, а не про удобство]
  /// Сохранённые ключи и баланс принадлежат КОНКРЕТНОМУ аккаунту. Если не
  /// стирать их при выходе, следующий человек, который войдёт на этом же
  /// устройстве под своим email, увидит на первом кадре чужие ключи (а
  /// `connection_string` в них — это готовый доступ к VPN) и чужой баланс,
  /// пока не придёт ответ сервера с его собственными данными.
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
  /// [ИСПРАВЛЕНО в патче backend] раньше отвечал 404 если email не найден —
  /// это давало возможность перебором узнавать зарегистрированные email
  /// (enumeration). После патча ответ всегда {"ok": true}, независимо от
  /// того, существует ли аккаунт — здесь ничего дополнительно делать не
  /// нужно, просто не полагайся на код ответа как признак "email существует".
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
  /// приглашение приходят ОДНИМ вызовом (так устроен реальный API, отдельного
  /// эндпоинта /referral или /balance на сервере нет — не выдумываем лишний).
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

  /// GET /hosts — список локаций. Сервер уже сам убирает чувствительные
  /// поля (host_username/host_pass/ssh-доступ) перед ответом — это видно в
  /// самом api.py, ничего дополнительно фильтровать на клиенте не нужно.
  /// Новая локация, добавленная тобой в панель (таблица xui_hosts),
  /// появится здесь автоматически, без изменений кода — так уже работает
  /// сегодня на реальном сервере.
  Future<List<dynamic>> getHosts() => _cached(_cacheHosts, _fetchHosts);

  Future<List<dynamic>> _fetchHosts() async {
    final res = await _get(_u('/hosts'));
    _checkOk(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['hosts'] as List<dynamic>;
  }

  /// GET /plans — вернёт Map<host_name, List<plan>>, включая специальный
  /// ключ "GLOBAL" (единый тариф на бандл из всех локаций — то, что мы
  /// показываем на главном экране покупки).
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
/// Сборка: flutter build apk --release --dart-define=SHOPBOT_API_KEY=<ключ из .env сервера>