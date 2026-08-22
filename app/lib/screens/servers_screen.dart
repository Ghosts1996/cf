import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';
import '../state/selected_server.dart';
import '../services/local_prefs.dart';
import '../services/tunnel_service.dart';

/// Экран выбора сервера.
///
/// НАМЕРЕННО не содержит захардкоженного списка стран — список приходит из
/// backend (`GET /hosts`), который берёт его из таблицы `xui_hosts` (те же
/// 6 панелей 3x-ui, что видит бот). Добавил новую локацию в 3x-ui и в БД
/// бота -> она появится тут сама.
///
/// [ИСПРАВЛЕНО] Раньше экран звал несуществующий `getServers()` и ожидал
/// поля `id`/`country_code`/`ping_ms`, которых реальный `/hosts` не отдаёт.
/// Реальный ответ (см. api.py -> api_hosts()) — это ТОЛЬКО `host_name`,
/// `host_url`, `subscription_url` (сервер намеренно не отдаёт
/// host_username/host_pass — это чувствительные данные для входа в саму
/// панель). Значит: id сервера = сам `host_name` (он уникален), ping
/// реального замера не будет — сервер таких данных не считает и не хранит.
///
/// [ВАЖНО] Этот экран больше НЕ шаг покупки. Покупка выдаёт ключ сразу на
/// всех локациях (единый GLOBAL-бандл, см. plans_screen.dart). "Выбор"
/// здесь влияет только на то, какая локация подсвечивается как
/// приоритетная в ConnectScreen — чисто клиентская настройка.
///
/// [ИСПРАВЛЕНО] "Избранное" и "авто-балансировка" раньше были локальным
/// `Set`/`bool` полем State — сбрасывались при уходе с экрана/перезапуске
/// приложения (то же семейство багов, что и тумблеры в
/// SettingsScreen/SecurityScreen — см. services/local_prefs.dart). Теперь
/// сохраняются через LocalPrefs на устройство. Backend по-прежнему не
/// хранит избранное на сервере (это чисто клиентское предпочтение, не
/// синхронизируется между устройствами одного аккаунта) — если понадобится
/// синхронизация между устройствами, нужен отдельный эндпоинт на бэкенде,
/// это уже другая задача.
class ServersScreen extends StatefulWidget {
  const ServersScreen({super.key});
  @override
  State<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends State<ServersScreen> {
  final _api = ApiClient.instance;
  final _prefs = LocalPrefs.instance;
  final _tunnel = TunnelService.instance;
  List<dynamic>? _hosts;
  String? _error;
  bool _loading = true;
  String? _selectedId;
  final Set<String> _favorites = {};
  bool _autoBalance = false;
  // [НОВОЕ] Живой пинг с телефона до каждого сервера — host_name -> мс,
  // null пока не измерено, -1 если сервер недоступен. Раньше здесь везде
  // была статичная надпись "сервер онлайн", которая не отражала реальную
  // задержку ни разу — просто константный текст.
  final Map<String, int?> _livePing = {};

  // [НОВОЕ] Реальные адреса серверов (host_name -> host:port), взятые из
  // самой VLESS-ссылки активного ключа (см. TunnelService.listProfileEndpoints).
  // [ИСПРАВЛЕНО — причина "все сервера показывают одинаковый пинг и
  // автобалансировка не переключается"] Раньше пинг мерился до
  // `connect_host`, который бэкенд считает из домена `subscription_url`
  // (см. backend-patch/api.py -> api_hosts()) — а этот домен часто ОБЩИЙ
  // для всех локаций сразу (единая точка выдачи подписки), а не адрес
  // конкретного VLESS-сервера страны. Поэтому все локации "мерили" по сути
  // один и тот же хост и получали одинаковый пинг — выбирать лучший было
  // не из чего. Теперь, если удаётся получить connection_string активного
  // ключа, пингуем РЕАЛЬНЫЙ адрес каждой локации (тот же, на который идёт
  // трафик при подключении). Старая логика через connect_host/subscription_url
  // остаётся запасным вариантом, если ключа/сети нет.
  Map<String, ({String host, int port, String security, String? sni})> _realEndpoints = {};

  // [ИЗМЕНЕНО — устраняет жалобу "пинг в списке серверов быстро становится
  // неверным что с включённой авто-балансировкой, что без неё"] Раньше
  // этот таймер вообще не создавался, пока авто-балансировка выключена —
  // список пингов измерялся РОВНО ОДИН РАЗ при открытии экрана и больше
  // никогда не обновлялся сам, даже если пользователь просто держал экран
  // открытым. Теперь обновление пинга идёт всегда, пока этот экран
  // смонтирован (он остаётся смонтированным внутри IndexedStack в
  // main.dart при переключении вкладок — см. RootShell, — поэтому таймер
  // не прерывается уходом на другую вкладку). Сам тумблер
  // "Авто-балансировка" по-прежнему решает ТОЛЬКО одно: нужно ли на основе
  // этих (теперь всегда актуальных) данных реально переключать поднятый
  // туннель — см. `_maybeApplyAutoBalance`, она сама проверяет
  // `_autoBalance` первой же строкой и ничего не делает, если он выключен.
  Timer? _pingRefreshTimer;
  static const _pingRefreshInterval = Duration(seconds: 25);
  // Минимальное преимущество нового сервера над тем, на котором реально
  // поднят туннель, прежде чем реально рвать рабочее соединение ради
  // переключения — без порога автобалансировка дёргала бы туннель туда-
  // обратно между двумя серверами с почти одинаковым (в пределах шума
  // сети) пингом.
  static const _switchThresholdMs = 20;
  // Не переключаем чаще, чем раз в это время, даже если каждый новый замер
  // формально находит сервер чуть быстрее — та же причина, что и порог выше.
  static const _switchCooldown = Duration(seconds: 45);
  DateTime? _lastSwitchAt;
  String? _lastSwitchTarget;
  bool _switching = false;

  ({String? host, int? port, String? security, String? sni}) _pingEndpoint(
      String hostName, Map<String, dynamic> server) {
    final real = _realEndpoints[hostName];
    if (real != null && real.host.isNotEmpty) {
      return (host: real.host, port: real.port, security: real.security, sni: real.sni);
    }

    final explicitHost = server['connect_host'] as String?;
    final explicitPort = (server['connect_port'] as num?)?.toInt();
    if (explicitHost != null && explicitHost.isNotEmpty) {
      // Запасной вариант из /hosts не несёт security/sni — там их нет,
      // проверяем только TCP (см. _measureLivePing).
      return (host: explicitHost, port: explicitPort ?? 443, security: null, sni: null);
    }

    // Рабочий /hosts пока отдаёт subscription_url/host_url без отдельных
    // connect_host/connect_port. Извлекаем адрес из уже имеющегося URL.
    for (final key in const ['subscription_url', 'host_url']) {
      final raw = server[key] as String?;
      if (raw == null || raw.isEmpty) continue;
      final uri = Uri.tryParse(raw);
      if (uri == null || uri.host.isEmpty) continue;
      return (host: uri.host, port: uri.hasPort ? uri.port : 443, security: null, sni: null);
    }
    return (host: null, port: null, security: null, sni: null);
  }

  /// TCP-connect до connect_host:connect_port (см. api.py -> api_hosts()).
  /// Не ICMP-пинг (для него на Android нужны root-права/raw sockets,
  /// недоступные обычному приложению) — время TCP-рукопожатия достаточно
  /// точно отражает задержку до сервера для целей UI.
  ///
  /// [ИСПРАВЛЕНО — реальный баг со скриншота] Раньше при `host == null`
  /// функция просто делала `return` и НИКОГДА не писала значение в
  /// `_livePing[hostName]` — экран трактует `null` как "ещё измеряю" (см.
  /// build()), поэтому надпись "измеряю..." оставалась НАВСЕГДА, если у
  /// хоста нет connect_host. А это ровно то, что произойдёт для КАЖДОГО
  /// хоста, если на живом сервере ещё не задеплоен патч `backend-patch/api.py`
  /// с полями connect_host/connect_port в ответе `/hosts` — то есть баг на
  /// скриншоте, скорее всего, не в этом файле, а в том, что бэкенд ещё
  /// отдаёт старый ответ без этих полей. Но теперь UI хотя бы не врёт
  /// бесконечным "измеряю..." — покажет честное "нет данных для пинга".
  ///
  /// [ИСПРАВЛЕНО — реальный баг: "5 мс · отлично" в этом приложении на
  /// локации, которая в Hiddify (реальный клиент, который действительно
  /// поднимает VLESS-сессию) полностью недоступна] Открытый TCP-порт — это
  /// НЕ то же самое, что рабочий VLESS-сервис на нём: панель 3x-ui может
  /// быть выключена, инбаунд удалён или неверно настроен, а TCP SYN/ACK на
  /// уровне ОС/файрвола сервера всё равно ответит мгновенно — раньше
  /// именно это принималось за "сервер отличный". Теперь для профилей с
  /// `security=tls` (обычный TLS, не Reality) после успешного TCP
  /// дополнительно делаем настоящее TLS-рукопожатие с тем же SNI, что и в
  /// самой VLESS-ссылке (`SecureSocket.connect`) — если сертификат/TLS-стек
  /// на той стороне не поднят или отдаёт не то, что ожидается, рукопожатие
  /// провалится, и локация честно покажется недоступной, а не "отлично".
  ///
  /// [ВАЖНО — то, что клиент принципиально не может проверить] Для
  /// профилей с `security=reality` (а судя по всему, это как раз случай
  /// Финляндии/Англии на скриншотах) TLS-рукопожатие в принципе не может
  /// отличить рабочий Reality-сервер от нерабочего: сервер под Reality,
  /// увидев обычное TLS-приветствие без правильного Reality-ключа
  /// (которого нет ни у этого приложения, ни у любого стороннего
  /// TLS-клиента — это и есть весь смысл маскировки Reality), сам
  /// действует как прозрачный прокси на настоящий сайт-приманку (например,
  /// www.microsoft.com) с ЕГО настоящим, доверенным сертификатом —
  /// рукопожатие успешно завершится ДАЖЕ ЕСЛИ реальный VLESS-инбаунд за
  /// ним полностью сломан. Полноценно проверить Reality-сервер можно
  /// только настоящим VLESS/Reality-рукопожатием — то есть кодом уровня
  /// sing-box/xray, а не парой строк Dart-сети. Если Финляндия/Англия — это
  /// security=reality (это легко проверить по логу `[servers] пинг ...` —
  /// см. debugPrint ниже, либо просто по самой VLESS-ссылке в панели
  /// 3x-ui), то "5/10 мс" на этом экране для них — не столько баг
  /// клиента, сколько архитектурное ограничение: единственный надёжный
  /// способ узнать, что конкретный Reality-хост сломан — реально
  /// подключиться к нему (что и делает Hiddify) или проверить панель
  /// 3x-ui/инбаунд на сервере напрямую.
  Future<void> _measureLivePing(
      String hostName, String? host, int? port,
      {String? security, String? sni}) async {
    if (host == null || host.isEmpty) {
      if (mounted)
        setState(
            () => _livePing[hostName] = -2); // -2 = нет connect_host от бэкенда
      return;
    }
    // [НОВОЕ — диагностика] Пишем в logcat, какой ИМЕННО адрес пингуется
    // для каждой локации: реальный из `_realEndpoints` (VLESS-профиль) или
    // запасной, угаданный из subscription_url/host_url (см. `_pingEndpoint`
    // выше). Если у всех локаций в логе будет один и тот же host — значит
    // либо не удалось получить реальные адреса (см. `_loadActiveConnectionString`
    // — там тоже есть лог) и мы на запасном варианте, либо VLESS-профили
    // в самой подписке физически ведут на один и тот же адрес (общая точка
    // входа) — тогда TCP-пинг принципиально не может их различить.
    final real = _realEndpoints[hostName];
    debugPrint('[servers] пинг $hostName -> $host:${port ?? 443} '
        '(${real != null ? "реальный VLESS-адрес" : "запасной вариант из /hosts"}, '
        'security=${security ?? "?"})');
    final sw = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(host, port ?? 443,
          timeout: const Duration(seconds: 4));
      // TCP прошёл — для обычного TLS (не Reality, не "none"/plaintext)
      // дополнительно проверяем настоящим TLS-рукопожатием с правильным
      // SNI, см. докстринг метода выше про то, почему это осмысленно
      // именно для security=tls и принципиально бесполезно для reality.
      if (security == 'tls') {
        final tlsSw = Stopwatch()..start();
        SecureSocket? secureSocket;
        try {
          secureSocket = await SecureSocket.secure(
            socket,
            host: (sni != null && sni.isNotEmpty) ? sni : host,
          ).timeout(const Duration(seconds: 4));
          tlsSw.stop();
          if (mounted) setState(() => _livePing[hostName] = tlsSw.elapsedMilliseconds + sw.elapsedMilliseconds);
          secureSocket.destroy();
        } catch (_) {
          // TCP-порт открыт, но TLS не поднимается — сервис за ним
          // фактически не работает, честно показываем "недоступен", а не
          // "отлично". SecureSocket.secure() не гарантированно закрывает
          // исходный TCP-сокет при неудаче — закрываем сами, иначе сокет
          // повиснет открытым до системного таймаута (маленькая, но
          // реальная утечка на каждый неудачный TLS-замер).
          socket.destroy();
          if (mounted) setState(() => _livePing[hostName] = -1);
        }
      } else {
        sw.stop();
        if (mounted) setState(() => _livePing[hostName] = sw.elapsedMilliseconds);
        socket.destroy();
      }
    } catch (_) {
      if (mounted) setState(() => _livePing[hostName] = -1);
    }
    // [НОВОЕ] Авто-балансировка — реагируем на КАЖДЫЙ завершившийся замер,
    // а не только после того, как отмерятся все хосты разом (при большом
    // количестве серверов первый результат может прийти намного раньше
    // последнего — нет смысла ждать самый медленный/недоступный сервер,
    // чтобы применить уже имеющиеся данные).
    _maybeApplyAutoBalance();
  }

