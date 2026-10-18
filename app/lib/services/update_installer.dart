// Загрузка и установка обновления прямо из приложения, без браузера.
//
// Как это выглядит для пользователя: на плашке «Доступна новая версия» он
// жмёт «Обновить», плашка превращается в шкалу загрузки, на 100 % Android
// показывает своё окно «Обновить приложение?» — одно нажатие, и новая версия
// встаёт поверх старой. Ключи и настройки сохраняются: пакет тот же, ключ
// подписи тот же.
//
// Окно Android убрать нельзя: обычное приложение не может ставить пакеты
// молча, это защита системы. При самом первом обновлении Android ещё раз
// спросит, можно ли этому приложению устанавливать файлы, — для этого
// открываем нужный экран настроек и ждём возврата.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_log_service.dart';
import 'tray_service.dart';
import 'tunnel_service.dart';
import 'update_service.dart';

enum UpdatePhase {
  /// Ничего не происходит — плашка предлагает «Обновить».
  idle,

  /// Идёт загрузка, см. [UpdateProgress.fraction].
  downloading,

  /// Файл загружен и проверен, можно ставить.
  ready,

  /// Android не разрешает приложению ставить пакеты — открыли настройки,
  /// ждём, пока пользователь разрешит и нажмёт «Установить» ещё раз.
  needsPermission,

  /// Что-то пошло не так, см. [UpdateProgress.error].
  failed,
}

@immutable
class UpdateProgress {
  const UpdateProgress({
    this.phase = UpdatePhase.idle,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.error,
  });

  final UpdatePhase phase;
  final int receivedBytes;

  /// Размер файла по заголовку ответа. Ноль — сервер не сказал, тогда шкала
  /// бегущая, без процентов.
  final int totalBytes;
  final String? error;

  /// Доля загруженного от 0 до 1, или null, если размер неизвестен.
  double? get fraction =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;

  int? get percent => fraction == null ? null : (fraction! * 100).floor();
}

/// То, что умеет только Android. Отдельный интерфейс — чтобы загрузку можно
/// было проверить тестами без телефона.
abstract class UpdatePlatform {
  /// Папка для загрузки внутри кэша приложения. Её же открывает наружу
  /// FileProvider (res/xml/update_paths.xml) — только её, не больше.
  Future<String> updatesDir();

  /// Разрешено ли приложению ставить пакеты («Установка неизвестных
  /// приложений» в настройках Android 8+).
  Future<bool> canInstall();

  /// Открывает экран настроек, где это разрешение включается.
  Future<void> openInstallSettings();

  /// Передаёт файл системному установщику.
  Future<void> installApk(String path);
}

class ChannelUpdatePlatform implements UpdatePlatform {
  static const _channel = MethodChannel('vpnonline/native_stats');

  @override
  Future<String> updatesDir() async =>
      (await _channel.invokeMethod<String>('getUpdatesDir'))!;

  @override
  Future<bool> canInstall() async =>
      await _channel.invokeMethod<bool>('canInstallPackages') ?? false;

  @override
  Future<void> openInstallSettings() =>
      _channel.invokeMethod<void>('openInstallPermissionSettings');

  @override
  Future<void> installApk(String path) =>
      _channel.invokeMethod<void>('installApk', {'path': path});
}

/// Windows: установщик (Inno Setup) запускается без окон, приложение
/// закрывается, установщик ставит новую версию поверх и сам открывает её.
class WindowsUpdatePlatform implements UpdatePlatform {
  @override
  Future<String> updatesDir() async =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}vpnonline-updates';

  // Разрешения, как на Android, здесь нет: приложение и так запущено с
  // правами администратора (их требует TUN-адаптер), и установщик
  // наследует их без окна UAC.
  @override
  Future<bool> canInstall() async => true;

  @override
  Future<void> openInstallSettings() async {}

  @override
  Future<void> installApk(String path) async {
    // VPN гасим до установки: установщик заменяет sing-box.exe, а занятый
    // работающим процессом файл не заменить.
    try {
      await TunnelService.instance
          .disconnect()
          .timeout(const Duration(seconds: 6));
    } catch (_) {}
    await Process.start(
      path,
      const ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-'],
      mode: ProcessStartMode.detached,
    );
    // Установщику нужно заменить и сам exe приложения — закрываемся.
    // Он подождёт и, если надо, доведёт закрытие до конца (installer.iss).
    await TrayService.instance.quit();
  }
}

