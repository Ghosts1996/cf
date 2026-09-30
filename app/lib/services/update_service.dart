// Проверка обновлений приложения.
//
// Приложение ставится не из магазина, а файлом APK, и само о новой версии
// узнать не могло: пользователь сидел на старой сборке, пока ему не напишут в
// боте. Теперь раз в несколько часов приложение спрашивает у GitHub, какой
// релиз последний, и если он новее установленного — показывает плашку с
// кнопкой «Обновить».
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
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'local_prefs.dart';

/// Номер сборки, вшитый при сборке: `--dart-define=APP_BUILD=<номер>`. В
/// CI это номер запуска сборки — он только растёт. Ноль — сборка без номера
/// (локальная, для разработки): такая об обновлениях не спрашивает, сравнивать
/// ей не с чем.
const int kAppBuild = int.fromEnvironment('APP_BUILD', defaultValue: 0);

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

class UpdateService {
  UpdateService({
    ReleaseProbe? probe,
    int? currentBuild,
    DateTime Function()? now,
  })  : _probe = probe ?? probeLatestRelease,
        _currentBuild = currentBuild ?? kAppBuild,
        _now = now ?? DateTime.now;

  static final UpdateService instance = UpdateService();

  static const _owner = 'Ghosts1996';
  static const _repo = 'cf';

  /// Имя файла APK, которое сборка прикладывает к релизу.
  static const apkAssetName = 'app-release.apk';

  /// Тег релиза: `build-<номер сборки>`.
  static const tagPrefix = 'build-';

  /// Как часто спрашивать при возврате в приложение. При запуске приложение
  /// спрашивает всегда (см. connect_screen.dart). Час — чтобы свёрнутое на
  /// весь день приложение увидело релиз в тот же день, но не дёргало сеть на
  /// каждое переключение между приложениями.
  static const checkInterval = Duration(hours: 1);

  static const _requestTimeout = Duration(seconds: 8);

  final ReleaseProbe _probe;
  final int _currentBuild;
  final DateTime Function() _now;

  /// Найденное обновление, которое пользователь ещё не скрыл. null — нечего
  /// показывать.
  final ValueNotifier<AppUpdate?> available = ValueNotifier<AppUpdate?>(null);

  int get currentBuild => _currentBuild;

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
  /// [force] — не смотреть на паузу между проверками. Ошибки сети наружу не
  /// выходят: проверка обновлений не должна мешать ничему остальному.
  Future<AppUpdate?> check({bool force = false}) async {
    // Сборка без номера сравнивать себя ни с чем не может.
    if (_currentBuild <= 0) return null;

    final prefs = LocalPrefs.instance;
    if (!force) {
      final lastMs = await prefs.getInt(PrefKeys.updateLastCheckMs, fallback: 0);
      final last = DateTime.fromMillisecondsSinceEpoch(lastMs);
      if (_now().difference(last) < checkInterval) {
        // Проверяли недавно — показываем то, что нашли тогда.
        return _publishRemembered();
      }
    }

    int? latest;
    try {
      final response = await _probe(latestApkUrl).timeout(_requestTimeout);
      // 404 — ни одного релиза ещё нет. Это не ошибка, просто нечего
      // предлагать.
      if (response.status >= 300 && response.status < 400) {
        latest = buildFromLocation(response.location);
      }
    } catch (_) {
      // Нет сети, GitHub недоступен — попробуем в следующий раз. Время
      // проверки не записываем, чтобы не ждать час после
      // случайного сбоя.
      return _publishRemembered();
    }

    await prefs.setInt(
        PrefKeys.updateLastCheckMs, _now().millisecondsSinceEpoch);
    await prefs.setInt(PrefKeys.updateLatestBuild, latest ?? 0);
    return _publishRemembered();
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
        ? AppUpdate(build: latest, downloadUrl: downloadUrlFor(latest))
        : null;
    available.value = update;
    return update;
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