  /// [ИСПРАВЛЕНО — сам баг со скриншотов: "все локации 1–2 мс · отлично",
  /// хотя Hiddify честно показывает Финляндию и Англию оффлайн]
  ///
  /// Раньше эта функция слепо мерила пинг до ЛЮБОГО адреса, который вернул
  /// `_pingEndpoint` — включая запасной вариант (`connect_host`/
  /// `subscription_url` из `/hosts`), который, как прямо предупреждает
  /// докстринг `_realEndpoints` выше, часто оказывается ОДНИМ общим
  /// адресом сразу на несколько (а то и на все) локации. TCP-пинг до
  /// такого общего шлюза технически "успешен" и очень быстр (шлюз обычно
  /// всегда поднят и близко), но не говорит АБСОЛЮТНО НИЧЕГО о состоянии
  /// конкретной локации — приложение по факту мерило не мёртвый
  /// Reality-узел, а случайно оказавшийся с ним рядом общий домен, и честно
  /// (с точки зрения самого TCP-замера) отвечало "отлично".
  ///
  /// Теперь на каждом цикле:
  /// 1. Если у какой-то локации ИЗ ТЕКУЩЕГО списка ещё нет её собственного
  ///    реального VLESS-адреса (`_realEndpoints`) — параллельно, не
  ///    блокируя этот цикл замера, пробуем догрузить его снова (см.
  ///    `_loadActiveConnectionString`). Раньше это вызывалось РОВНО ОДИН
  ///    РАЗ при открытии экрана в `_load()` — если в тот момент ключ ещё не
  ///    успел прогрузиться или сеть на секунду моргнула, экран навсегда
  ///    застревал на запасном варианте до перезапуска приложения. Теперь
  ///    попытка повторяется сама, пока не получится — как только реальный
  ///    адрес найдётся, следующий же цикл (через `_pingRefreshInterval`)
  ///    сам подхватит точные данные без участия пользователя. Именно это
  ///    объясняет и вторую половину жалобы: "на мгновение показывает
  ///    реальный пинг, а потом снова 1 мс" — реальный адрес мог найтись
  ///    один раз, а затем при следующей неудачной попытке загрузки
  ///    молча стереться; см. также правку в `_loadActiveConnectionString`
  ///    ниже — она больше не затирает уже найденные адреса.
  /// 2. Если после этого у локации всё ещё нет реального адреса, и её
  ///    запасной адрес совпадает с запасным адресом ХОТЯ БЫ ЕЩЁ ОДНОЙ
  ///    локации — это и есть признак "общего шлюза, а не персонального
  ///    сервера": для таких локаций честно показываем "нет данных для
  ///    пинга" (тот же -2, что уже используется, когда connect_host вообще
  ///    отсутствует), а не выдуманное число.
  void _measureAllPings(List<dynamic> hosts) {
    if (!_realEndpointsComplete(hosts)) {
      unawaited(_loadActiveConnectionString());
    }

    final endpoints = <String,
        ({String? host, int? port, String? security, String? sni})>{};
    final fallbackHostCounts = <String, int>{};
    for (final s in hosts) {
      final host = s as Map<String, dynamic>;
      final hostName = host['host_name'] as String? ?? '';
      if (hostName.isEmpty) continue;
      final endpoint = _pingEndpoint(hostName, host);
      endpoints[hostName] = endpoint;
      final usesRealEndpoint = _realEndpoints[hostName]?.host.isNotEmpty ?? false;
      if (!usesRealEndpoint && endpoint.host != null && endpoint.host!.isNotEmpty) {
        final key = '${endpoint.host}:${endpoint.port ?? 443}';
        fallbackHostCounts[key] = (fallbackHostCounts[key] ?? 0) + 1;
      }
    }

    for (final entry in endpoints.entries) {
      final hostName = entry.key;
      final endpoint = entry.value;
      final usesRealEndpoint = _realEndpoints[hostName]?.host.isNotEmpty ?? false;
      if (!usesRealEndpoint && endpoint.host != null && endpoint.host!.isNotEmpty) {
        final key = '${endpoint.host}:${endpoint.port ?? 443}';
        final sharedBy = fallbackHostCounts[key] ?? 0;
        if (sharedBy > 1) {
          debugPrint('[servers] $hostName делит запасной адрес $key ещё '
              'с ${sharedBy - 1} локацией(ями) — это общий шлюз, а не её '
              'персональный сервер, честный пинг для него посчитать '
              'нельзя, показываю "нет данных"');
          if (mounted) setState(() => _livePing[hostName] = -2);
          continue;
        }
      }
      _measureLivePing(hostName, endpoint.host, endpoint.port,
          security: endpoint.security, sni: endpoint.sni);
    }
  }

