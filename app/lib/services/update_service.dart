// Проверка обновлений приложения.
//
// Приложение ставится не из магазина, а файлом APK, и само о новой версии
// узнать не могло: пользователь сидел на старой сборке, пока ему не напишут в
// боте. Теперь приложение само спрашивает у GitHub, какой релиз последний, и
// если он новее установленного — показывает плашку с кнопкой «Обновить», а
// свёрнутое — системное уведомление.
//
// Почему не API GitHub, а переадресация. У API лимит — 60 запросов в час на
// один IP без авторизации. Все клиенты, подключённые к одному серверу VPN,
// выходят в интернет с одного адреса, и уже при нескольких десятках
// пользователей лимит кончался бы: проверка молча переставала бы работать.
//
// Вместо этого спрашиваем постоянную ссылку на файл последнего релиза:
// `releases/latest/download/app-release.apk`. GitHub отвечает на неё
// переадресацией на тот же файл конкретного релиза —
// `releases/download/build-340/app-release.apk`. Один запрос сразу даёт и
// номер последней сборки, и прямую ссылку на APK; сам файл не скачиваем —
// читаем только заголовок Location. Пока релизов нет, ответ — 404.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'local_prefs.dart';

/// Номер сборки, вшитый при сборке: `--dart-define=APP_BUILD=<номер>`. В
/// CI это номер запуска сборки — он только растёт. Ноль — сборка без номера
/// (локальная, для разработки): такая об обновлениях не спрашивает, сравнивать
/// ей не с чем.
const int kAppBuild = int.fromEnvironment('APP_BUILD', defaultValue: 0);

/// Версия для показа в «О приложении»: «1.0.<номер сборки>». Номер сборки
/// растёт с каждым выпуском, по нему видно, какая версия стоит. Без номера
/// (локальная сборка) — просто «1.0.0».
String get appVersionLabel => appVersionLabelFor(kAppBuild);

@visibleForTesting
String appVersionLabelFor(int build) => build > 0 ? '1.0.$build' : '1.0.0';

/// Найденное обновление.
@immutable
class AppUpdate {
  const AppUpdate({required this.build, required this.downloadUrl});

  /// Номер сборки последнего релиза.
  final int build;

  /// Прямая ссылка на APK последнего релиза.
  final Uri downloadUrl;
}

/// Что вернул запрос к странице последнего релиза: код ответа и адрес
/// переадресации. Вынесено в отдельный тип, чтобы сетевой запрос можно было
/// подменить в тестах.
typedef ReleaseProbe = Future<({int status, String? location})> Function(
    Uri url);

/// Номер последней сборки для Windows (см. [UpdateService.windowsBuildUrl]).
/// null — релиза для Windows ещё нет.
typedef WindowsBuildProbe = Future<int?> Function();

class UpdateService {
  UpdateService({
    ReleaseProbe? probe,
    WindowsBuildProbe? windowsProbe,
    bool? windows,
    int? currentBuild,
    DateTime Function()? now,
  })  : _probe = probe ?? probeLatestRelease,
        _windowsProbe = windowsProbe ?? fetchWindowsBuild,
        _windows = windows ?? Platform.isWindows,
        _currentBuild = currentBuild ?? kAppBuild,
        _now = now ?? DateTime.now;

  static final UpdateService instance = UpdateService();

  static const _owner = 'Ghosts1996';
  static const _repo = 'cf';

  /// Имя файла APK, которое сборка прикладывает к релизу.
  static const apkAssetName = 'app-release.apk';

  /// Тег релиза: `build-<номер сборки>`.
  static const tagPrefix = 'build-';

  /// Как часто спрашивать, пока приложение на экране, и при возврате в него.
  /// При запуске приложение спрашивает всегда (см. connect_screen.dart).
  /// Запрос лёгкий — один заголовок переадресации, — так что пять минут ничего
  /// не стоят, а вышедший релиз виден почти сразу. С часовой паузой плашка
  /// появлялась через час после выхода, если приложение недавно открывали.
  static const checkInterval = Duration(minutes: 5);

