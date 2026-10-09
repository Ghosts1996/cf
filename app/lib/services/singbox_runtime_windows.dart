// Windows-реализация туннеля.
//
// На Android туннель поднимает нативный плагин flutter_singbox_client:
// libbox (sing-box, собранный в .so) работает внутри процесса приложения и
// делится событиями через MethodChannel/EventChannel.
//
// Под Windows нативной реализации у пакета нет, поэтому sing-box
// запускается отдельным процессом — `sing-box.exe run -c config.json` — с
// TUN-инбаундом (виртуальный адаптер через драйвер WinTun), как это сделано
// в большинстве настольных sing-box-клиентов. Этот класс:
//   1) находит sing-box.exe и wintun.dll рядом с .exe приложения;
//   2) берёт тот же JSON-конфиг, что строит _buildSingBoxConfig() в
//      tunnel_service.dart, и адаптирует его под Windows (имя TUN-интерфейса,
//      убирает android-only поля, включает Clash API);
//   3) запускает процесс, ждёт подъёма Clash API и только тогда считает
//      сессию поднятой;
//   4) раз в секунду опрашивает Clash API (/connections) за счётчиками
//      трафика — это встроенный HTTP-API sing-box;
//   5) на disconnect() останавливает процесс и подчищает временные конфиги.
//
// Две вещи обеспечиваются вне этого файла:
//   - создание TUN-адаптера требует прав администратора, поэтому в
//     windows/runner/runner.exe.manifest стоит requireAdministrator —
//     UAC-запрос показывается до первой строчки Dart-кода;
//   - sing-box.exe и wintun.dll должны лежать рядом с .exe (папка
//     windows/sing-box/ копируется при сборке, см. windows/CMakeLists.txt).
//     Без них подключение завершится понятной ошибкой из _ensureBinary.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_singbox_client/flutter_singbox_client.dart'
    show OutboundGroup, OutboundGroupItem, SessionOptions;
import 'package:http/http.dart' as http;

import 'clash_api.dart';
import 'singbox_runtime.dart';

class WindowsSingboxRuntime implements SingboxRuntimeClient {
  Process? _process;
  Timer? _statsTimer;
  Directory? _tempDir;

  final StreamController<String> _stateCtrl =
      StreamController<String>.broadcast();
  final StreamController<_WinTrafficStats> _statsCtrl =
      StreamController<_WinTrafficStats>.broadcast();
  final StreamController<String> _faultCtrl =
      StreamController<String>.broadcast();
  final StreamController<dynamic> _groupsCtrl =
      StreamController<dynamic>.broadcast();

  String _state = 'disconnected';
  int _lastDownload = 0;
  int _lastUpload = 0;

  // Порт локального Clash-совместимого API sing-box — только для служебного
  // опроса статуса/трафика самим приложением, наружу не смотрит
  // (127.0.0.1).
  static const int _clashApiPort = 9095;

  String get _sep => Platform.pathSeparator;
  String get _exeDir => File(Platform.resolvedExecutable).parent.path;
  String get _singboxDir => _joinPath([_exeDir, 'sing-box']);
  String get _singboxExe => _joinPath([_singboxDir, 'sing-box.exe']);
  String get _wintunDll => _joinPath([_singboxDir, 'wintun.dll']);

  String _joinPath(List<String> parts) => parts.join(_sep);

  @override
  Future<void> initialize() async {
    // Осиротевший sing-box.exe от прошлой сессии (приложение закрыли
    // крестиком, а не кнопкой "Отключить") продолжает висеть в фоне: держит
    // TUN-адаптер и порт Clash API. Из-за этого установщик не может заменить
    // занятые файлы, а новый запуск приложения стартует с состоянием
    // "disconnected", пока старый процесс живёт сам по себе. Поэтому на каждом
    // старте убиваем все лишние sing-box.exe.
    await _forceKillByName();
    _setState('disconnected');
  }

  @override
  Stream<dynamic> get serviceStateStream => _stateCtrl.stream;

  @override
  Stream<dynamic> get trafficStatsStream => _statsCtrl.stream;

