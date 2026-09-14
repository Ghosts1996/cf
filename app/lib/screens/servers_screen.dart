import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/neon.dart';
import '../services/api_client.dart';
import '../state/selected_server.dart';
import '../services/local_prefs.dart';
import '../services/tunnel_service.dart';
import '../services/locale_service.dart';

/// Экран выбора сервера.
///
/// Списка стран в коде нет: он приходит из `GET /hosts`, который отдаёт
/// содержимое таблицы `xui_hosts` (те же панели 3x-ui, что видит бот).
/// Новая локация в 3x-ui и в БД бота появляется здесь сама.
///
/// Реальный ответ `/hosts` — это `host_name`, `host_url` и
/// `subscription_url`; host_username/host_pass сервер намеренно не отдаёт.
/// Отсюда два следствия: id сервера — это сам `host_name` (он уникален), а
/// пинг сервер не считает и не хранит, его меряет клиент.
///
/// Экран не является шагом покупки: ключ выдаётся сразу на все локации
/// (GLOBAL-бандл, см. plans_screen.dart), и выбор здесь влияет только на то,
/// какая локация считается приоритетной при подключении.
///
/// Избранное и авто-балансировка хранятся в LocalPrefs на устройстве —
/// backend их не синхронизирует между устройствами одного аккаунта.
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
  // Живой пинг с телефона до каждого сервера: host_name -> мс, null пока не
  // измерено, -1 если сервер недоступен.
  final Map<String, int?> _livePing = {};

  // Реальные адреса серверов (host_name -> host:port) из самой VLESS-ссылки
  // активного ключа (TunnelService.listProfileEndpoints).
  //
  // Замер по `connect_host`, который бэкенд считает из домена
  // `subscription_url`, для этого не годится: этот домен часто общий для всех
  // локаций сразу (единая точка выдачи подписки), а не адрес VLESS-сервера
  // конкретной страны — все локации мерили бы один и тот же хост и получали
  // одинаковый пинг. Если connection_string активного ключа удалось
  // получить, пингуем реальный адрес каждой локации — тот же, на который
  // идёт трафик при подключении. Путь через connect_host/subscription_url
  // остаётся запасным.
  Map<
      String,
      ({
        String host,
        int port,
        String security,
        String? sni,
        String transport
      })> _realEndpoints = {};

  // Пинг обновляется всё время, пока экран смонтирован. Внутри IndexedStack
  // (RootShell) он остаётся смонтированным и при переходе на другую вкладку,
  // так что таймер не прерывается. Тумблер "Авто-балансировка" решает только
  // одно: переключать ли по этим данным поднятый туннель — см.
  // _maybeApplyAutoBalance, она сама проверяет `_autoBalance` первой строкой.
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
  // host_name сервера, на который прямо сейчас идёт переключение поднятого
  // туннеля (_onServerTapped) — только для индикатора на карточке.
  String? _switchingToId;

  // Результаты настоящей проверки (TunnelService.realCheckProfile):
  // host_name -> результат. В отличие от `_livePing` (обычный TCP/TLS-замер,
  // который для security=reality не доказывает, что VLESS-сервис работает),
  // это полноценное VLESS/Reality-рукопожатие тем же ядром sing-box, что и
  // боевое подключение.
  //
  // Запускается только по явному действию пользователя, а не в фоне: проверка
  // поднимает временную сессию через тот же единственный нативный клиент, что
  // и боевой туннель, поэтому обязана быть последовательной и не пересекаться
  // с реальным подключением (см. `_realCheckAll`).
  final Map<String, RealCheckResult> _realCheckResults = {};
  // true, пока идёт последовательный обход всех локаций в _realCheckAll().
  bool _realChecking = false;
  // Когда реальная проверка последний раз доводилась до конца — для паузы
  // между автоматическими прогонами: каждая локация это запуск и остановка
  // сессии sing-box, секунды работы и расход батареи.
  DateTime? _lastRealCheckAt;
  static const _realCheckCooldown = Duration(minutes: 10);
  // Насколько долго результату реальной проверки можно доверять при
  // автоматическом переключении живого туннеля (см. _autoBalanceScore).
  static const _realCheckMaxAge = Duration(minutes: 30);
  // Автопроверка при открытии экрана запускается один раз за сессию экрана:
  // дальше её перезапускает только отключение VPN или кнопка "Проверить".
  bool _autoRealCheckScheduled = false;
  // true, когда числа в _livePing получены от самого ядра через работающий
  // туннель, а не TCP-стуком.
  bool _pingFromTunnel = false;
  // host_name локации, которая проверяется прямо сейчас — для индикатора
  // на конкретной карточке.
  String? _realCheckingId;

  // Пинг сервера, на котором туннель поднят прямо сейчас.
  //
  // `_livePing` — это TCP/TLS-пинг мимо туннеля, и для security=reality он
  // помечен как "сеть (VLESS не проверен)". Заменить его настоящим замером
  // через VLESS для всех локаций сразу, оставаясь подключённым, нельзя:
  // flutter_singbox_client держит только одну активную сессию ядра (та же
  // причина, по которой "Реальная проверка" требует сначала отключиться).
  // Но для текущей локации честный замер через реальный VLESS-канал уже
  // есть — TunnelService.connectedDelayMs(), то же число, что на главном
  // экране. Его и показываем вместо TCP-оценки.
  int? _connectedTunnelPing;
  bool _measuringConnectedTunnelPing = false;

  Future<void> _measureConnectedTunnelPing() async {
    if (!_tunnel.isConnected) {
      if (mounted && _connectedTunnelPing != null) {
        setState(() => _connectedTunnelPing = null);
      }
      return;
    }
    if (_measuringConnectedTunnelPing) return;
    _measuringConnectedTunnelPing = true;
    try {
      final ms = await _tunnel.connectedDelayMs();
      if (mounted) setState(() => _connectedTunnelPing = ms);
    } finally {
      _measuringConnectedTunnelPing = false;
    }
  }

  /// Реагирует на подключение/отключение туннеля, пока этот экран открыт —
  /// без этого реальный пинг текущего сервера появился/пропал бы только на
  /// следующем тике `_pingRefreshTimer` (раз в 25 секунд), а не сразу после
  /// нажатия "Подключить"/"Отключить" на главном экране.
  void _onTunnelLatencyChanged() {
    if (!mounted) return;
    unawaited(_measureThroughTunnel());
  }

  void _onTunnelStatusChangedForPing() {
    if (!mounted) return;
    setState(() {}); // обновить, какая карточка сейчас считается "текущей"
    unawaited(_measureConnectedTunnelPing());
    // VPN только что выключили — можно перепроверить локации по-настоящему,
    // пока туннель был поднят, это было невозможно. Пауза внутри
    // `_realCheckCooldown` не даст запускать проверку на каждое промежуточное
    // событие статуса.
    if (!_tunnel.isConnected && !_tunnel.isBusy) _maybeAutoRealCheck();
  }

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

  /// TCP-connect до connect_host:connect_port. Не ICMP — для него на Android
  /// нужны root-права и raw sockets; время TCP-рукопожатия достаточно точно
  /// отражает задержку для целей интерфейса.
  ///
  /// Если адреса нет, пишем в `_livePing` отдельное значение: null экран
  /// трактует как "ещё измеряю", и надпись "измеряю..." висела бы вечно.
  ///
  /// Открытый TCP-порт — это не работающий VLESS-сервис: панель 3x-ui может
  /// быть выключена или инбаунд удалён, а SYN/ACK на уровне ОС всё равно
  /// придёт мгновенно. Поэтому для профилей с `security=tls` после успешного
  /// TCP делается ещё и настоящее TLS-рукопожатие с тем же SNI, что в
  /// VLESS-ссылке.
  ///
  /// Для `security=reality` доказать работоспособность клиент не может в
  /// принципе: увидев обычное TLS-приветствие без правильного Reality-ключа,
  /// сервер работает прозрачным прокси на сайт-приманку с его настоящим
  /// сертификатом, и рукопожатие проходит даже при полностью сломанном
  /// VLESS-инбаунде. Единственный надёжный способ — настоящее
  /// VLESS/Reality-рукопожатие, то есть "Реальная проверка" ниже.
  Future<void> _measureLivePing(
      String hostName, String? host, int? port,
      {String? security, String? sni}) async {
    if (host == null || host.isEmpty) {
      if (mounted)
        setState(
            () => _livePing[hostName] = -2); // -2 = нет connect_host от бэкенда
      return;
    }
    // Пишем в лог, какой адрес пингуется для каждой локации: реальный из
    // `_realEndpoints` или запасной из subscription_url/host_url. Один и тот же
    // host у всех локаций означает, что мы либо не получили реальные адреса,
    // либо профили подписки физически ведут на общую точку входа — тогда
    // TCP-пинг их не различит.
    final real = _realEndpoints[hostName];
    debugPrint('[servers] пинг $hostName -> $host:${port ?? 443} '
        '(${real != null ? "реальный VLESS-адрес" : "запасной вариант из /hosts"}, '
        'security=${security ?? "?"})');
    final sw = Stopwatch()..start();
    Socket? socket;
    try {
      // Окно 8 секунд и одна повторная попытка. Четырёх секунд на слабой
      // мобильной сети не хватает на TCP-рукопожатие до европейского сервера:
      // DNS-резолв, SYN, ожидание SYN/ACK — и всё это на канале, по которому
      // одновременно летят ещё пять таких же замеров (_measureAllPings запускает
      // их разом). Один пропущенный пакет — и живая локация помечается красным.
      socket = await _connectWithRetry(host, port ?? 443);
      // Останавливаем `sw` сразу после TCP-подключения, до TLS-ветки: иначе
      // секундомер продолжает тикать во время SecureSocket.secure, и время TLS
      // считается дважды — в `sw` и в `tlsSw`.
      sw.stop();
      // TCP прошёл — для обычного TLS (не Reality и не plaintext) проверяем ещё
      // и настоящим рукопожатием с правильным SNI, см. докстринг метода.
      if (security == 'tls') {
        final tlsSw = Stopwatch()..start();
        SecureSocket? secureSocket;
        try {
          secureSocket = await SecureSocket.secure(
            socket,
            host: (sni != null && sni.isNotEmpty) ? sni : host,
          ).timeout(const Duration(seconds: 4));
          tlsSw.stop();
          if (mounted) {
            setState(() => _livePing[hostName] =
                sw.elapsedMilliseconds + tlsSw.elapsedMilliseconds);
          }
          secureSocket.destroy();
        } catch (_) {
          // TCP-порт открыт, но TLS не поднимается — сервис за ним не работает.
          // SecureSocket.secure() не гарантирует закрытие исходного сокета при
          // неудаче, поэтому закрываем сами: иначе он висит до системного таймаута.
          socket.destroy();
          if (mounted) setState(() => _livePing[hostName] = -1);
        }
      } else {
        // `sw` уже остановлен выше — здесь чистое время TCP-подключения.
        if (mounted) setState(() => _livePing[hostName] = sw.elapsedMilliseconds);
        socket.destroy();
      }
    } catch (_) {
      // Неудачный замер значит разное в двух случаях, и валить их в одну надпись
      // нельзя:
      //
      //  * у локации есть собственный адрес из VLESS-подписки — мы стучались
      //    туда, куда пойдёт трафик, и "недоступен" заслужено;
      //  * реального адреса нет, и стучались мы в запасной, угаданный из
      //    subscription_url/host_url. Это адрес панели выдачи подписки, а не
      //    VLESS-сервера страны, и его недоступность о локации не говорит ничего —
      //    тот же случай, что -2 ("нет данных для пинга").
      final hasRealEndpoint = _realEndpoints[hostName]?.host.isNotEmpty ?? false;
      if (mounted) {
        setState(() => _livePing[hostName] = hasRealEndpoint ? -1 : -2);
      }
    }
    // Реагируем на каждый завершившийся замер, а не на весь их набор: при
    // большом числе серверов первый результат приходит намного раньше
    // последнего, и ждать самый медленный незачем.
    _maybeApplyAutoBalance();
  }

  /// Одна повторная попытка TCP-подключения. Возвращает открытый сокет или
  /// бросает последнюю ошибку, если обе попытки не удались.
  Future<Socket> _connectWithRetry(String host, int port) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await Socket.connect(host, port,
            timeout: const Duration(seconds: 8));
      } catch (e) {
        lastError = e;
        // Небольшая пауза перед второй попыткой: если канал моргнул, ему
        // нужно дать долю секунды, а не бить в него немедленно повторно.
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 400));
        }
      }
    }
    throw lastError ?? const SocketException('Не удалось подключиться');
  }

  /// Замер через работающий туннель — та же метрика, что показывают зрелые
  /// клиенты: ядро само прогоняет проверку по всем outbound'ам группы `proxy`
  /// (TunnelService.measureLatenciesThroughTunnel), туннель при этом не
  /// прерывается.
  ///
  /// Три способа мерить дают три очень разных числа:
  ///  * realCheckProfile меряет полный цикл — поднять сессию, дождаться
  ///    готовности, сделать запрос, погасить. Это "сколько ждать
  ///    подключения", а не задержка канала;
  ///  * TCP-стук меряет установку TCP и до Reality-узла успешен всегда;
  ///  * URLTest ядра — чистое время запроса через уже поднятый outbound.
  ///
  /// Результаты кладутся в тот же `_livePing`, поэтому подписи и
  /// авто-балансировка работают с ними без изменений.
  Future<void> _measureThroughTunnel() async {
    if (!_tunnel.isConnected) return;
    // Экран не запускает прогон сам. Единственный замерщик живёт в
    // TunnelService (`latencyByRemark`): один таймер, пропуск циклов под
    // нагрузкой, медиана трёх измерений. Два независимых теста по одной группе
    // мешали бы друг другу.
    final measured = _tunnel.latencyByRemark.value;
    if (!mounted || measured.isEmpty) return;

    // Ядро возвращает результаты под remark'ами из VLESS-ссылки
    // ("VPNonLine | 🇬🇧 Англия"), а экран работает с host_name из /hosts
    // ("🇬🇧 Англия") — панель 3x-ui дописывает в remark название сервиса. По
    // собственным ключам ответа ни один не совпал бы с именем локации.
    // Сопоставляем по вхождению — той же логикой, что TunnelService._matchProfile.
    final byHostName = <String, int>{};
    for (final host in (_hosts ?? const <dynamic>[])) {
      final hostName = (host as Map<String, dynamic>)['host_name'] as String?;
      if (hostName == null || hostName.isEmpty) continue;
      final needle = hostName.toLowerCase().trim();
      for (final entry in measured.entries) {
        final remark = entry.key.toLowerCase();
        if (remark == needle || remark.contains(needle)) {
          byHostName[hostName] = entry.value;
          break;
        }
      }
    }
    if (byHostName.isEmpty) return;

    setState(() {
      _pingFromTunnel = true;
      byHostName.forEach((hostName, delayMs) => _livePing[hostName] = delayMs);
      // Локации, до которых ядро не достучалось, в ответ не попадают — помечаем
      // их "недоступен", а не оставляем старое число.
      for (final hostName in _livePing.keys.toList()) {
        if (!byHostName.containsKey(hostName)) _livePing[hostName] = -1;
      }
    });
  }

  void _measureAllPings(List<dynamic> hosts) {
    if (!_realEndpointsComplete(hosts)) {
      unawaited(_loadActiveConnectionString());
    }

    // При поднятом туннеле TCP-сокеты пойдут внутрь туннеля и измерят не то.
    // Спрашиваем у ядра — см. _measureThroughTunnel.
    if (_tunnel.isConnected) {
      unawaited(_measureThroughTunnel());
      return;
    }
    _pingFromTunnel = false;

    final endpoints = <String,
        ({String? host, int? port, String? security, String? sni})>{};
    final hostKeyCounts = <String, int>{};
    for (final s in hosts) {
      final host = s as Map<String, dynamic>;
      final hostName = host['host_name'] as String? ?? '';
      if (hostName.isEmpty) continue;
      final endpoint = _pingEndpoint(hostName, host);
      endpoints[hostName] = endpoint;
      if (endpoint.host != null && endpoint.host!.isNotEmpty) {
        final key = '${endpoint.host}:${endpoint.port ?? 443}';
        hostKeyCounts[key] = (hostKeyCounts[key] ?? 0) + 1;
      }
    }

    for (final entry in endpoints.entries) {
      final hostName = entry.key;
      final endpoint = entry.value;
      if (endpoint.host != null && endpoint.host!.isNotEmpty) {
        final key = '${endpoint.host}:${endpoint.port ?? 443}';
        final sharedBy = hostKeyCounts[key] ?? 0;
        if (sharedBy > 1) {
          final usesRealEndpoint =
              _realEndpoints[hostName]?.host.isNotEmpty ?? false;
          debugPrint('[servers] $hostName делит адрес $key ещё с '
              '${sharedBy - 1} локацией(ями) '
              '(${usesRealEndpoint ? "это её реальный VLESS-адрес" : "запасной вариант"}) '
              '— это общий фронт, а не персональный сервер этой локации, '
              'честный пинг для него посчитать нельзя, показываю "нет данных"');
          if (mounted) setState(() => _livePing[hostName] = -2);
          continue;
        }
      }
      _measureLivePing(hostName, endpoint.host, endpoint.port,
          security: endpoint.security, sni: endpoint.sni);
    }
  }

  String _formatCheckTime(DateTime value) {
    final h = value.hour.toString().padLeft(2, '0');
    final m = value.minute.toString().padLeft(2, '0');
    return '$h:$m';
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

  /// Подтягивает connection_string активного ключа и реальные адреса локаций
  /// из него. Если пользователь не залогинен, активного ключа нет или сеть
  /// недоступна — просто остаёмся на запасном варианте пинга через
  /// subscription_url/host_url.
  ///
  /// Ручной ключ учитывается наравне с ключами кабинета и приоритетнее их:
  /// ConnectScreen подключается по нему в первую очередь, и без этого пинг
  /// мерился бы по совсем другой подписке.
  ///
  /// Активные ключи перебираются по порядку, пока не найдётся непустая и
  /// разбираемая подписка: бэкенд (api_user_keys) на ошибке запроса к
  /// конкретной панели молча пишет `connection_string: ''`, и опора только на
  /// самый свежий ключ обрывала бы поиск на первом же таком случае.
  Future<void> _loadActiveConnectionString() async {
    // Ручной ключ приоритетнее — именно по нему подключается ConnectScreen,
    // если он задан. `ensureLoaded()` идемпотентен, поэтому зовём его здесь, не
    // полагаясь на то, что ConnectScreen успеет прочитать значение раньше: оба
    // экрана создаются почти одновременно в IndexedStack.
    await ManualKeyStore.instance.ensureLoaded();
    final manual = ManualKeyStore.instance.value?.trim();
    if (manual != null && manual.isNotEmpty) {
      final endpoints = await _tunnel.listProfileEndpoints(manual);
      debugPrint('[servers] ручной ключ: найдено ${endpoints.length} '
          'локаций -> ${endpoints.entries.map((e) => '${e.key}=${e.value.host}:${e.value.port}').join(', ')}');
      if (mounted && endpoints.isNotEmpty) {
        // Мержим, а не заменяем карту целиком: функция вызывается на каждом цикле
        // замера, и один неудачный прогон (сеть моргнула, подписка не отдалась)
        // стирал бы уже найденные адреса — экран откатывался на общий запасной.
        setState(() => _realEndpoints = {..._realEndpoints, ...endpoints});
        return;
      }
      // Ручной ключ задан, но подписка не распарсилась. Не переходим молча на
      // ключи аккаунта (ConnectScreen в этой ситуации тоже не подключится по
      // аккаунту) — просто остаёмся без реальных адресов.
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

  /// connection_string, по которому реально подключается ConnectScreen: та же
  /// логика приоритета, что в `_loadActiveConnectionString`, но без записи в
  /// `_realEndpoints` — `_realCheckAll()` нужна сама строка подписки, а не
  /// разобранные из неё адреса.
  Future<String?> _resolveActiveConnectionString() async {
    await ManualKeyStore.instance.ensureLoaded();
    final manual = ManualKeyStore.instance.value?.trim();
    if (manual != null && manual.isNotEmpty) return manual;
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
        final cs = key['connection_string'] as String?;
        if (cs != null && cs.isNotEmpty) return cs;
      }
    } catch (_) {
      // Нет сети/ключей — вызывающий код честно сообщит об этом пользователю.
    }
    return null;
  }

  /// Настоящая проверка всех локаций списка: по очереди вызывает
  /// TunnelService.realCheckProfile() — реальное VLESS/Reality-рукопожатие
  /// через временную сессию sing-box. Именно это отличает "работает" от
  /// "отвечает на TCP" и честно показывает мёртвую Reality-локацию.
  ///
  /// Строго последовательно, один сервер за раз: realCheckProfile использует
  /// тот же единственный нативный клиент, что и боевое подключение.
  /// Полностью блокируется, если туннель поднят или занят — временная сессия
  /// не может работать одновременно с боевым VPN, не разрывая его. Общий флаг
  /// `_switching` не даёт авто-балансировке и ручному тапу по серверу тронуть
  /// тот же клиент во время проверки.
  Future<void> _realCheckAll({bool silent = false}) async {
    if (_realChecking || _switching || _hosts == null || _hosts!.isEmpty) {
      return;
    }
    if (_tunnel.isConnected || _tunnel.isBusy) {
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              tr('Сначала отключитесь от VPN — реальная проверка на время поднимает и гасит тестовое соединение тем же движком.')),
        ));
      }
      return;
    }

    final connectionString = await _resolveActiveConnectionString();
    if (connectionString == null || connectionString.isEmpty) {
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Нет активного ключа с подпиской — нечего проверять.')),
        ));
      }
      return;
    }

    setState(() {
      _realChecking = true;
      _switching = true; // тот же общий замок, что и у переключения туннеля
    });

    for (final s in _hosts!) {
      if (!mounted) break;
      final host = s as Map<String, dynamic>;
      final id = host['host_name'] as String? ?? '';
      if (id.isEmpty) continue;
      setState(() => _realCheckingId = id);
      final result = await _tunnel.realCheckProfile(connectionString, id);
      if (!mounted) break;
      setState(() => _realCheckResults[id] = result);
      // Сохраняем после каждой локации, а не в конце цикла: проверка идёт
      // секундами на локацию, и уход с экрана на середине не должен терять уже
      // полученные результаты.
      _saveRealCheckResults();
    }

    if (!mounted) return;
    _lastRealCheckAt = DateTime.now();
    setState(() {
      _realChecking = false;
      _switching = false;
      _realCheckingId = null;
    });
  }

  /// Оценка локации для авто-балансировки. `null` означает "этой локации в
  /// сравнении не место": данных нет либо им нельзя доверять.
  ///
  /// Порядок предпочтения:
  ///  1. Есть свежий результат реальной проверки — берём его; "не работает"
  ///     исключает локацию из сравнения, а не означает "нет данных".
  ///  2. Результата нет, но локация не Reality — берём TCP-замер.
  ///  3. Reality без реальной проверки пропускаем: низкий TCP-пинг до
  ///     Reality-узла ничего не доказывает (сервер отвечает сертификатом
  ///     сайта-приманки даже со сломанным инбаундом).
  ///
  /// Отсеивать по третьему правилу вообще всё нельзя: в этой подписке
  /// Reality — все локации, и без результатов реальной проверки сравнивать
  /// было бы нечего.
  int? _autoBalanceScore(String id) {
    final realCheck = _realCheckResults[id];
    if (realCheck != null && _isRealCheckFresh) {
      if (!realCheck.ok) return null; // подтверждённо мёртвая локация
      final latency = realCheck.latencyMs;
      if (latency != null && latency > 0) return latency;
      return null;
    }
    if (_realEndpoints[id]?.security == 'reality') return null;
    final ping = _livePing[id];
    if (ping == null || ping < 0) return null;
    return ping;
  }

  /// Результаты реальной проверки не вечны: сервер мог лечь через час после
  /// того, как проверка признала его рабочим. Переключать по ним живой
  /// туннель имеет смысл, только пока они свежие.
  bool get _isRealCheckFresh {
    final last = _lastRealCheckAt;
    if (last == null) return false;
    return DateTime.now().difference(last) < _realCheckMaxAge;
  }

  /// Имя локации на экране (`host_name` из /hosts) по тому, что
  /// TunnelService считает текущим сервером.
  ///
  /// Там лежит remark из VLESS-ссылки ("VPNonLine | 🇩🇪 Германия"), а после
  /// мгновенного переключения внутри группы — уже host_name ("🇩🇪 Германия"):
  /// панель 3x-ui дописывает в remark название сервиса. Прямое сравнение с
  /// host_name поэтому почти никогда не совпадает, и авто-балансировка
  /// считала, что текущего сервера нет в списке. Сопоставляем по вхождению —
  /// той же логикой, что TunnelService._matchProfile и latencyForHostName.
  String? _hostIdForConnectedName(String? connectedName) {
    final hosts = _hosts;
    if (hosts == null || connectedName == null || connectedName.isEmpty) {
      return null;
    }
    final needle = connectedName.trim().toLowerCase();
    String idOf(dynamic raw) =>
        (raw as Map<String, dynamic>)['host_name'] as String? ?? '';
    for (final raw in hosts) {
      final id = idOf(raw);
      if (id.isNotEmpty && id.trim().toLowerCase() == needle) return id;
    }
    for (final raw in hosts) {
      final id = idOf(raw);
      if (id.isEmpty) continue;
      final hay = id.trim().toLowerCase();
      if (needle.contains(hay) || hay.contains(needle)) return id;
    }
    return null;
  }

  void _maybeApplyAutoBalance() {
    if (!_autoBalance || _hosts == null || _hosts!.isEmpty) return;
    String? bestId;
    int? bestPing;
    for (final s in _hosts!) {
      final host = s as Map<String, dynamic>;
      final id = host['host_name'] as String? ?? '';
      if (id.isEmpty) continue;
      final score = _autoBalanceScore(id);
      if (score == null) continue;
      if (bestPing == null || score < bestPing) {
        bestPing = score;
        bestId = id;
      }
    }
    if (bestId == null) return;

    final tunnelConnected = _tunnel.isConnected;
    final connectedId = _hostIdForConnectedName(_tunnel.connectedServerName.value);

    if (!tunnelConnected) {
      // Туннель не поднят — просто держим предпочтение актуальным.
      if (bestId != _selectedId) {
        setState(() => _selectedId = bestId);
        SelectedServer.select(bestId, bestId);
        _prefs.setString(PrefKeys.selectedServerId, bestId);
      }
      return;
    }

    // Туннель поднят. Сравниваем реальный текущий сервер с лучшим найденным.
    if (bestId == connectedId) return; // уже и так на лучшем сервере
    if (_switching || _realChecking || _tunnel.isBusy) {
      return; // уже идёт подключение, отключение или реальная проверка
    }
    if (connectedId == null) {
      // Не наш известный хост (например, ручной ключ с произвольным remark'ом) —
      // чужое соединение не трогаем.
      return;
    }
    // Текущий сервер оценивается той же мерой, что и кандидаты: смешав две
    // шкалы (реальная VLESS-задержка против TCP-оценки), можно оторвать
    // рабочее соединение, сравнив килограммы с метрами.
    final currentPing = _autoBalanceScore(connectedId);
    if (currentPing == null) return;
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
      // Не удалось переключиться (например, целевой сервер как раз лёг) — не
      // критично: TunnelService уже попытался восстановить соединение своей
      // обычной логикой, а следующий цикл замера попробует снова.
    }).whenComplete(() {
      _switching = false;
    });
  }

  /// Тап по серверу. Если туннель поднят, переключаем саму сессию через
  /// TunnelService.switchPreferredHost() — тем же методом, которым
  /// пользуется авто-балансировка. Обновления одного лишь "предпочтения"
  /// мало: VLESS-сессия продолжала бы висеть на прежнем сервере до ручного
  /// переподключения.
  Future<void> _onServerTapped(String id, String name) async {
    // Предпочтение обновляем сразу в любом случае: даже если переключение
    // ниже не понадобится или не удастся, экран "Подключение" должен
    // показывать актуальный выбор.
    setState(() => _selectedId = id);
    SelectedServer.select(id, name);
    _prefs.setString(PrefKeys.selectedServerId, id);

    if (!_tunnel.isConnected) return; // не из чего переключать — обычный выбор
    if (id == _hostIdForConnectedName(_tunnel.connectedServerName.value)) {
      return; // уже подключены сюда
    }
    if (_switching || _tunnel.isBusy) return; // уже идёт подключение/отключение

    _switching = true;
    if (mounted) setState(() => _switchingToId = id);
    try {
      await _tunnel.switchPreferredHost(id);
      if (mounted) {
        setState(() => _lastSwitchTarget = id);
        _lastSwitchAt = DateTime.now();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${tr('Не удалось переключиться на')} $name: $e')),
        );
      }
    } finally {
      _switching = false;
      if (mounted) setState(() => _switchingToId = null);
    }
  }

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    unawaited(_restoreRealCheckResults());
    _load();
    _pingRefreshTimer = Timer.periodic(_pingRefreshInterval, (_) {
      if (_hosts == null || _hosts!.isEmpty) return;
      _measureAllPings(_hosts!);
      unawaited(_measureConnectedTunnelPing());
    });
    // Обновляет реальный пинг текущего сервера сразу при
    // подключении/отключении, а не раз в 25 секунд по таймеру.
    _tunnel.status.addListener(_onTunnelStatusChangedForPing);
    // Новая порция замеров от единого замерщика — перерисовать подписи.
    _tunnel.latencyByRemark.addListener(_onTunnelLatencyChanged);
    _tunnel.connectedServerName.addListener(_onTunnelStatusChangedForPing);
    unawaited(_measureConnectedTunnelPing());
  }

  @override
  void dispose() {
    _pingRefreshTimer?.cancel();
    _tunnel.status.removeListener(_onTunnelStatusChangedForPing);
    _tunnel.latencyByRemark.removeListener(_onTunnelLatencyChanged);
    _tunnel.connectedServerName.removeListener(_onTunnelStatusChangedForPing);
    super.dispose();
  }

  /// Восстанавливает избранное, авто-баланс и ранее выбранный сервер из
  /// LocalPrefs, а также результаты прошлой реальной проверки — чтобы экран
  /// открывался с осмысленными подписями, а не с "измеряю..." у всех локаций.
  Future<void> _restoreRealCheckResults() async {
    try {
      final raw = await _prefs.getString(PrefKeys.cachedRealCheckJson);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final at = (decoded['at'] as num?)?.toInt() ?? 0;
      final results = decoded['results'];
      if (results is! Map<String, dynamic>) return;
      final restored = <String, RealCheckResult>{};
      results.forEach((hostName, value) {
        if (value is! Map<String, dynamic>) return;
        restored[hostName] = RealCheckResult(
          ok: value['ok'] == true,
          latencyMs: (value['ms'] as num?)?.toInt(),
          error: value['error'] as String?,
        );
      });
      if (!mounted || restored.isEmpty) return;
      setState(() {
        _realCheckResults.addAll(restored);
        if (at > 0) {
          _lastRealCheckAt = DateTime.fromMillisecondsSinceEpoch(at);
        }
      });
    } catch (_) {
      // Битый или недоступный кэш — просто откроемся без прошлых значений.
    }
  }

  void _saveRealCheckResults() {
    try {
      final payload = <String, dynamic>{
        'at': DateTime.now().millisecondsSinceEpoch,
        'results': _realCheckResults.map((hostName, result) => MapEntry(
              hostName,
              <String, dynamic>{
                'ok': result.ok,
                if (result.latencyMs != null) 'ms': result.latencyMs,
                if (result.error != null) 'error': result.error,
              },
            )),
      };
      unawaited(
          _prefs.setString(PrefKeys.cachedRealCheckJson, jsonEncode(payload)));
    } catch (_) {
      // Не критично: в следующий раз экран просто откроется без прошлых
      // значений, а сама проверка отработает как обычно.
    }
  }

  /// Автоматический запуск реальной проверки, пока VPN выключен.
  ///
  /// Обычный TCP-замер не отличает рабочий Reality-сервер от нерабочего (см.
  /// докстринг `_measureLivePing`), достоверный ответ даёт только реально
  /// поднятая VLESS-сессия.
  ///
  /// Ограничения намеренные:
  ///  * только при выключенном VPN — проверка поднимает временную сессию тем
  ///    же единственным нативным клиентом, что и боевой туннель;
  ///  * не чаще, чем раз в `_realCheckCooldown`: каждая локация это запуск и
  ///    остановка ядра, несколько секунд и заметный расход батареи;
  ///  * молча, без всплывающих сообщений — экран просто заменяет подписи на
  ///    подтверждённые.
  void _maybeAutoRealCheck() {
    if (_realChecking || _switching) return;
    if (_tunnel.isConnected || _tunnel.isBusy) return;
    if (_hosts == null || _hosts!.isEmpty) return;
    final last = _lastRealCheckAt;
    if (last != null && DateTime.now().difference(last) < _realCheckCooldown) {
      return;
    }
    unawaited(_realCheckAll(silent: true));
  }

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
      if (!mounted) return;
      setState(() {
        _hosts = hosts;
        if (hosts.isNotEmpty) {
          // Сохранённый `_selectedId` может больше не встречаться в свежем списке
          // хостов (сервер удалили или переименовали) — тогда выбираем первый
          // доступный, а не указываем на несуществующий host_name.
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
              selectedHost['host_name'] as String? ?? tr('Без названия'),
            );
          }
        }
        _loading = false;
      });
      await _loadActiveConnectionString();
      _measureAllPings(hosts);
      // Хосты и подписка получены — можно запускать автоматическую реальную
      // проверку. Один раз за сессию экрана; дальше её перезапустит отключение
      // VPN или кнопка.
      if (!_autoRealCheckScheduled) {
        _autoRealCheckScheduled = true;
        _maybeAutoRealCheck();
      }
    } catch (e) {
      // Ожидаемо, пока backend/.env не настроены под реальную БД/панели —
      // это не заглушка, а честная ошибка сети/интеграции.
      if (!mounted) return;
      setState(() {
        _error = '${tr('Не удалось получить список серверов:')} $e';
        _loading = false;
      });
    }
  }

  /// В имени хоста (remark в 3x-ui) обычно есть код страны первыми буквами:
  /// "DE Frankfurt" -> "DE". При другом формате имён достаточно поправить эту
  /// функцию — на данные с сервера она не влияет.
  String _codeFromName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '??';
    final firstWord = trimmed.split(RegExp(r'\s+')).first;
    // Имена локаций начинаются с эмодзи-флага, а каждая его половина занимает
    // в UTF-16 две кодовые единицы: substring(0, 2) разрезал флаг пополам и
    // выводил одинокий региональный индикатор вместо "DE". Считаем по рунам,
    // а сам флаг показываем целиком — он читается лучше любых двух букв.
    final runes = firstWord.runes.toList();
    if (runes.isEmpty) return '??';
    final code = String.fromCharCodes(runes.take(2));
    return runes.first > 0xFFFF ? code : code.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    // ServersScreen используется и во вкладке RootShell, и как
    // отдельный MaterialPageRoute с главного экрана. Во втором
    // случае без Scaffold текст вне NeonCard попадал под аварийный
    // DefaultTextStyle Flutter с жёлтым двойным подчёркиванием.
    return AnimatedBuilder(
      animation: LocaleService.instance,
      builder: (context, _) => Scaffold(
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
              screenLabel: tr('Выбор сервера'),
            ),
            Text(
              tr('Список подтягивается напрямую из панелей 3x-ui через backend — новая локация появляется здесь автоматически.'),
              style: const TextStyle(fontSize: 10, color: AppColors.textDim),
            ),
            const SizedBox(height: 10),
            // Кнопка настоящей проверки (см. `_realCheckAll`). Отдельно от
            // автоматического TCP-пинга: она требует отсутствия боевого соединения и
            // идёт последовательно по всем локациям, несколько секунд на сервер,
            // поэтому не может быть фоновым таймером.
            NeonCard(
              margin: const EdgeInsets.only(bottom: 10),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr('Реальная проверка серверов'),
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(
                          _tunnel.isConnected || _tunnel.isBusy
                              ? tr('сначала отключитесь от VPN')
                              : (_realChecking
                                  ? '${tr('проверяю')} ${_realCheckingId ?? "..."}'
                                  // Показываем, когда проверка отработала в последний раз — иначе неясно,
                                  // насколько свежие подписи под локациями.
                                  : (_lastRealCheckAt != null
                                      ? '${tr('проверено в')} ${_formatCheckTime(_lastRealCheckAt!)} · ${tr('обновляется автоматически')}'
                                      : tr('реально поднимает VLESS к каждому серверу — точнее пинга'))),
                          style: const TextStyle(
                              fontSize: 10, color: AppColors.textDim),
                        ),
                      ],
                    ),
                  ),
                  if (_realChecking)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.violetGlow),
                    )
                  else
                    GestureDetector(
                      onTap: _realCheckAll,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        child: Text(tr('Проверить'),
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.violetGlow)),
                      ),
                    ),
                ],
              ),
            ),
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
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(tr('В панелях 3x-ui пока нет активных локаций.'),
                    style: const TextStyle(color: AppColors.textDim)),
              ),
            if (_hosts != null)
              ..._hosts!.map((s) {
                final host = s as Map<String, dynamic>;
                final id = host['host_name'] as String? ?? '';
                final name = id.isEmpty ? tr('Без названия') : id;
                final code = _codeFromName(name);
                final isSelected = id == _selectedId;
                final isFav = _favorites.contains(id);
                final ping = _livePing[id];
                // Для Reality-профилей число показывается как приблизительная сетевая
                // задержка и не подсвечивается зелёным: успешный TCP/TLS до Reality-узла
                // не доказывает, что VLESS-инбаунд за ним работает (см. `_measureLivePing`),
                // а в общих порогах "< 80 мс -> отлично" мёртвая локация выглядела бы
                // наравне с рабочими.
                final isRealityOnly =
                    _realEndpoints[id]?.security == 'reality';
                // Транспорт показываем, когда он не голый TCP: по подписке
                // сразу видно, какая локация ходит через XHTTP, а какая нет,
                // и почему одна из них может быть недоступна текущему ядру.
                final transport = _realEndpoints[id]?.transport;
                final transportSuffix =
                    (transport == null || transport == 'tcp')
                        ? ''
                        : ' · $transport';
                // Для сервера, на котором туннель поднят прямо сейчас, берём настоящий
                // замер через VLESS (см. `_connectedTunnelPing`), а не TCP-оценку.
                //
                // Пороги у двух шкал разные, и это не опечатка. TCP/TLS-стук
                // меряет один обмен пакетами с сервером — там нормой считаются
                // десятки миллисекунд. URLTest ядра меряет полный HTTP-запрос
                // через VLESS: рукопожатие, прокси, ответ сайта, — и 150-400 мс
                // там обычное дело. Ровно те же числа показывает Hiddify.
                final isCurrentlyConnected =
                    _tunnel.isConnected && id == _tunnel.connectedServerName.value;
                String pingLabel;
                Color pingColor;
                if (isCurrentlyConnected) {
                  final tunnelPing = _connectedTunnelPing;
                  if (tunnelPing == null) {
                    pingLabel = tr('измеряю через VLESS...');
                    pingColor = AppColors.textDim;
                  } else if (tunnelPing < 150) {
                    pingLabel = '$tunnelPing ${tr('мс · отлично (через VLESS)')}';
                    pingColor = AppColors.success;
                  } else if (tunnelPing < 400) {
                    pingLabel = '$tunnelPing ${tr('мс · через VLESS')}';
                    pingColor = AppColors.warning;
                  } else {
                    pingLabel = '$tunnelPing ${tr('мс · медленно (через VLESS)')}';
                    pingColor = AppColors.danger;
                  }
                } else if (ping == null) {
                  pingLabel = tr('измеряю...');
                  pingColor = AppColors.textDim;
                } else if (ping == -2) {
                  pingLabel = tr('нет данных для пинга');
                  pingColor = AppColors.textDim;
                } else if (ping < 0) {
                  pingLabel = tr('недоступен');
                  pingColor = AppColors.danger;
                } else if (isRealityOnly) {
                  pingLabel = '~$ping ${tr('мс · сеть (VLESS не проверен)')}';
                  pingColor = AppColors.warning;
                } else if (ping < 80) {
                  pingLabel = '$ping ${tr('мс · отлично')}';
                  pingColor = AppColors.success;
                } else if (ping < 180) {
                  pingLabel = '$ping ${tr('мс')}';
                  pingColor = AppColors.warning;
                } else {
                  pingLabel = '$ping ${tr('мс · медленно')}';
                  pingColor = AppColors.danger;
                }
                // Результат настоящей проверки достовернее любой оценки по TCP/TLS и
                // перекрывает надпись выше: это подтверждённый факт — либо поднятая
                // VLESS-сессия, либо отказ на настоящем VLESS/Reality-рукопожатии.
                if (_realCheckingId == id) {
                  pingLabel = tr('проверяю по-настоящему...');
                  pingColor = AppColors.textDim;
                } else {
                  // Свежий замер через работающий туннель показываем вместо результата
                  // прошлой реальной проверки: та мерила время запуска сессии, а не задержку
                  // канала.
                  final livePingNow = _livePing[id];
                  final realCheck = (_pingFromTunnel &&
                          livePingNow != null &&
                          livePingNow > 0)
                      ? null
                      : _realCheckResults[id];
                  if (realCheck != null) {
                    if (realCheck.ok) {
                      pingLabel =
                          '${tr('работает ·')} ${realCheck.latencyMs} ${tr('мс (проверено)')}';
                      pingColor = AppColors.success;
                    } else {
                      pingLabel =
                          '${tr('не работает')} (${realCheck.error ?? tr("нет ответа")})';
                      pingColor = AppColors.danger;
                    }
                  }
                }
                return ServerPill(
                  code: code,
                  name: name,
                  pingLabel: '$pingLabel$transportSuffix',
                  pingColor: pingColor,
                  onTap: () => _onServerTapped(id, name),
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
                      if (_switchingToId == id)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppColors.violetGlow),
                        )
                      else if (isSelected)
                        NeonBadge(tr('выбран'))
                      else
                        const Icon(Icons.chevron_right_rounded,
                            color: AppColors.textDim, size: 18),
                    ],
                  ),
                );
              }),
            SectionTitle(tr('Автовыбор')),
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
                        Text(tr('Авто-балансировка'),
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(
                          // Показываем факт последнего переключения, а не статичную надпись про
                          // выбор лучшего сервера, по которой не видно, работает ли функция.
                          _autoBalance
                              ? (_lastSwitchTarget != null
                                  ? '${tr('реально переключились на')} $_lastSwitchTarget'
                                  : tr('следим за пингом каждые 25 с и переключаем туннель сами'))
                              : tr('выбор лучшего сервера'),
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
                      // Таймер замера работает всегда (см. `_pingRefreshTimer`); тумблер только
                      // решает, будет ли `_maybeApplyAutoBalance` переключать туннель по уже
                      // идущим замерам.
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
      ),
    );
  }
}