  /// Как часто спрашивать из свёрнутого приложения (пока работает VPN,
  /// процесс жив). Нашлась новая версия — системное уведомление, см.
  /// [claimAnnouncement].
  static const backgroundCheckInterval = Duration(hours: 1);

  static const _requestTimeout = Duration(seconds: 8);

  // ── Windows ─────────────────────────────────────────────────────────────
  //
  // Установщик для Windows лежит в отдельном постоянном релизе `windows`
  // (не «последнем» — тот остаётся за Android и его APK). Рядом с
  // установщиком — текстовый файл с номером сборки: по нему приложение и
  // узнаёт, что пора обновиться. Оба файла отдаются переадресацией на
  // хранилище GitHub, без API и его лимита запросов.

  static const windowsTag = 'windows';
  static const windowsInstallerName = 'VPNonLine-Setup.exe';
  static const windowsBuildFileName = 'windows-build.txt';

  static Uri get windowsInstallerUrl => Uri.parse(
      'https://github.com/$_owner/$_repo/releases/download/'
      '$windowsTag/$windowsInstallerName');

  static Uri get windowsBuildUrl => Uri.parse(
      'https://github.com/$_owner/$_repo/releases/download/'
      '$windowsTag/$windowsBuildFileName');

  final WindowsBuildProbe _windowsProbe;
  final bool _windows;
  final ReleaseProbe _probe;
  final int _currentBuild;
  final DateTime Function() _now;

  /// Найденное обновление, которое пользователь ещё не скрыл. null — нечего
  /// показывать.
  final ValueNotifier<AppUpdate?> available = ValueNotifier<AppUpdate?>(null);

  int get currentBuild => _currentBuild;

  /// Не удалось ли спросить GitHub в последней проверке (нет сети, GitHub
  /// недоступен). Нужно кнопке «Проверить обновления»: отличить «новой
  /// версии нет» от «не получилось узнать».
  bool get lastCheckFailed => _lastCheckFailed;
  bool _lastCheckFailed = false;

  static Uri get latestReleasePage =>
      Uri.parse('https://github.com/$_owner/$_repo/releases/latest');

  /// Постоянная ссылка на APK последнего релиза. По ней и узнаём номер
  /// сборки — из адреса, на который она переадресует.
  static Uri get latestApkUrl => Uri.parse(
      'https://github.com/$_owner/$_repo/releases/latest/download/$apkAssetName');

  static Uri downloadUrlFor(int build) => Uri.parse(
      'https://github.com/$_owner/$_repo/releases/download/'
      '$tagPrefix$build/$apkAssetName');