  @override
  Stream<dynamic> get faultStream => _faultCtrl.stream;

  // На Windows ядро — отдельный процесс sing-box.exe, и его журнал пишется в
  // файл рядом с бинарником, а не приходит событиями. Отдаём пустой поток,
  // чтобы подписчик работал одинаково на обеих платформах.
  @override
  Stream<dynamic> get coreLogStream => const Stream<dynamic>.empty();

  @override
  Future<dynamic> getServiceState() async => _state;

  @override
  Future<dynamic> getTrafficStats() async => _WinTrafficStats(
        downlinkTotalBytes: _lastDownload,
        uplinkTotalBytes: _lastUpload,
        downlinkBps: 0,
        uplinkBps: 0,
      );

  // На Windows нет системного диалога "разрешить VPN", как на Android.
  // Права на поднятие TUN-адаптера здесь получены заранее — на старте всего
  // приложения через requireAdministrator в манифесте (см. докстринг файла).
  // Если бы приложение НЕ было запущено с правами администратора, Windows
  // вообще не дала бы ему стартовать — так что к этому моменту мы точно уже
  // администратор.
  @override
  Future<bool> requestVPNPermission() async => true;

  late final ClashApiClient _clash = ClashApiClient(port: _clashApiPort);

  /// Адрес проверки задержки — тот же, что у группы `latency` в конфиге
  /// текущей сессии.
  String _latencyUrl = 'http://cp.cloudflare.com/';

  /// Переключение сервера на лету — через Clash API работающего
  /// sing-box.exe. Раньше на Windows его не было вовсе: туннель вставал на
  /// первый сервер списка и, если тот был мёртв, так на нём и оставался.
  @override
  Future<void> selectOutbound(String groupTag, String outboundTag) async {
    if (_process == null) {
      throw StateError('sing-box.exe не запущен — переключать нечего.');
    }
    await _clash.select(groupTag, outboundTag);
  }

  /// Замер задержки участников группы через Clash API.
  ///
  /// Как и на Android, вызов только запускает замер и сразу возвращается, а
  /// результаты приходят в [outboundGroupStream] по мере готовности — каждый
  /// раз полным снимком группы: ответившие со своим числом, отказавшие с
  /// 65535 (так libbox помечает не ответившего), ещё не измеренные с нулём.
  /// Раньше замер шёл внутри вызова целиком и упирался в восьмисекундный
  /// предел ожидания приложения: результатов не доходило ни одного, и экран
  /// «Серверы» на Windows помечал «нет ответа» все локации подряд.
  @override
  Future<void> urlTest(String groupTag) async {
    if (_process == null) {
      throw StateError('sing-box.exe не запущен — мерить нечего.');
    }
    unawaited(_measureGroup(groupTag));
  }

  Future<void> _measureGroup(String groupTag) async {
    final List<String> members;
    try {
      members = await _clash.members(groupTag);
    } catch (_) {
      return;
    }
    if (members.isEmpty) return;
    final delays = <String, int>{};
    void emit() => _groupsCtrl.add([
          OutboundGroup(tag: groupTag, type: 'urltest', items: [
            for (final tag in members)
              OutboundGroupItem(
                  tag: tag, type: 'vless', urlTestDelayMs: delays[tag] ?? 0),
          ]),
        ]);
    await Future.wait(members.map((tag) async {
      final d = await _clash.delay(tag, url: _latencyUrl);
      delays[tag] = d ?? 65535;
      emit();
    }));
  }

  @override
  Future<void> closeAllConnections() async {
    if (_process == null) return;
    try {
      await _clash.closeAllConnections();
    } catch (_) {}
  }

  @override
  Stream<dynamic> get outboundGroupStream => _groupsCtrl.stream;

  void _setState(String s) {
    _state = s;
    _stateCtrl.add(s);
  }

  Future<void> _ensureBinary() async {
    await Directory(_singboxDir).create(recursive: true);
    if (!await File(_singboxExe).exists()) {
      await _downloadSingBox();
    }
    if (!await File(_wintunDll).exists()) {
      await _downloadWintun();
    }
  }

