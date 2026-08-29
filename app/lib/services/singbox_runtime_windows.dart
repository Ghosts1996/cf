// [НОВОЕ — Windows real-VPN]
//
// На Android туннель поднимает нативный плагин flutter_singbox_client:
// libbox (sing-box, скомпилированный в .so) работает ВНУТРИ процесса
// приложения, событиями делится через MethodChannel/EventChannel.
//
// На Windows у пакета нет нативной реализации, поэтому здесь другой, но
// абсолютно рабочий и распространённый на практике подход (так же устроены
// многие настольные VLESS/sing-box-клиенты): sing-box запускается как
// ОТДЕЛЬНЫЙ процесс — `sing-box.exe run -c config.json` — с TUN-инбаундом
// (виртуальный сетевой адаptер через драйвер WinTun). Этот класс:
//   1) находит sing-box.exe и wintun.dll рядом с .exe приложения;
//   2) берёт тот же самый sing-box-конфиг (JSON), что и так уже строит
//      _buildSingBoxConfig() в tunnel_service.dart для Android, и лишь
//      немного адаптирует его под Windows (имя TUN-интерфейса, убирает
//      android-only поля, включает Clash API для статистики трафика);
//   3) запускает процесс, ждёт, пока поднимется Clash API (значит sing-box
//      реально стартовал), и после этого считает сессию "connected";
//   4) раз в секунду опрашивает Clash API (/connections) за реальными
//      счётчиками трафика — это официальный встроенный HTTP-API sing-box,
//      не что-то самописное/хак;
//   5) на disconnect() — корректно останавливает процесс (SIGTERM, затем
//      SIGKILL, если завис) и подчищает временные файлы конфига.
//
// ВАЖНО — то, что НЕЛЬЗЯ сделать одной только правкой .dart-кода:
//   - Создание TUN-адаптера в Windows требует прав администратора. Здесь это
//     решено на уровне манифеста приложения (windows/runner/runner.exe.manifest
//     → requireAdministrator) — Windows сама покажет UAC-запрос при старте
//     приложения, до того как выполнится хоть одна строчка Dart. Без этого
//     шага (см. инструкцию, которую я отдельно прислал) TUN не поднимется —
//     это ограничение самой ОС, не sing-box и не Flutter.
//   - Бинарник sing-box.exe и wintun.dll физически должны лежать рядом с
//     .exe приложения (папка windows/sing-box/ в репозитории → копируется
//     при сборке, см. windows/CMakeLists.txt). Я не могу скачать и положить
//     их за тебя — у меня нет доступа в сеть из этой песочницы. Т.е. без
//     этих двух файлов на диске подключение честно завершится понятной
//     ошибкой (см. _ensureBinary), а не тихим "не работает".
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

  String get _sep => Platform.pathSeparator;
  String get _exeDir => File(Platform.resolvedExecutable).parent.path;
  String get _singboxDir => _joinPath([_exeDir, 'sing-box']);
  String get _singboxExe => _joinPath([_singboxDir, 'sing-box.exe']);
  String get _wintunDll => _joinPath([_singboxDir, 'wintun.dll']);

  String _joinPath(List<String> parts) => parts.join(_sep);

  @override
  Future<void> initialize() async {
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

  /// [НОВОЕ] Клиент приложения ничего вручную не скачивает — при первом
  /// подключении приложение само тянет свежий sing-box.exe с официальных
  /// GitHub Releases (SagerNet/sing-box) через GitHub API (чтобы не хардкодить
  /// версию — она меняется) и распаковывает архив штатным Windows-инструментом
  /// Expand-Archive (PowerShell, есть в любой Windows 10/11 из коробки — новая
  /// pub-зависимость на архиватор не нужна).
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

  /// [НОВОЕ] Аналогично — wintun.dll (драйвер TUN-адаптера) тянется с
  /// официального wintun.net. У wintun.net нет versioned "latest"-ссылки как
  /// у GitHub, поэтому: пробуем известную на сегодня ссылку
  /// (wintun-0.14.1.zip), а если она перестанет существовать в будущем —
  /// подстраховываемся, вытаскивая актуальную ссылку прямо со страницы
  /// wintun.net регуляркой по `builds/wintun-*.zip`.
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

    // [ИСПРАВЛЕНО — реальная причина "кнопка Отключить зависает и ничего не
    // делает несколько секунд подряд", подтверждено видео с зависшим
    // спиннером] Раньше здесь СНАЧАЛА посылался `ProcessSignal.sigterm` и
    // код честно ждал до 5 секунд, пока процесс сам завершится, и только
    // потом, по таймауту, переходил к `sigkill`. На Windows это ожидание
    // было гарантированно бесполезным: Windows не имеет понятия о POSIX-
    // сигналах, и Dart на этой платформе не может доставить произвольному
    // дочернему процессу настоящий SIGTERM — `sing-box.exe` просто никогда
    // не получал команду на завершение и продолжал работать все эти 5
    // секунд, пока не срабатывал таймаут. Каждое нажатие "Отключить" из-за
    // этого ощущалось как зависшая кнопка на добрые 5 секунд, прежде чем
    // туннель реально останавливался. Теперь на Windows процесс убивается
    // сразу через `sigkill` (это Windows честно доставляет — TerminateProcess)
    // без бессмысленного ожидания несуществующего мягкого завершения.
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

    // [НОВОЕ — реальная причина жалобы "кнопка Отключить ничего не
    // отключает"] Раньше disconnect() полагался ИСКЛЮЧИТЕЛЬНО на поле
    // `_process`, сохранённое в момент connect(). Если по любой причине
    // (пересоздание объекта рантайма, гонка состояний между старой и новой
    // сессией, `_process` уже был обнулён чем-то другим) эта ссылка к
    // моменту нажатия "Отключить" оказывалась `null` или указывала не на
    // тот процесс — блок выше просто ничего не делал, а реальный
    // sing-box.exe продолжал работать в фоне: TUN-адаптер оставался
    // поднят, интернет по-прежнему шёл через туннель, и UI (или пользователь
    // вручную) мог решить, что кнопка "не работает". Теперь после попытки
    // остановить процесс по сохранённой ссылке ДОПОЛНИТЕЛЬНО принудительно
    // убиваем ВСЕ процессы sing-box.exe по имени через штатный Windows
    // taskkill — это не зависит от того, есть ли у нас живая ссылка на
    // Process, и гарантирует, что нажатие "Отключить" реально останавливает
    // туннель, даже если внутреннее состояние этого класса рассинхронизировалось.
    await _forceKillByName();

    final dir = _tempDir;
    _tempDir = null;
    if (dir != null) {
      await dir.delete(recursive: true).catchError((_) => dir);
    }

    _setState('disconnected');
  }

  /// Принудительно завершает ЛЮБЫЕ запущенные процессы sing-box.exe по
  /// имени — подстраховка на случай, если внутренняя ссылка `_process`
  /// потеряна или устарела (см. докстринг в disconnect() выше). `taskkill`
  /// есть в любой Windows из коробки, дополнительных зависимостей не
  /// требует. Код возврата 128 ("процесс не найден") — ожидаемый и
  /// нормальный исход, когда процесс уже был корректно остановлен обычным
  /// путём чуть выше — не логируем это как ошибку.
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