  /// Номер сборки из адреса переадресации. Понимает оба вида:
  /// `…/releases/download/build-123/app-release.apk` и
  /// `…/releases/tag/build-123`. null — адрес не того вида (например,
  /// переадресация на общий список релизов, пока ни одного нет).
  @visibleForTesting
  static int? buildFromLocation(String? location) {
    if (location == null || location.isEmpty) return null;
    final match = RegExp(
            '/releases/(?:download|tag)/${RegExp.escape(tagPrefix)}(\\d+)(?:/|\$)')
        .firstMatch(location.trim());
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// Проверяет, не вышла ли новая версия, и публикует её в [available].
  ///
  /// [force] — не смотреть на паузу между проверками; [maxAge] — сколько
  /// ждать после прошлой проверки. Ошибки сети наружу не выходят: проверка
  /// обновлений не должна мешать ничему остальному.
  Future<AppUpdate?> check({
    bool force = false,
    Duration maxAge = checkInterval,
  }) async {
    // Сборка без номера сравнивать себя ни с чем не может.
    if (_currentBuild <= 0) return null;

    final prefs = LocalPrefs.instance;
    if (!force) {
      final lastMs = await prefs.getInt(PrefKeys.updateLastCheckMs, fallback: 0);
      final last = DateTime.fromMillisecondsSinceEpoch(lastMs);
      if (_now().difference(last) < maxAge) {
        // Проверяли недавно — показываем то, что нашли тогда.
        return _publishRemembered();
      }
    }

    int? latest;
    _lastCheckFailed = false;
    try {
      if (_windows) {
        latest = await _windowsProbe().timeout(_requestTimeout);
      } else {
        final response = await _probe(latestApkUrl).timeout(_requestTimeout);
        // 404 — ни одного релиза ещё нет. Это не ошибка, просто нечего
        // предлагать. А вот 5xx — GitHub сейчас не отвечает: это сбой,
        // и прошлый ответ («новая версия есть») затирать им нельзя.
        if (response.status >= 500) {
          throw HttpException('GitHub ответил ${response.status}');
        }
        if (response.status >= 300 && response.status < 400) {
          latest = buildFromLocation(response.location);
        }
      }
    } catch (_) {
      // Нет сети, GitHub недоступен — попробуем в следующий раз. Время
      // проверки не записываем, чтобы не ждать паузу после случайного сбоя.
      _lastCheckFailed = true;
      return _publishRemembered();
    }

    await prefs.setInt(
        PrefKeys.updateLastCheckMs, _now().millisecondsSinceEpoch);
    await prefs.setInt(PrefKeys.updateLatestBuild, latest ?? 0);
    return _publishRemembered();
  }

  /// Проверка по кнопке «Проверить обновления»: всегда спрашивает GitHub и
  /// показывает в том числе версию, которую раньше скрыли «×», — раз
  /// человек спросил сам, значит, хочет её видеть.
  Future<AppUpdate?> checkNow() async {
    await LocalPrefs.instance.setInt(PrefKeys.updateDismissedBuild, 0);
    return check(force: true);
  }

  /// Сообщали ли уже о сборке [update] — плашкой на экране или системным
  /// уведомлением. Первый вызов для сборки отвечает true и запоминает её:
  /// о каждой версии уведомление приходит один раз.
  Future<bool> claimAnnouncement(AppUpdate update) async {
    final prefs = LocalPrefs.instance;
    final announced =
        await prefs.getInt(PrefKeys.updateAnnouncedBuild, fallback: 0);
    if (announced >= update.build) return false;
    await prefs.setInt(PrefKeys.updateAnnouncedBuild, update.build);
    return true;
  }

  /// Скрыть плашку для этой версии. Следующая версия покажется снова.
  Future<void> dismiss() async {
    final update = available.value;
    if (update == null) return;
    await LocalPrefs.instance
        .setInt(PrefKeys.updateDismissedBuild, update.build);
    available.value = null;
  }

  Future<AppUpdate?> _publishRemembered() async {
    final prefs = LocalPrefs.instance;
    final latest = await prefs.getInt(PrefKeys.updateLatestBuild, fallback: 0);
    final dismissed =
        await prefs.getInt(PrefKeys.updateDismissedBuild, fallback: 0);
    final AppUpdate? update = (latest > _currentBuild && latest != dismissed)
        ? AppUpdate(
            build: latest,
            downloadUrl: _windows ? windowsInstallerUrl : downloadUrlFor(latest))
        : null;
    available.value = update;
    return update;
  }

  /// Номер последней Windows-сборки из файла в релизе `windows`.
  @visibleForTesting
  static Future<int?> fetchWindowsBuild() async {
    final client = HttpClient()
      ..connectionTimeout = _requestTimeout
      ..userAgent = 'VPNonLine-updater';
    try {
      final request = await client.getUrl(windowsBuildUrl);
      request.followRedirects = true;
      request.maxRedirects = 5;
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_requestTimeout);
      return parseWindowsBuild(body);
    } finally {
      client.close(force: true);
    }
  }

  /// Номер сборки из содержимого `windows-build.txt`.
  @visibleForTesting
  static int? parseWindowsBuild(String body) {
    final value = int.tryParse(body.trim());
    return value != null && value > 0 ? value : null;
  }

  /// Настоящий запрос: GET без следования переадресации, тело не читаем.
  @visibleForTesting
  static Future<({int status, String? location})> probeLatestRelease(
      Uri url) async {
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      final request = await client.getUrl(url);
      request.followRedirects = false;
      final response = await request.close();
      final location = response.headers.value(HttpHeaders.locationHeader);
      // Тело не нужно — сливаем, чтобы соединение закрылось.
      await response.drain<void>();
      return (status: response.statusCode, location: location);
    } finally {
      client.close(force: true);
    }
  }
}