  /// sing-box.exe скачивается при первом подключении с официальных GitHub
  /// Releases (SagerNet/sing-box) через GitHub API — чтобы не хардкодить
  /// версию. Архив распаковывается штатным Expand-Archive из PowerShell,
  /// новой pub-зависимости на архиватор не нужно.
  Future<void> _downloadSingBox() async {
    _faultCtrl.add('Скачиваю sing-box.exe (один раз, при первом подключении)…');
    try {
      final apiRes = await http
          .get(
            Uri.parse(
                'https://api.github.com/repos/SagerNet/sing-box/releases/latest'),
            headers: {'User-Agent': 'VPNonLine-App'},
          )
          .timeout(const Duration(seconds: 20));
      if (apiRes.statusCode != 200) {
        throw PlatformException(
          code: 'SINGBOX_DOWNLOAD_FAILED',
          message:
              'GitHub API вернул ${apiRes.statusCode} при поиске свежей версии sing-box.',
        );
      }
      final data = jsonDecode(apiRes.body) as Map<String, dynamic>;
      final assets = (data['assets'] as List).cast<Map<String, dynamic>>();
      // Сначала обычная сборка (*-windows-amd64.zip): по алфавиту раньше неё
      // идёт сборка для Windows 7 (*-windows-amd64-legacy-windows-7.zip), и
      // прежний поиск «первый подходящий» брал её.
      Map<String, dynamic>? asset;
      for (final a in assets) {
        final name = (a['name'] as String).toLowerCase();
        if (name.endsWith('-windows-amd64.zip')) {
          asset = a;
          break;
        }
      }
      if (asset == null) {
        for (final a in assets) {
          final name = (a['name'] as String).toLowerCase();
          if (name.contains('windows-amd64') && name.endsWith('.zip')) {
            asset = a;
            break;
          }
        }
      }
      if (asset == null) {
        throw PlatformException(
          code: 'SINGBOX_DOWNLOAD_FAILED',
          message:
              'В последнем релизе sing-box не нашёлся файл *windows-amd64*.zip.',
        );
      }
      final zipPath = _joinPath([_singboxDir, '_sb_download.zip']);
      final extractDir = _joinPath([_singboxDir, '_sb_extract']);
      final bytes = await http
          .readBytes(Uri.parse(asset['browser_download_url'] as String))
          .timeout(const Duration(minutes: 5));
      await File(zipPath).writeAsBytes(bytes);

      await _expandArchive(zipPath, extractDir);

      final exeInside = _findFileRecursive(extractDir, 'sing-box.exe');
      if (exeInside == null) {
        throw PlatformException(
          code: 'SINGBOX_DOWNLOAD_FAILED',
          message: 'sing-box.exe не нашёлся внутри скачанного архива.',
        );
      }
      await File(exeInside).copy(_singboxExe);

      await File(zipPath).delete().catchError((_) => File(zipPath));
      await Directory(extractDir)
          .delete(recursive: true)
          .catchError((_) => Directory(extractDir));
    } catch (e) {
      if (e is PlatformException) rethrow;
      throw PlatformException(
        code: 'SINGBOX_DOWNLOAD_FAILED',
        message: 'Не удалось автоматически скачать sing-box.exe: $e',
      );
    }
  }

