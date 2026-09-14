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

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_singbox_client/flutter_singbox_client.dart'
    show SessionOptions;
import 'package:http/http.dart' as http;

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

  String _state = 'disconnected';
  int _lastDownload = 0;
  int _lastUpload = 0;

  // Порт локального Clash-совместимого API sing-box — только для служебного
  // опроса статуса/трафика самим приложением, наружу не смотрит
  // (127.0.0.1).
  static const int _clashApiPort = 9095;

  // Конфиг, который строит _buildSingBoxConfig(), всегда поднимает ещё один
  // локальный 'mixed' (SOCKS5+HTTP) инбаунд на 127.0.0.1:2080, и
  // _prepareWindowsConfig его не трогает.
  //
  // Ответ Clash API (/version) доказывает только, что процесс sing-box.exe
  // запустился и слушает служебный порт, — но не что TUN поднялся и трафик
  // идёт. Если создание TUN тихо не удалось (нет прав у фактически
  // запущенного процесса, антивирус блокирует wintun.dll, конфликт со старым
  // зависшим адаптером), sing-box.exe и его API продолжают работать, а
  // приложение показывает "подключено" при нулевом трафике. Поэтому
  // _verifyTunnelPassesTraffic ниже делает настоящий HTTP-запрос через этот
  // локальный прокси-порт: он идёт тем же VLESS/Reality outbound'ом, что и
  // боевой трафик, но не зависит от TUN.
  //
  // Порт захардкожен намеренно — в общем конфиге он всегда 2080, см.
  // tunnel_service.dart::_proxyPort.
  static const int _localProxyPort = 2080;

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

  /// На Windows не поддерживается: ядро работает отдельным процессом
  /// sing-box.exe без командного канала libbox, через который идёт
  /// переключение outbound'а на лету. Бросаем осознанно —
  /// TunnelService.switchPreferredHost поймает и сменит сервер
  /// переподключением. Молчаливый no-op отрапортовал бы о смене сервера,
  /// которой не было.
  @override
  Future<void> selectOutbound(String groupTag, String outboundTag) async {
    throw UnsupportedError(
        'Переключение outbound на лету доступно только на Android.');
  }

  /// Не поддерживается по той же причине, что и selectOutbound: командного
  /// канала libbox у отдельного процесса sing-box.exe нет.
  @override
  Future<void> urlTest(String groupTag) async {
    throw UnsupportedError(
        'Замер задержки через ядро доступен только на Android.');
  }

  /// Пустой поток, а не заглушка с фейковыми данными: вызывающий увидит,
  /// что групп нет, и просто не будет предлагать этот способ замера.
  @override
  Stream<dynamic> get outboundGroupStream => const Stream<dynamic>.empty();

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
      Map<String, dynamic>? asset;
      for (final a in assets) {
        final name = (a['name'] as String).toLowerCase();
        if (name.contains('windows-amd64') && name.endsWith('.zip')) {
          asset = a;
          break;
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
  Map<String, dynamic> _prepareWindowsConfig(String androidStyleConfig) {
    final map = jsonDecode(androidStyleConfig) as Map<String, dynamic>;
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

  Future<Directory> _writeConfig(Map<String, dynamic> config) async {
    final dir = await Directory.systemTemp.createTemp('vpnonline_sb_');
    final file = File(_joinPath([dir.path, 'config.json']));
    await file.writeAsString(jsonEncode(config));
    return dir;
  }

  @override
  Future<void> checkConfig(String config) async {
    _setState('connecting');
    try {
      await _ensureBinary();
      final map = _prepareWindowsConfig(config);
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
    } catch (_) {
      _setState('disconnected');
      rethrow;
    }
  }

  @override
  Future<void> connect(SessionOptions options) async {
    await _ensureBinary();
    // На случай, если предыдущая сессия почему-то не была закрыта.
    await disconnect();
    _setState('connecting');
    try {
      final map = _prepareWindowsConfig(options.config);
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

      // См. _localProxyPort выше: без этой проверки "connected" означало бы
      // только "процесс жив", а не "трафик идёт".
      final trafficOk = await _verifyTunnelPassesTraffic();

      // Проверка выше идёт через локальный прокси-порт, то есть прямо в outbound
      // sing-box'а, в обход TUN. Она доказывает, что VLESS/Reality-сервер жив, но
      // не то, что поднялся адаптер `VPNonLine`, через который идёт системный
      // трафик компьютера. Поэтому спрашиваем у самой Windows через
      // Get-NetAdapter, существует ли адаптер и в состоянии ли он "Up".
      final adapterOk = await _verifyTunAdapterUp();
      if (!adapterOk) {
        await disconnect();
        throw PlatformException(
          code: 'TUN_ADAPTER_NOT_UP',
          message:
              'sing-box и VLESS-сервер работают, но сетевой адаптер '
              '"VPNonLine" в Windows не поднялся (или не в состоянии Up) — '
              'весь обычный трафик компьютера идёт в обход туннеля. Обычно '
              'причина одна из: 1) приложение реально запущено НЕ от имени '
              'администратора (проверь — при старте должен был появиться '
              'UAC-запрос, если его не было, значит exe запущен в обход '
              'этого требования, например ярлыком со старыми правами '
              'совместимости); 2) антивирус/Windows Defender блокирует '
              'драйвер wintun.dll — добавь папку с sing-box.exe в '
              'исключения; 3) завис адаптер "VPNonLine" от предыдущей '
              'сессии — перезагрузи компьютер.',
        );
      }
      if (!trafficOk) {
        await disconnect();
        throw PlatformException(
          code: 'TUNNEL_NOT_PASSING_TRAFFIC',
          message:
              'Сетевой адаптер поднялся, но VLESS-сервер не отвечает через '
              'него. Проверь интернет-соединение или попробуй сменить '
              'сервер.',
        );
      }

      _setState('connected');
      _startStatsPolling();
    } catch (_) {
      _setState('disconnected');
      rethrow;
    }
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

  /// Проверяет, что трафик реально идёт через VLESS/Reality outbound: запрос
  /// уходит через локальный SOCKS/HTTP-прокси sing-box'а
  /// (127.0.0.1:$_localProxyPort), а не напрямую, — та же логика, что и в
  /// честном замере пинга (tunnel_service.dart::connectedDelayMs()).
  /// До трёх коротких попыток: сразу после старта outbound-соединению иногда
  /// нужна секунда-другая.
  Future<bool> _verifyTunnelPassesTraffic() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final client = HttpClient();
      client.findProxy = (_) => 'PROXY 127.0.0.1:$_localProxyPort';
      client.connectionTimeout = const Duration(seconds: 4);
      try {
        final req = await client
            .getUrl(Uri.parse('http://cp.cloudflare.com/generate_204'))
            .timeout(const Duration(seconds: 4));
        final res = await req.close().timeout(const Duration(seconds: 4));
        await res.drain<void>();
        if (res.statusCode == 204 || res.statusCode == 200) {
          return true;
        }
      } catch (_) {
        // Пробуем ещё раз ниже — процесс мог ещё не успеть полностью
        // поднять outbound-соединение сразу после старта.
      } finally {
        client.close(force: true);
      }
      if (attempt < 2) {
        await Future.delayed(const Duration(milliseconds: 700));
      }
    }
    return false;
  }

  /// Спрашивает у Windows, поднялся ли TUN-адаптер `VPNonLine` и в каком он
  /// состоянии — см. комментарий в connect() выше. Get-NetAdapter есть в
  /// PowerShell из коробки. До трёх попыток с паузой: адаптеру иногда нужна
  /// секунда-другая, чтобы перейти из "Disconnected" в "Up".
  Future<bool> _verifyTunAdapterUp() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final result = await Process.run(
          'powershell',
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            "(Get-NetAdapter -Name 'VPNonLine' -ErrorAction Stop).Status",
          ],
        ).timeout(const Duration(seconds: 5));
        final status = (result.stdout as String? ?? '').trim();
        if (status.toLowerCase() == 'up') {
          return true;
        }
      } catch (_) {
        // Адаптера ещё нет / PowerShell недоступен / ошибка — пробуем ещё
        // раз ниже, а если попытки кончатся — вызывающий код честно
        // сообщит об ошибке вместо фальшивого "Подключено".
      }
      if (attempt < 2) {
        await Future.delayed(const Duration(milliseconds: 700));
      }
    }
    return false;
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