  /// Есть ли у КАЖДОЙ локации из актуального списка её собственный реальный
  /// VLESS-адрес в `_realEndpoints`? Используется, чтобы решить, стоит ли
  /// на этом цикле замера ещё раз попробовать `_loadActiveConnectionString()`
  /// — см. докстринг `_measureAllPings` выше.
  bool _realEndpointsComplete(List<dynamic> hosts) {
    for (final s in hosts) {
      final hostName = (s as Map<String, dynamic>)['host_name'] as String? ?? '';
      if (hostName.isEmpty) continue;
      final real = _realEndpoints[hostName];
      if (real == null || real.host.isEmpty) return false;
    }
    return true;
  }

  /// [НОВОЕ] Подтягивает connection_string активного ключа и реальные
  /// адреса локаций из него (см. докстринг `_realEndpoints` выше). Не
  /// падает и не мешает остальной загрузке экрана, если пользователь не
  /// залогинен/нет активного ключа/сеть недоступна — в этом случае просто
  /// остаёмся на запасном варианте пинга через subscription_url/host_url.
  ///
  /// [ИСПРАВЛЕНО] Две реальные причины, по которым сюда раньше можно было
  /// не дойти до реальных адресов вообще (и молча свалиться на общий
  /// subscription_url — тот самый "у всех локаций одинаковый пинг"):
  ///
  /// 1. Ручной ключ игнорировался полностью — бралcя ТОЛЬКО ключ из
  ///    личного кабинета (`_api.getKeys()`), хотя ConnectScreen подключает
  ///    туннель по ручному ключу В ПРИОРИТЕТЕ, если он задан (см.
  ///    `_effectiveConnectionString` в connect_screen.dart). Если
  ///    подключение реально идёт по ручному ключу — измерение пинга шло
  ///    по СОВЕРШЕННО ДРУГОЙ подписке, а то и вовсе без неё.
  /// 2. Бэкенд (`backend-patch/api.py::api_user_keys()`) на любой ошибке
  ///    запроса к конкретной 3x-ui-панели молча пишет `connection_string:
  ///    ''` для этого ключа, проглатывая исключение. Раньше брался только
  ///    `active.first` — если у САМОГО свежего по сроку ключа
  ///    connection_string оказывался пустым (например, именно в этот
  ///    момент не ответила одна из панелей), функция полностью сдавалась,
  ///    хотя у пользователя мог быть ещё один активный ключ с рабочей
  ///    подпиской. Теперь перебираем ВСЕ активные ключи по порядку, пока
  ///    не найдём непустую и реально парсящуюся подписку.
  Future<void> _loadActiveConnectionString() async {
    // Ручной ключ имеет приоритет — именно по нему реально подключается
    // ConnectScreen, если он задан. `ensureLoaded()` идемпотентен (внутри
    // флаг `_loaded`) — безопасно звать здесь же, не полагаясь на то, что
    // ConnectScreen успеет прочитать значение из SharedPreferences раньше
    // нас (оба экрана создаются практически одновременно в IndexedStack).
    await ManualKeyStore.instance.ensureLoaded();
    final manual = ManualKeyStore.instance.value?.trim();
    if (manual != null && manual.isNotEmpty) {
      final endpoints = await _tunnel.listProfileEndpoints(manual);
      debugPrint('[servers] ручной ключ: найдено ${endpoints.length} '
          'локаций -> ${endpoints.entries.map((e) => '${e.key}=${e.value.host}:${e.value.port}').join(', ')}');
      if (mounted && endpoints.isNotEmpty) {
        // [ИСПРАВЛЕНО — часть бага "на мгновение реальный пинг, потом
        // снова 1 мс"] Раньше это был `_realEndpoints = endpoints` —
        // полная замена карты. Если эта функция позже (см. её вызов на
        // каждом цикле в `_measureAllPings`) отработает ещё раз, но с
        // меньшим/пустым результатом (временная сетевая ошибка,
        // подписка на секунду не отдалась) — уже найденные реальные
        // адреса стирались, и экран откатывался обратно на запасной
        // (общий) адрес, хотя реальный уже был известен. Теперь новые
        // данные ДОБАВЛЯЮТСЯ к уже имеющимся, а не заменяют их целиком.
        setState(() => _realEndpoints = {..._realEndpoints, ...endpoints});
        return;
      }
      // Ручной ключ задан, но подписка не распарсилась — не переходим на
      // ключи аккаунта молча (ConnectScreen в этой ситуации тоже не
      // подключится по аккаунту), просто остаёмся без реальных адресов.
      return;
    }

    try {
      final keys = await _api.getKeys();
      final active = keys.cast<Map<String, dynamic>>().where((k) {
        final expiryStr = k['expiry_date'] as String?;
        final expiry = expiryStr != null ? DateTime.tryParse(expiryStr) : null;
        return expiry != null && expiry.isAfter(DateTime.now());
      }).toList()
        ..sort((a, b) {
          final ea = DateTime.tryParse(a['expiry_date'] as String? ?? '');
          final eb = DateTime.tryParse(b['expiry_date'] as String? ?? '');
          if (ea == null && eb == null) return 0;
          if (ea == null) return 1;
          if (eb == null) return -1;
          return eb.compareTo(ea);
        });
      for (final key in active) {
        final connectionString = key['connection_string'] as String?;
        if (connectionString == null || connectionString.isEmpty) continue;
        final endpoints = await _tunnel.listProfileEndpoints(connectionString);
        if (endpoints.isEmpty) continue;
        debugPrint('[servers] ключ ${key['key_id']}: найдено '
            '${endpoints.length} локаций -> ${endpoints.entries.map((e) => '${e.key}=${e.value.host}:${e.value.port}').join(', ')}');
        // См. комментарий у аналогичной правки в ветке ручного ключа
        // выше — мержим, а не затираем целиком.
        if (mounted) {
          setState(() => _realEndpoints = {..._realEndpoints, ...endpoints});
        }
        return;
      }
      debugPrint('[servers] ни у одного активного ключа не нашлось '
          'рабочей подписки — остаёмся на запасном варианте пинга '
          '(subscription_url/host_url из /hosts)');
    } catch (e) {
      debugPrint('[servers] не удалось получить ключи для реального '
          'пинга: $e — остаёмся на запасном варианте');
      // Нет ключа/сети — не критично, экран просто останется на запасном
      // варианте измерения пинга (см. _pingEndpoint).
    }
  }