  /// wintun.dll (драйвер TUN-адаптера) тянется с официального wintun.net.
  /// Versioned "latest"-ссылки там нет, поэтому сначала пробуем известную
  /// (wintun-0.14.1.zip), а если её не станет — вытаскиваем актуальную прямо
  /// со страницы регуляркой по `builds/wintun-*.zip`.
  Future<void> _downloadWintun() async {
    _faultCtrl.add('Скачиваю wintun.dll (один раз, при первом подключении)…');
    try {
      String zipUrl = 'https://www.wintun.net/builds/wintun-0.14.1.zip';
      final headCheck = await http
          .get(Uri.parse(zipUrl))
          .timeout(const Duration(seconds: 15))
          .catchError((_) => http.Response('', 404));
      if (headCheck.statusCode != 200) {
        final page = await http
            .get(Uri.parse('https://www.wintun.net/'))
            .timeout(const Duration(seconds: 15));
        final match =
            RegExp(r'builds/wintun-[\d.]+\.zip').firstMatch(page.body);
        if (match == null) {
          throw PlatformException(
            code: 'WINTUN_DOWNLOAD_FAILED',
            message: 'Не удалось найти актуальную ссылку на wintun.dll на wintun.net.',
          );
        }
        zipUrl = 'https://www.wintun.net/${match.group(0)}';
      }

      final zipPath = _joinPath([_singboxDir, '_wintun_download.zip']);
      final extractDir = _joinPath([_singboxDir, '_wintun_extract']);
      final bytes = await http
          .readBytes(Uri.parse(zipUrl))
          .timeout(const Duration(minutes: 3));
      await File(zipPath).writeAsBytes(bytes);

      await _expandArchive(zipPath, extractDir);

      // Внутри архива: wintun/bin/amd64/wintun.dll (официальная структура).
      final dllInside = _findFileRecursive(extractDir, 'wintun.dll',
          preferPathContains: 'amd64');
      if (dllInside == null) {
        throw PlatformException(
          code: 'WINTUN_DOWNLOAD_FAILED',
          message: 'wintun.dll (amd64) не нашёлся внутри скачанного архива.',
        );
      }
      await File(dllInside).copy(_wintunDll);

      await File(zipPath).delete().catchError((_) => File(zipPath));
      await Directory(extractDir)
          .delete(recursive: true)
          .catchError((_) => Directory(extractDir));
    } catch (e) {
      if (e is PlatformException) rethrow;
      throw PlatformException(
        code: 'WINTUN_DOWNLOAD_FAILED',
        message: 'Не удалось автоматически скачать wintun.dll: $e',
      );
    }
  }

