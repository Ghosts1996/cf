// Загрузка обновления внутри приложения — на настоящем HTTP-сервере на
// 127.0.0.1, с переадресацией, как у GitHub (ссылка релиза → хранилище).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpnonline_app/services/update_installer.dart';
import 'package:vpnonline_app/services/update_service.dart';

class FakePlatform implements UpdatePlatform {
  FakePlatform(this.dir);
  final String dir;
  bool allowed = true;
  final installed = <String>[];
  int settingsOpened = 0;

  @override
  Future<String> updatesDir() async => dir;
  @override
  Future<bool> canInstall() async => allowed;
  @override
  Future<void> openInstallSettings() async => settingsOpened++;
  @override
  Future<void> installApk(String path) async => installed.add(path);
}

/// Похоже на APK: zip-архив начинается с «PK».
Uint8List fakeApk(int size) {
  final b = Uint8List(size);
  b[0] = 0x50;
  b[1] = 0x4B;
  for (var i = 2; i < size; i++) {
    b[i] = i % 251;
  }
  return b;
}

void main() {
  late HttpServer server;
  late Directory dir;
  late FakePlatform platform;
  // Что отдаёт «хранилище» на следующий запрос.
  late Future<void> Function(HttpResponse) storage;

  setUp(() async {
    HttpOverrides.global = null;
    dir = await Directory.systemTemp.createTemp('vpnonline-upd');
    platform = FakePlatform(dir.path);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
      if (req.uri.path.startsWith('/releases/download/')) {
        // Как GitHub: ссылка релиза переадресует на хранилище.
        res.statusCode = HttpStatus.found;
        res.headers.set(HttpHeaders.locationHeader,
            'http://127.0.0.1:${server.port}/storage/app.apk');
        await res.close();
        return;
      }
      await storage(res);
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  AppUpdate update() => AppUpdate(
      build: 341,
      downloadUrl: Uri.parse('http://127.0.0.1:${server.port}'
          '/releases/download/build-341/app-release.apk'));

  test('загрузка с переадресацией, шкала до 100 %, затем установка', () async {
    final apk = fakeApk(3 * 1024 * 1024 + 17);
    storage = (res) async {
      res.contentLength = apk.length;
      // Порциями, как по сети.
      for (var i = 0; i < apk.length; i += 64 * 1024) {
        res.add(apk.sublist(i, (i + 64 * 1024).clamp(0, apk.length)));
        await res.flush();
      }
      await res.close();
    };
    final installer = UpdateInstaller(platform: platform);
    final seen = <UpdateProgress>[];
    installer.state.addListener(() => seen.add(installer.state.value));

    await installer.downloadAndInstall(update());

    final percents = seen
        .where((p) => p.phase == UpdatePhase.downloading && p.percent != null)
        .map((p) => p.percent!)
        .toList();
    expect(percents.last, 100);
    for (var i = 1; i < percents.length; i++) {
      expect(percents[i], greaterThanOrEqualTo(percents[i - 1]),
          reason: 'шкала не должна прыгать назад');
    }
    expect(seen.length, lessThan(110),
        reason: 'экран перерисовывается по процентам, а не на каждую порцию');
    expect(installer.state.value.phase, UpdatePhase.ready);
    expect(platform.installed, hasLength(1));
    expect(File(platform.installed.single).readAsBytesSync(), apk,
        reason: 'на установку должен уйти ровно тот файл, что отдал сервер');
  });

  test('размер неизвестен — шкала бегущая, загрузка всё равно проходит',
      () async {
    final apk = fakeApk(200 * 1024);
    storage = (res) async {
      res.headers.chunkedTransferEncoding = true;
      res.add(apk);
      await res.close();
    };
    final installer = UpdateInstaller(platform: platform);
    final fractions = <double?>[];
    installer.state.addListener(() {
      if (installer.state.value.phase == UpdatePhase.downloading) {
        fractions.add(installer.state.value.fraction);
      }
    });
    await installer.downloadAndInstall(update());
    expect(fractions.every((f) => f == null), isTrue);
    expect(installer.state.value.phase, UpdatePhase.ready);
    expect(platform.installed, hasLength(1));
  });

  test('недокачанный файл не уходит на установку', () async {
    // Голый сокет: заявляем полный размер, отдаём половину и рвём
    // соединение — так выглядит обрыв связи посреди загрузки.
    final apk = fakeApk(500 * 1024);
    final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    raw.listen((socket) async {
      socket.listen((_) {}); // запрос читаем и не разбираем
      socket.add('HTTP/1.1 200 OK\r\n'
              'Content-Type: application/vnd.android.package-archive\r\n'
              'Content-Length: ${apk.length}\r\n\r\n'
          .codeUnits);
      socket.add(apk.sublist(0, apk.length ~/ 2));
      await socket.flush();
      socket.destroy();
    });
    final installer = UpdateInstaller(
        platform: platform, stallTimeout: const Duration(seconds: 5));
    await installer.downloadAndInstall(AppUpdate(
        build: 341,
        downloadUrl: Uri.parse('http://127.0.0.1:${raw.port}/app.apk')));
    await raw.close();
    expect(installer.state.value.phase, UpdatePhase.failed);
    expect(platform.installed, isEmpty);
    expect(dir.listSync(), isEmpty, reason: 'обрывки загрузки не копятся');
  });

  test('вместо APK пришла страница — не ставим', () async {
    storage = (res) async {
      res.headers.contentType = ContentType.html;
      res.write('<html>Rate limit exceeded</html>');
      await res.close();
    };
    final installer = UpdateInstaller(platform: platform);
    await installer.downloadAndInstall(update());
    expect(installer.state.value.phase, UpdatePhase.failed);
    expect(installer.state.value.error, contains('что-то другое'));
    expect(platform.installed, isEmpty);
  });

  test('сервер ответил 404 — понятная ошибка, без установки', () async {
    storage = (res) async {
      res.statusCode = 404;
      await res.close();
    };
    final installer = UpdateInstaller(platform: platform);
    await installer.downloadAndInstall(update());
    expect(installer.state.value.phase, UpdatePhase.failed);
    expect(installer.state.value.error, contains('404'));
    expect(platform.installed, isEmpty);
  });

  test('загрузка зависла — ошибка, а не вечная шкала', () async {
    final apk = fakeApk(300 * 1024);
    final hang = Completer<void>();
    storage = (res) async {
      res.contentLength = apk.length;
      res.add(apk.sublist(0, 1000));
      await res.flush();
      await hang.future; // дальше ни байта
    };
    final installer = UpdateInstaller(
        platform: platform, stallTimeout: const Duration(seconds: 1));
    await installer.downloadAndInstall(update());
    hang.complete();
    expect(installer.state.value.phase, UpdatePhase.failed);
    expect(installer.state.value.error, contains('остановилась'));
    expect(platform.installed, isEmpty);
  });

  test('«Отмена» останавливает загрузку и убирает файл', () async {
    final apk = fakeApk(2 * 1024 * 1024);
    storage = (res) async {
      res.contentLength = apk.length;
      for (var i = 0; i < apk.length; i += 16 * 1024) {
        res.add(apk.sublist(i, (i + 16 * 1024).clamp(0, apk.length)));
        await res.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await res.close();
    };
    final installer = UpdateInstaller(platform: platform);
    installer.state.addListener(() {
      final p = installer.state.value;
      if (p.phase == UpdatePhase.downloading && (p.percent ?? 0) >= 5) {
        installer.cancel();
      }
    });
    await installer.downloadAndInstall(update());
    expect(installer.state.value.phase, UpdatePhase.idle);
    expect(platform.installed, isEmpty);
    expect(dir.listSync(), isEmpty);
  });

  test('нет разрешения на установку — открываем настройки, потом ставим',
      () async {
    final apk = fakeApk(100 * 1024);
    var downloads = 0;
    storage = (res) async {
      downloads++;
      res.contentLength = apk.length;
      res.add(apk);
      await res.close();
    };
    platform.allowed = false;
    final installer = UpdateInstaller(platform: platform);
    await installer.downloadAndInstall(update());
    expect(installer.state.value.phase, UpdatePhase.needsPermission);
    expect(platform.settingsOpened, 1);
    expect(platform.installed, isEmpty);

    // Пользователь разрешил и нажал «Установить».
    platform.allowed = true;
    await installer.downloadAndInstall(update());
    expect(platform.installed, hasLength(1));
    expect(downloads, 1, reason: 'второй раз файл не качаем');
  });

  test('вернулись из настроек с разрешением — ставим сами; без разрешения '
      'настройки снова не открываем', () async {
    final apk = fakeApk(50 * 1024);
    storage = (res) async {
      res.contentLength = apk.length;
      res.add(apk);
      await res.close();
    };
    platform.allowed = false;
    final installer = UpdateInstaller(platform: platform);
    await installer.downloadAndInstall(update());
    expect(platform.settingsOpened, 1);

    // Вернулся, ничего не разрешив: остаёмся на «Установить», в настройки
    // не выкидываем.
    await installer.continueIfPermitted();
    expect(platform.settingsOpened, 1);
    expect(platform.installed, isEmpty);
    expect(installer.state.value.phase, UpdatePhase.needsPermission);

    // Разрешил и вернулся — установка идёт без второго нажатия.
    platform.allowed = true;
    await installer.continueIfPermitted();
    expect(platform.installed, hasLength(1));
    expect(installer.state.value.phase, UpdatePhase.ready);

    // Обычный возврат в приложение без ожидания разрешения — ничего.
    await installer.continueIfPermitted();
    expect(platform.installed, hasLength(1));
  });

  test('при запуске APK прошлого обновления удаляется, а идущая загрузка '
      'не трогается', () async {
    File('${dir.path}/vpnonline-341.apk').writeAsBytesSync(fakeApk(1000));
    final installer = UpdateInstaller(platform: platform);
    await installer.cleanup();
    expect(dir.listSync(), isEmpty);

    File('${dir.path}/vpnonline-342.apk').writeAsBytesSync(fakeApk(1000));
    installer.state.value =
        const UpdateProgress(phase: UpdatePhase.downloading);
    await installer.cleanup();
    expect(dir.listSync(), hasLength(1));
  });

  test('старые файлы от прошлых обновлений убираются', () async {
    File('${dir.path}/vpnonline-300.apk').writeAsBytesSync(fakeApk(1000));
    File('${dir.path}/vpnonline-320.apk.part').writeAsBytesSync([1, 2, 3]);
    final apk = fakeApk(10 * 1024);
    storage = (res) async {
      res.contentLength = apk.length;
      res.add(apk);
      await res.close();
    };
    await UpdateInstaller(platform: platform).downloadAndInstall(update());
    final names = dir.listSync().map((e) => e.uri.pathSegments.last).toList();
    expect(names, ['vpnonline-341.apk']);
  });
}