  /// [ИСПРАВЛЕНО — сама жалоба "автопереключение не работает"] Раньше эта
  /// функция при включённой авто-балансировке только меняла "предпочтение"
  /// (`_selectedId`/`SelectedServer`/LocalPrefs) — то, какой сервер
  /// возьмётся при СЛЕДУЮЩЕМ ручном нажатии "Подключить". На уже
  /// работающий туннель это никак не влияло: если пользователь был
  /// подключён к Германии, а через минуту Нидерланды оказывались быстрее,
  /// приложение молча продолжало гнать трафик через Германию — тумблер
  /// был чисто косметическим.
  ///
  /// Теперь, если туннель ПОДНЯТ прямо сейчас и он поднят на одном из
  /// известных нам хостов (см. `_livePing`, не тронет ручной ключ с чужим
  /// remark'ом, для него живого пинга в этой таблице просто не найдётся),
  /// а среди измеренных серверов нашёлся ощутимо более быстрый — реально
  /// переключаем сам туннель на него (см. `TunnelService.switchPreferredHost`).
  /// Порог `_switchThresholdMs` и пауза `_switchCooldown` — чтобы не рвать
  /// рабочее соединение из-за шума в 3-5 мс или не дёргать его каждые
  /// 30 секунд туда-обратно между двумя почти равными серверами.
  ///
  /// Если туннель сейчас не поднят — ведём себя как раньше: просто
  /// обновляем предпочтение, которое подхватится при следующем подключении.
  void _maybeApplyAutoBalance() {
    if (!_autoBalance || _hosts == null || _hosts!.isEmpty) return;
    String? bestId;
    int? bestPing;
    for (final s in _hosts!) {
      final host = s as Map<String, dynamic>;
      final id = host['host_name'] as String? ?? '';
      if (id.isEmpty) continue;
      final ping = _livePing[id];
      if (ping == null || ping < 0)
        continue; // ещё не измерен / недоступен / нет данных
      if (bestPing == null || ping < bestPing) {
        bestPing = ping;
        bestId = id;
      }
    }
    if (bestId == null) return;

    final tunnelConnected = _tunnel.isConnected;
    final connectedName = _tunnel.connectedServerName.value;

    if (!tunnelConnected) {
      // Туннель не поднят — просто держим предпочтение актуальным, как и
      // раньше. Реального переключения делать не из чего.
      if (bestId != _selectedId) {
        setState(() => _selectedId = bestId);
        SelectedServer.select(bestId, bestId);
        _prefs.setString(PrefKeys.selectedServerId, bestId);
      }
      return;
    }

    // Туннель поднят. Сравниваем реальный текущий сервер с лучшим найденным.
    if (bestId == connectedName) return; // уже и так на лучшем сервере
    if (_switching || _tunnel.isBusy) return; // уже идёт подключение/отключение
    if (connectedName == null || !_livePing.containsKey(connectedName)) {
      // Не наш известный хост (например, вставленный вручную ключ с
      // произвольным remark'ом) — не трогаем чужое соединение.
      return;
    }
    final currentPing = _livePing[connectedName];
    if (currentPing == null || currentPing < 0) return;
    if (bestPing == null || (currentPing - bestPing) < _switchThresholdMs) {
      return; // разница в пределах шума — не стоит рвать рабочее соединение
    }
    final now = DateTime.now();
    if (_lastSwitchAt != null &&
        now.difference(_lastSwitchAt!) < _switchCooldown) {
      return; // недавно уже переключались — ждём остывания
    }

    _switching = true;
    _lastSwitchAt = now;
    final target = bestId;
    _tunnel.switchPreferredHost(target).then((_) {
      if (!mounted) return;
      setState(() {
        _selectedId = target;
        _lastSwitchTarget = target;
      });
      SelectedServer.select(target, target);
      _prefs.setString(PrefKeys.selectedServerId, target);
    }).catchError((_) {
      // Не удалось переключиться (например, целевой сервер как раз лёг) —
      // это не критично, TunnelService сам к этому моменту уже попытался
      // восстановить соединение по своей обычной логике (см. connect()).
      // Следующий цикл замера (через _pingRefreshInterval) попробует снова.
    }).whenComplete(() {
      _switching = false;
    });
  }

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _load();
    // [ИЗМЕНЕНО] Раньше запускался условно, только если авто-балансировка
    // была включена (см. удалённый `_syncAutoBalanceTimer`) — теперь
    // работает всегда, пока экран открыт, см. докстринг `_pingRefreshTimer`
    // выше.
    _pingRefreshTimer = Timer.periodic(_pingRefreshInterval, (_) {
      if (_hosts == null || _hosts!.isEmpty) return;
      _measureAllPings(_hosts!);
    });
  }

  @override
  void dispose() {
    _pingRefreshTimer?.cancel();
    super.dispose();
  }

  /// [НОВОЕ] Восстанавливаем избранное/авто-баланс/ранее выбранный сервер
  /// из LocalPrefs — раньше эти три значения были обычными полями State и
  /// всегда стартовали с дефолтов (пустое избранное, авто-баланс выкл,
  /// выбранный сервер = null) при каждом открытии экрана.
  Future<void> _loadPrefs() async {
    final results = await Future.wait([
      _prefs.getStringSet(PrefKeys.favoriteServers),
      _prefs.getBool(PrefKeys.autoBalance, fallback: false),
      _prefs.getString(PrefKeys.selectedServerId),
    ]);
    if (!mounted) return;
    setState(() {
      _favorites
        ..clear()
        ..addAll(results[0] as Set<String>);
      _autoBalance = results[1] as bool;
      _selectedId = results[2] as String?;
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final hosts = await _api.getHosts();
      setState(() {
        _hosts = hosts;
        if (hosts.isNotEmpty) {
          // [ИСПРАВЛЕНО] Раньше проверка "_selectedId == null" срабатывала
          // ТОЛЬКО в первый заход — если сохранённый ранее _selectedId
          // (например через LocalPrefs) больше не встречается в свежем
          // списке хостов (сервер удалили/переименовали), экран продолжал
          // бы указывать на несуществующий host_name молча. Теперь если
          // текущий _selectedId не найден среди актуальных хостов —
          // выбираем первый доступный.
          final stillExists = _selectedId != null &&
              hosts.any((h) =>
                  (h as Map<String, dynamic>)['host_name'] == _selectedId);
          if (!stillExists) {
            final first = hosts.first as Map<String, dynamic>;
            _selectedId = first['host_name'] as String?;
            _prefs.setString(PrefKeys.selectedServerId, _selectedId ?? '');
          }
          if (SelectedServer.hostName.value == null) {
            final selectedHost = hosts.firstWhere(
              (h) => (h as Map<String, dynamic>)['host_name'] == _selectedId,
              orElse: () => hosts.first,
            ) as Map<String, dynamic>;
            SelectedServer.select(
              selectedHost['host_name'] as String? ?? '',
              selectedHost['host_name'] as String? ?? 'Без названия',
            );
          }
        }
        _loading = false;
      });
      await _loadActiveConnectionString();
      _measureAllPings(hosts);
    } catch (e) {
      // Ожидаемо, пока backend/.env не настроены под реальную БД/панели —
      // это не заглушка, а честная ошибка сети/интеграции.
      setState(() {
        _error = 'Не удалось получить список серверов: $e';
        _loading = false;
      });
    }
  }

  /// В имени хоста (remark в 3x-ui) обычно уже есть код страны первыми
  /// буквами, например "DE Frankfurt" -> "DE". Если формат другой в твоей
  /// панели — просто поправь эту функцию, на данные с сервера это не влияет.
  String _codeFromName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '??';
    final firstWord = trimmed.split(RegExp(r'\s+')).first;
    return firstWord.length >= 2
        ? firstWord.substring(0, 2).toUpperCase()
        : firstWord.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    // ServersScreen используется и во вкладке RootShell, и как
    // отдельный MaterialPageRoute с главного экрана. Во втором
    // случае без Scaffold текст вне NeonCard попадал под аварийный
    // DefaultTextStyle Flutter с жёлтым двойным подчёркиванием.
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppHeader(
              trailing: Icons.refresh_rounded,
              onTrailingTap: _load,
              screenLabel: 'Выбор сервера',
            ),
            const Text(
              'Список подтягивается напрямую из панелей 3x-ui через backend — новая локация появляется здесь автоматически.',
              style: TextStyle(fontSize: 10, color: AppColors.textDim),
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator())),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_error!,
                    style:
                        const TextStyle(color: AppColors.danger, fontSize: 12)),
              ),
            if (_hosts != null && _hosts!.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text('В панелях 3x-ui пока нет активных локаций.',
                    style: TextStyle(color: AppColors.textDim)),
              ),
            if (_hosts != null)
              ..._hosts!.map((s) {
                final host = s as Map<String, dynamic>;
                final id = host['host_name'] as String? ?? '';
                final name = id.isEmpty ? 'Без названия' : id;
                final code = _codeFromName(name);
                final isSelected = id == _selectedId;
                final isFav = _favorites.contains(id);
                final ping = _livePing[id];
                final String pingLabel;
                final Color pingColor;
                if (ping == null) {
                  pingLabel = 'измеряю...';
                  pingColor = AppColors.textDim;
                } else if (ping == -2) {
                  pingLabel = 'нет данных для пинга';
                  pingColor = AppColors.textDim;
                } else if (ping < 0) {
                  pingLabel = 'недоступен';
                  pingColor = AppColors.danger;
                } else if (ping < 80) {
                  pingLabel = '$ping мс · отлично';
                  pingColor = AppColors.success;
                } else if (ping < 180) {
                  pingLabel = '$ping мс';
                  pingColor = AppColors.warning;
                } else {
                  pingLabel = '$ping мс · медленно';
                  pingColor = AppColors.danger;
                }
                return ServerPill(
                  code: code,
                  name: name,
                  pingLabel: pingLabel,
                  pingColor: pingColor,
                  onTap: () {
                    setState(() => _selectedId = id);
                    SelectedServer.select(id, name);
                    _prefs.setString(PrefKeys.selectedServerId, id);
                  },
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            if (isFav) {
                              _favorites.remove(id);
                            } else {
                              _favorites.add(id);
                            }
                          });
                          _prefs.setStringSet(
                              PrefKeys.favoriteServers, _favorites);
                        },
                        child: Icon(
                          isFav
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          size: 18,
                          color: isFav
                              ? const Color(0xFFF5C451)
                              : const Color(0xFF372A52),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (isSelected)
                        const NeonBadge('выбран')
                      else
                        const Icon(Icons.chevron_right_rounded,
                            color: AppColors.textDim, size: 18),
                    ],
                  ),
                );
              }),
            const SectionTitle('Автовыбор'),
            NeonCard(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                          colors: [AppColors.success, Color(0xFF1D9A6C)]),
                    ),
                    alignment: Alignment.center,
                    child: const Text('⚡', style: TextStyle(fontSize: 14)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Авто-балансировка',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(
                          // [НОВОЕ] Честно показываем, что тумблер реально
                          // делает — реальный факт последнего переключения
                          // вместо статичной надписи "выбор лучшего
                          // сервера", которая никак не показывала, работает
                          // функция на самом деле или нет.
                          _autoBalance
                              ? (_lastSwitchTarget != null
                                  ? 'реально переключились на $_lastSwitchTarget'
                                  : 'следим за пингом каждые 25 с и переключаем туннель сами')
                              : 'выбор лучшего сервера',
                          style: const TextStyle(
                              fontSize: 10, color: AppColors.textDim),
                        ),
                      ],
                    ),
                  ),
                  NeonToggle(
                    value: _autoBalance,
                    onChanged: (v) {
                      setState(() => _autoBalance = v);
                      _prefs.setBool(PrefKeys.autoBalance, v);
                      // [ИЗМЕНЕНО] Таймер замера теперь работает всегда
                      // (см. `_pingRefreshTimer`) — трогать его здесь
                      // больше не нужно, тумблер только меняет, включит
                      // ли `_maybeApplyAutoBalance` реальное переключение
                      // туннеля по уже идущим замерам.
                      if (v && _hosts != null && _hosts!.isNotEmpty) {
                        _measureAllPings(_hosts!);
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
            ),
          ),
        ),
      ),
    );
  }
}