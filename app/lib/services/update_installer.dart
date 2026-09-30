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
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

class UpdateInstaller {
  UpdateInstaller({
    UpdatePlatform? platform,
    this.stallTimeout = const Duration(seconds: 30),
  }) : _platform = platform ?? ChannelUpdatePlatform();

  static final UpdateInstaller instance = UpdateInstaller();

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
      state.value = UpdateProgress(
          phase: UpdatePhase.failed,
          error: 'Не удалось запустить установку: $e');
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
      // Старые файлы — от прошлых обновлений или оборванной загрузки —
      // убираем: APK весит под сотню мегабайт, копить их незачем.
      if (dir.existsSync()) {
        for (final f in dir.listSync()) {
          try {
            f.deleteSync(recursive: true);
          } catch (_) {}
        }
      } else {
        dir.createSync(recursive: true);
      }
    } catch (e) {
      state.value = UpdateProgress(
          phase: UpdatePhase.failed, error: 'Нет места для загрузки: $e');
      return null;
    }

    final part = File('${dir.path}/vpnonline-${update.build}.apk.part');
    final target = File('${dir.path}/vpnonline-${update.build}.apk');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'VPNonLine-updater';
    _client = client;
    IOSink? sink;
    try {
      // Переадресации — это нормально: GitHub отдаёт файл релиза со своего
      // хранилища, и ссылка переадресует туда.
      final request = await client.getUrl(update.downloadUrl);
      request.followRedirects = true;
      request.maxRedirects = 5;
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('сервер ответил ${response.statusCode}');
      }
      final total = response.contentLength > 0 ? response.contentLength : 0;
      sink = part.openWrite();
      var received = 0;
      var lastPercent = -1;
      var lastTick = DateTime.now();
      final head = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(stallTimeout)) {
        if (_cancelled) throw const _Cancelled();
        sink.add(chunk);
        received += chunk.length;
        if (head.length < 2) head.add(chunk.take(2 - head.length).toList());
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
      if (_cancelled) throw const _Cancelled();

      // Недокачанный файл Android отвергнет с невнятной ошибкой «ошибка
      // разбора пакета». Лучше поймать это здесь и сказать как есть.
      if (total > 0 && received != total) {
        throw HttpException('файл загрузился не полностью '
            '($received из $total байт)');
      }
      // APK — это zip-архив и начинается с «PK». Если пришло что-то другое —
      // скорее всего, страница с ошибкой вместо файла.
      final magic = head.takeBytes();
      if (magic.length < 2 || magic[0] != 0x50 || magic[1] != 0x4B) {
        throw const HttpException('вместо файла обновления пришло что-то другое');
      }

      if (target.existsSync()) target.deleteSync();
      part.renameSync(target.path);
      _apkPath = target.path;
      state.value = UpdateProgress(
          phase: UpdatePhase.ready, receivedBytes: received, totalBytes: total);
      return target.path;
    } on _Cancelled {
      state.value = const UpdateProgress(phase: UpdatePhase.idle);
      return null;
    } on TimeoutException {
      state.value = const UpdateProgress(
          phase: UpdatePhase.failed,
          error: 'Загрузка остановилась — проверьте интернет и повторите.');
      return null;
    } catch (e) {
      state.value = UpdateProgress(
          phase: _cancelled ? UpdatePhase.idle : UpdatePhase.failed,
          error: _cancelled ? null : 'Не удалось загрузить обновление: $e');
      return null;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      if (_apkPath == null) {
        try {
          if (part.existsSync()) part.deleteSync();
        } catch (_) {}
      }
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