class UpdateInstaller {
  UpdateInstaller({
    UpdatePlatform? platform,
    this.stallTimeout = const Duration(seconds: 30),
    this.maxAttempts = 6,
    this.retryDelay = const Duration(seconds: 2),
    this.fileExtension = 'apk',
    this.fileMagic = const [0x50, 0x4B],
  }) : _platform = platform ?? ChannelUpdatePlatform();

  static final UpdateInstaller instance = Platform.isWindows
      ? UpdateInstaller(
          platform: WindowsUpdatePlatform(),
          fileExtension: 'exe',
          // Исполняемый файл Windows начинается с «MZ».
          fileMagic: const [0x4D, 0x5A],
        )
      : UpdateInstaller();

  /// Расширение загружаемого файла: apk на Android, exe на Windows.
  final String fileExtension;

  /// Первые байты правильного файла: «PK» у APK (zip), «MZ» у exe.
  final List<int> fileMagic;

  final UpdatePlatform _platform;

  final ValueNotifier<UpdateProgress> state =
      ValueNotifier(const UpdateProgress());

  HttpClient? _client;
  String? _apkPath;
  bool _cancelled = false;

  /// Сколько ждать очередную порцию данных, прежде чем считать загрузку
  /// зависшей. Не на весь файл целиком — медленная, но живая сеть должна
  /// докачать сколько угодно долго.
  final Duration stallTimeout;

  /// Сколько раз подряд пробовать, если связь рвётся посреди файла. Каждая
  /// следующая попытка докачивает с места обрыва, а не начинает сначала:
  /// на мобильной сети соединение с хранилищем GitHub рвётся посреди
  /// стомегабайтного файла, и раньше загрузка на этом сразу заканчивалась
  /// ошибкой.
  final int maxAttempts;

  /// Пауза перед повторной попыткой; растёт с номером попытки.
  final Duration retryDelay;

  static const _networkError =
      'Связь прервалась при загрузке обновления. Нажмите «Повторить» — '
      'загрузка продолжится с того же места.';
  static const _stalledError =
      'Загрузка остановилась — проверьте интернет и нажмите «Повторить».';

  /// Загружает обновление и сразу передаёт его на установку.
  Future<void> downloadAndInstall(AppUpdate update) async {
    final phase = state.value.phase;
    if (phase == UpdatePhase.downloading) return; // уже качаем
    if ((phase == UpdatePhase.ready || phase == UpdatePhase.needsPermission) &&
        _apkPath != null &&
        File(_apkPath!).existsSync()) {
      // Файл уже загружен — второй раз не качаем.
      await install();
      return;
    }
    final path = await _download(update);
    if (path != null) await install();
  }

  /// Передаёт загруженный файл системе. Вызывается и повторно — после того,
  /// как пользователь выдал разрешение на установку.
  Future<void> install() async {
    final path = _apkPath;
    if (path == null || !File(path).existsSync()) {
      state.value = const UpdateProgress(
          phase: UpdatePhase.failed,
          error: 'Файл обновления пропал — загрузите заново.');
      return;
    }
    try {
      if (!await _platform.canInstall()) {
        state.value = const UpdateProgress(phase: UpdatePhase.needsPermission);
        await _platform.openInstallSettings();
        return;
      }
      await _platform.installApk(path);
      // Окно Android открыто. Если пользователь его закроет, плашка должна
      // по-прежнему предлагать «Установить», а не молча исчезнуть.
      state.value = const UpdateProgress(phase: UpdatePhase.ready);
    } catch (e) {
      _log('не удалось запустить установку: $e');
      state.value = const UpdateProgress(
          phase: UpdatePhase.failed,
          error: 'Не удалось открыть установку обновления. Попробуйте ещё раз '
              'или скачайте обновление через браузер.');
    }
  }

  /// Убирает APK, оставшийся от прошлого обновления. После установки
  /// новой версии Android запускает её с чистого листа, а файл в кэше так
  /// и лежал бы — под сотню мегабайт. Вызывается при запуске; пока идёт
  /// загрузка или файл ждёт установки, ничего не трогает.
  Future<void> cleanup() async {
    if (state.value.phase != UpdatePhase.idle) return;
    try {
      final dir = Directory(await _platform.updatesDir());
      if (!dir.existsSync()) return;
      for (final f in dir.listSync()) {
        try {
          f.deleteSync(recursive: true);
        } catch (_) {}
      }
    } catch (_) {
      // Нет канала (не Android) или нет доступа — не страшно.
    }
  }