  /// Распаковка встроенным в Windows PowerShell (Expand-Archive) — без новых
  /// pub-зависимостей на архиватор.
  Future<void> _expandArchive(String zipPath, String destDir) async {
    await Directory(destDir).create(recursive: true);
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      'Expand-Archive -LiteralPath "$zipPath" -DestinationPath "$destDir" -Force',
    ]);
    if (result.exitCode != 0) {
      throw PlatformException(
        code: 'ARCHIVE_EXTRACT_FAILED',
        message: 'Не удалось распаковать архив: ${result.stderr}',
      );
    }
  }

  String? _findFileRecursive(String rootDir, String fileName,
      {String? preferPathContains}) {
    final root = Directory(rootDir);
    if (!root.existsSync()) return null;
    final matches = <String>[];
    for (final entity in root.listSync(recursive: true)) {
      if (entity is File &&
          entity.path.toLowerCase().endsWith(fileName.toLowerCase())) {
        matches.add(entity.path);
      }
    }
    if (matches.isEmpty) return null;
    if (preferPathContains != null) {
      for (final m in matches) {
        if (m.toLowerCase().contains(preferPathContains.toLowerCase())) {
          return m;
        }
      }
    }
    return matches.first;
  }

  /// Берёт готовый JSON-конфиг sing-box (тот же самый, что строится для
  /// Android в tunnel_service.dart::_buildSingBoxConfig) и адаптирует под
  /// Windows:
  ///  - имя TUN-интерфейса делает windows-приличным;
  ///  - убирает include_package/exclude_package — по документации sing-box
  ///    эти поля TUN-инбаунда поддерживаются ТОЛЬКО на Android/iOS, на
  ///    Windows валидный конфиг их просто не должен содержать;
  ///  - включает Clash API (127.0.0.1) — нужен, чтобы это же приложение
  ///    могло спросить у процесса sing-box "жив ли ты" и "сколько трафика".
  @visibleForTesting
  static Map<String, dynamic> prepareWindowsConfig(String androidStyleConfig) {
    final map = jsonDecode(androidStyleConfig) as Map<String, dynamic>;
    _adaptDnsForWindows(map);
    final inbounds = (map['inbounds'] as List?)?.cast<Map<String, dynamic>>();
    if (inbounds != null) {
      for (final inbound in inbounds) {
        if (inbound['type'] == 'tun') {
          inbound['interface_name'] = 'VPNonLine';
          inbound.remove('include_package');
          inbound.remove('exclude_package');
        }
      }
    }
    map['experimental'] = {
      'clash_api': {
        'external_controller': '127.0.0.1:$_clashApiPort',
      },
    };
    return map;
  }

  /// DNS на Windows — всегда через туннель и по TCP.
  ///
  /// На Android при выключенной «Защите от DNS-протечек» имена резолвятся
  /// напрямую составным резолвером: 1.1.1.1 по UDP и системный DNS
  /// одновременно (тип `multi` из форка ядра). У штатного sing-box.exe на
  /// Windows такого резолвера нет, и прямой DNS сводился к одному UDP к
  /// 1.1.1.1 — а его у многих провайдеров режут или подменяют. Проверка при
  /// подключении идёт через прокси-порт и DNS компьютера не касается, поэтому
  /// проходила, а браузер не мог узнать адрес ни одного сайта: «VPN
  /// подключён, а интернет не работает».
  ///
  /// Через туннель DNS не зависит от провайдера вовсе, а TCP — от того,
  /// пропускает ли VPN-сервер UDP: TCP через VLESS проходит всегда, и ядро
  /// держит одно соединение на много запросов.
  static void _adaptDnsForWindows(Map<String, dynamic> map) {
    final dns = map['dns'];
    if (dns is! Map) return;
    final servers = dns['servers'];
    if (servers is List) {
      servers.removeWhere((s) => s is Map && s['type'] == 'multi');
      for (final s in servers) {
        if (s is Map && s['tag'] == 'dns-remote' && s['type'] == 'udp') {
          s['type'] = 'tcp';
        }
      }
    }
    dns['final'] = 'dns-remote';
    final route = map['route'];
    if (route is Map) {
      final resolver = route['default_domain_resolver'];
      if (resolver is Map && resolver['server'] == 'dns-direct-multi') {
        resolver['server'] = 'dns-direct';
      }
    }
  }

  Future<Directory> _writeConfig(Map<String, dynamic> config) async {
    final dir = await Directory.systemTemp.createTemp('vpnonline_sb_');
    final file = File(_joinPath([dir.path, 'config.json']));
    await file.writeAsString(jsonEncode(config));
    return dir;
  }

  /// Только проверка конфига — состояние сессии не трогает. Раньше здесь
  /// ставилось «connecting» (и при отказе — «disconnected»), а приложение
  /// перед каждым подключением задаёт ядру с полдюжины таких проверок:
  /// экран мигал «Подключение…» без всякого подключения, а проваленная
  /// проверка возможностей ядра выглядела как обрыв сессии.
  @override
  Future<void> checkConfig(String config) async {
    await _ensureBinary();
    final map = prepareWindowsConfig(config);
    final dir = await _writeConfig(map);
    try {
      final result = await Process.run(
        _singboxExe,
        ['check', '-c', _joinPath([dir.path, 'config.json'])],
      );
      if (result.exitCode != 0) {
        throw PlatformException(
          code: 'INVALID_CONFIG',
          message:
              'sing-box отклонил конфиг: ${result.stderr}\n${result.stdout}',
        );
      }
    } finally {
      await dir.delete(recursive: true).catchError((_) => dir);
    }
  }

  @override
  Future<void> connect(SessionOptions options) async {
    await _ensureBinary();
    // На случай, если предыдущая сессия почему-то не была закрыта.
    await disconnect();
    _setState('connecting');
    try {
      final map = prepareWindowsConfig(options.config);
      _latencyUrl = _latencyUrlOf(map) ?? _latencyUrl;
      _tempDir = await _writeConfig(map);
      final configPath = _joinPath([_tempDir!.path, 'config.json']);

      _process = await Process.start(
        _singboxExe,
        ['run', '-c', configPath],
        workingDirectory: _singboxDir,
      );
      // Логи sing-box сейчас не сохраняем на диск — при желании тут легко
      // добавить запись в файл (app_log_service.dart уже есть в проекте).
      _process!.stdout.transform(utf8.decoder).listen((_) {});
      _process!.stderr.transform(utf8.decoder).listen((_) {});
      unawaited(_process!.exitCode.then((code) {
        _process = null;
        if (_state != 'disconnected') {
          _faultCtrl.add('sing-box неожиданно завершился (код $code)');
          _setState('disconnected');
        }
      }));

      final started = await _waitForClashApi(const Duration(seconds: 12));
      if (!started) {
        await disconnect();
        throw PlatformException(
          code: 'CONNECT_FAILED',
          message: 'sing-box не поднялся за 12 секунд. Проверь: запущено ли '
              'приложение от имени администратора, лежит ли wintun.dll рядом '
              'с sing-box.exe, не занят ли порт $_clashApiPort другим процессом.',
        );
      }

      // Связь через сервер здесь больше не проверяем: это делает само
      // приложение (как и на Android) — и умеет при этом перейти на живой
      // сервер без перезапуска ядра. Своя проверка здесь стоила до трёх
      // попыток по четыре секунды на мёртвом первом сервере, а при её провале
      // sing-box.exe гасился и поднимался заново.
      //
      // Сетевой адаптер — только для сессии с TUN. Проверка серверов с экрана
      // «Серверы» поднимает ядро без него (только локальный прокси), и
      // прежнее требование адаптера валило каждую такую проверку: все
      // локации на Windows были «нет ответа».
      if (hasTunInbound(map)) {
        final adapterOk = await _verifyTunAdapterUp();
        if (!adapterOk) {
          await disconnect();
          throw PlatformException(
            code: 'TUN_ADAPTER_NOT_UP',
            message:
                'sing-box работает, но сетевой адаптер "VPNonLine" в Windows '
                'не поднялся — весь трафик компьютера идёт в обход туннеля. '
                'Обычно причина одна из: 1) приложение запущено НЕ от имени '
                'администратора; 2) антивирус/Windows Defender блокирует '
                'драйвер wintun.dll — добавь папку с sing-box.exe в '
                'исключения; 3) завис адаптер "VPNonLine" от предыдущей '
                'сессии — перезагрузи компьютер.',
          );
        }
      }

      _setState('connected');
      _startStatsPolling();
    } catch (_) {
      _setState('disconnected');
      rethrow;
    }
  }

  static String? _latencyUrlOf(Map<String, dynamic> config) {
    final outbounds = config['outbounds'];
    if (outbounds is! List) return null;
    for (final o in outbounds) {
      if (o is Map && o['type'] == 'urltest' && o['url'] is String) {
        return o['url'] as String;
      }
    }
    return null;
  }

  /// Сессия с TUN (боевое подключение), а не проверка серверов, которой
  /// хватает локального прокси.
  @visibleForTesting
  static bool hasTunInbound(Map<String, dynamic> config) {
    final inbounds = config['inbounds'];
    if (inbounds is! List) return false;
    return inbounds.any((i) => i is Map && i['type'] == 'tun');
  }

  Future<bool> _waitForClashApi(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_process == null) return false;
      try {
        final res = await http
            .get(Uri.parse('http://127.0.0.1:$_clashApiPort/version'))
            .timeout(const Duration(milliseconds: 600));
        if (res.statusCode == 200) return true;
      } catch (_) {
        // ещё не поднялся — попробуем ещё раз
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  /// Поднялся ли в Windows TUN-адаптер `VPNonLine`. Без него sing-box.exe и
  /// его API работают, а трафик компьютера идёт мимо туннеля (нет прав
  /// администратора, антивирус держит wintun.dll, завис старый адаптер).
  /// Адаптеру иногда нужна секунда-другая после старта ядра.
  Future<bool> _verifyTunAdapterUp() async {
    // Сначала дешёвый способ — список сетевых интерфейсов из самого Dart: без
    // запуска PowerShell, который на Windows с антивирусом стартует по
    // секунде-три на каждую попытку. Адаптер получает адрес 172.19.0.1 почти
    // сразу после старта ядра.
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final list = await NetworkInterface.list(
            includeLoopback: false, type: InternetAddressType.IPv4);
        final found = list.any((i) =>
            i.name.toLowerCase().contains('vpnonline') ||
            i.addresses.any((a) => a.address == '172.19.0.1'));
        if (found) return true;
      } catch (_) {
        break; // список недоступен — спросим у PowerShell ниже
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    // Запасной путь — тот же вопрос через Get-NetAdapter, один раз.
    try {
      final result = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "(Get-NetAdapter -Name 'VPNonLine' -ErrorAction Stop).Status",
        ],
      ).timeout(const Duration(seconds: 8));
      final status = (result.stdout as String? ?? '').trim();
      return status.toLowerCase() == 'up';
    } catch (_) {
      return false;
    }
  }

  void _startStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final res = await http
            .get(Uri.parse('http://127.0.0.1:$_clashApiPort/connections'))
            .timeout(const Duration(seconds: 2));
        if (res.statusCode != 200) return;
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final down = (body['downloadTotal'] as num?)?.toInt() ?? _lastDownload;
        final up = (body['uploadTotal'] as num?)?.toInt() ?? _lastUpload;
        final downBps = down > _lastDownload ? down - _lastDownload : 0;
        final upBps = up > _lastUpload ? up - _lastUpload : 0;
        _lastDownload = down;
        _lastUpload = up;
        _statsCtrl.add(_WinTrafficStats(
          downlinkTotalBytes: down,
          uplinkTotalBytes: up,
          downlinkBps: downBps,
          uplinkBps: upBps,
        ));
      } catch (_) {
        // сеть/API временно недоступны — просто пропускаем тик
      }
    });
  }

  @override
  Future<void> disconnect() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    _lastDownload = 0;
    _lastUpload = 0;

    // На Windows сразу sigkill, без предварительного sigterm. Windows не знает
    // POSIX-сигналов, и Dart не доставляет там произвольному дочернему
    // процессу настоящий SIGTERM: sing-box.exe просто не получал команду на
    // завершение, и каждое нажатие "Отключить" висело пять секунд до таймаута.
    // sigkill Windows доставляет честно — через TerminateProcess.
    final proc = _process;
    _process = null;
    if (proc != null) {
      proc.kill(ProcessSignal.sigkill);
      try {
        await proc.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        // Не откликнулся даже на sigkill за разумное время — не блокируем
        // пользователя дальше, ниже всё равно есть подстраховка по имени
        // процесса через taskkill.
      }
    }

    // Полагаться только на поле `_process` из connect() нельзя: если ссылка к
    // моменту отключения обнулилась или указывает не на тот процесс (гонка
    // между старой и новой сессией, пересоздание объекта рантайма), блок выше
    // ничего не сделает, а sing-box.exe продолжит держать TUN. Поэтому следом
    // безусловно убиваем все процессы по имени через taskkill.
    await _forceKillByName();

    final dir = _tempDir;
    _tempDir = null;
    if (dir != null) {
      await dir.delete(recursive: true).catchError((_) => dir);
    }

    _setState('disconnected');
  }

  /// Принудительно завершает любые запущенные sing-box.exe по имени —
  /// подстраховка, когда внутренняя ссылка `_process` потеряна или устарела.
  /// taskkill есть в любой Windows. Код возврата 128 ("процесс не найден") —
  /// нормальный исход, если процесс уже остановлен обычным путём.
  Future<void> _forceKillByName() async {
    try {
      await Process.run(
        'taskkill',
        ['/F', '/IM', 'sing-box.exe', '/T'],
      ).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Нет прав, taskkill недоступен или процесс уже завершён —
      // не критично, это только подстраховка поверх обычного пути отключения.
    }
  }
}

class _WinTrafficStats {
  _WinTrafficStats({
    required this.downlinkTotalBytes,
    required this.uplinkTotalBytes,
    required this.downlinkBps,
    required this.uplinkBps,
  });

  final int downlinkTotalBytes;
  final int uplinkTotalBytes;
  final int downlinkBps;
  final int uplinkBps;
}