  /// Возврат в приложение из настроек Android. Если разрешение на установку
  /// выдали — ставим сразу, без второго нажатия «Установить». Если нет —
  /// ничего не делаем: иначе настройки открывались бы снова при каждом
  /// возврате в приложение.
  Future<void> continueIfPermitted() async {
    if (state.value.phase != UpdatePhase.needsPermission) return;
    try {
      if (!await _platform.canInstall()) return;
    } catch (_) {
      return;
    }
    await install();
  }

  /// Прервать загрузку.
  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  Future<String?> _download(AppUpdate update) async {
    _cancelled = false;
    _apkPath = null;
    state.value = const UpdateProgress(phase: UpdatePhase.downloading);

    final Directory dir;
    try {
      dir = Directory(await _platform.updatesDir());
      if (!dir.existsSync()) dir.createSync(recursive: true);
    } catch (e) {
      _log('нет места для загрузки: $e');
      state.value = const UpdateProgress(
          phase: UpdatePhase.failed,
          error: 'Не хватает места для загрузки обновления.');
      return null;
    }
    final part =
        File('${dir.path}/vpnonline-${update.build}.$fileExtension.part');
    final target = File('${dir.path}/vpnonline-${update.build}.$fileExtension');
    // Старые файлы — от прошлых обновлений — убираем: APK весит под сотню
    // мегабайт, копить их незачем. Недокачанный файл этой же версии
    // оставляем: загрузка продолжится с места обрыва.
    try {
      for (final f in dir.listSync()) {
        if (f.path == part.path) continue;
        try {
          f.deleteSync(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}

    var received = part.existsSync() ? part.lengthSync() : 0;
    var total = 0;
    void dropPart() {
      try {
        if (part.existsSync()) part.deleteSync();
      } catch (_) {}
      received = 0;
    }

    for (var attempt = 1;; attempt++) {
      String? failure;
      try {
        final result = await _fetch(update.downloadUrl, part, received,
            knownTotal: total);
        received = result.received;
        if (result.total > 0) total = result.total;
        if (_cancelled) throw const _Cancelled();
        if (total > 0 && received > total) {
          // Кусок лёг не туда — такой файл не собрать, начинаем заново.
          dropPart();
          throw const _Restart();
        }
        if (total > 0 && received < total) {
          throw HttpException('связь оборвалась на $received из $total байт');
        }
        break;
      } on _Cancelled {
        dropPart();
        state.value = const UpdateProgress(phase: UpdatePhase.idle);
        return null;
      } on _BadStatus catch (e) {
        _log('сервер ответил ${e.code}');
        // 404 и прочие «нет такого файла» повтором не лечатся.
        if (e.code < 500 || attempt >= maxAttempts) {
          dropPart();
          state.value = UpdateProgress(
              phase: UpdatePhase.failed,
              error: 'Сервер обновлений ответил ошибкой ${e.code}. '
                  'Попробуйте позже или скачайте через браузер.');
          return null;
        }
        failure = _networkError;
      } on _Restart {
        dropPart();
        failure = _networkError;
      } on TimeoutException {
        failure = _stalledError;
      } catch (e) {
        if (_cancelled) {
          dropPart();
          state.value = const UpdateProgress(phase: UpdatePhase.idle);
          return null;
        }
        _log('попытка $attempt: ${_describe(e)}');
        failure = _networkError;
      }
      // Что успело лечь на диск, то и докачиваем.
      received = part.existsSync() ? part.lengthSync() : 0;
      if (attempt >= maxAttempts) {
        state.value = UpdateProgress(
            phase: UpdatePhase.failed,
            receivedBytes: received,
            totalBytes: total,
            error: failure);
        return null;
      }
      state.value = UpdateProgress(
          phase: UpdatePhase.downloading,
          receivedBytes: received,
          totalBytes: total);
      await Future<void>.delayed(retryDelay * attempt);
      if (_cancelled) {
        dropPart();
        state.value = const UpdateProgress(phase: UpdatePhase.idle);
        return null;
      }
    }

    // APK — это zip-архив и начинается с «PK», exe — с «MZ». Если пришло
    // что-то другое — скорее всего, страница с ошибкой вместо файла.
    var magic = const <int>[];
    try {
      final raf = part.openSync();
      magic = raf.readSync(2);
      raf.closeSync();
    } catch (_) {}
    if (magic.length < 2 || magic[0] != fileMagic[0] || magic[1] != fileMagic[1]) {
      dropPart();
      state.value = const UpdateProgress(
          phase: UpdatePhase.failed,
          error: 'Вместо файла обновления пришло что-то другое. '
              'Попробуйте позже или скачайте через браузер.');
      return null;
    }
    try {
      if (target.existsSync()) target.deleteSync();
      part.renameSync(target.path);
    } catch (e) {
      _log('не удалось сохранить файл: $e');
      dropPart();
      state.value = const UpdateProgress(
          phase: UpdatePhase.failed,
          error: 'Не хватает места для загрузки обновления.');
      return null;
    }
    _apkPath = target.path;
    state.value = UpdateProgress(
        phase: UpdatePhase.ready, receivedBytes: received, totalBytes: total);
    return target.path;
  }

  /// Одна попытка: дописывает файл в [part], начиная с байта [from]
  /// (докачка через Range). Возвращает, сколько байт теперь на диске и
  /// полный размер файла (0 — неизвестен).
  Future<({int received, int total})> _fetch(Uri url, File part, int from,
      {required int knownTotal}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'VPNonLine-updater';
    _client = client;
    IOSink? sink;
    try {
      // Переадресации — это нормально: GitHub отдаёт файл релиза со своего
      // хранилища, и ссылка переадресует туда. Заголовок Range Dart
      // переносит в запрос по новому адресу.
      final request = await client.getUrl(url);
      request.followRedirects = true;
      request.maxRedirects = 5;
      if (from > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
      }
      final response = await request.close().timeout(stallTimeout);
      var received = from;
      var total = knownTotal;
      switch (response.statusCode) {
        case HttpStatus.partialContent when from > 0:
          final range = parseContentRange(
              response.headers.value(HttpHeaders.contentRangeHeader));
          if (range == null || range.start != from) {
            await _drain(response);
            throw const _Restart();
          }
          if (range.total != null) total = range.total!;
        case HttpStatus.ok:
          // Докачку сервер не поддержал — файл целиком, с начала.
          received = 0;
          total = response.contentLength > 0 ? response.contentLength : 0;
        case HttpStatus.requestedRangeNotSatisfiable when from > 0:
          await _drain(response);
          throw const _Restart();
        default:
          await _drain(response);
          throw _BadStatus(response.statusCode);
      }
      sink = part.openWrite(
          mode: received > 0 ? FileMode.writeOnlyAppend : FileMode.writeOnly);
      var lastPercent = -1;
      var lastTick = DateTime.now();
      state.value = UpdateProgress(
          phase: UpdatePhase.downloading,
          receivedBytes: received,
          totalBytes: total);
      await for (final chunk in response.timeout(stallTimeout)) {
        if (_cancelled) throw const _Cancelled();
        sink.add(chunk);
        received += chunk.length;
        // Экран перерисовываем по процентам, а не на каждую порцию данных:
        // порций тысячи, и каждая перерисовка — работа для телефона.
        final percent = total > 0 ? (received * 100 ~/ total) : -1;
        final now = DateTime.now();
        if (percent != lastPercent ||
            (total == 0 && now.difference(lastTick).inMilliseconds > 250)) {
          lastPercent = percent;
          lastTick = now;
          state.value = UpdateProgress(
              phase: UpdatePhase.downloading,
              receivedBytes: received,
              totalBytes: total);
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      return (received: received, total: total);
    } finally {
      // Всё, что успело прийти, остаётся на диске — следующая попытка
      // продолжит с этого места.
      try {
        await sink?.close();
      } catch (_) {}
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  static Future<void> _drain(HttpClientResponse response) async {
    try {
      await response.drain<void>();
    } catch (_) {}
  }

  /// Начало и полный размер из заголовка `Content-Range: bytes 100-199/1000`.
  /// Полный размер null, если сервер написал «*».
  @visibleForTesting
  static ({int start, int? total})? parseContentRange(String? value) {
    if (value == null) return null;
    final m = RegExp(r'^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$').firstMatch(value);
    if (m == null) return null;
    return (start: int.parse(m.group(1)!), total: int.tryParse(m.group(3)!));
  }

  /// Ошибка сети в журнал — коротко и без длинной подписанной ссылки на
  /// хранилище, которую HttpException пишет в свой текст.
  static String _describe(Object e) => switch (e) {
        HttpException(:final message) => message,
        SocketException(:final message, :final osError) =>
          osError == null ? message : '$message (${osError.message})',
        TlsException(:final message) => 'TLS: $message',
        _ => e.runtimeType.toString(),
      };

  static void _log(String message) {
    unawaited(AppLogService.instance
        .log('Обновление: $message', level: AppLogLevel.warning));
  }
}

class _Restart implements Exception {
  const _Restart();
}

class _BadStatus implements Exception {
  const _BadStatus(this.code);
  final int code;
}

class _Cancelled implements Exception {
  const _Cancelled();
}
