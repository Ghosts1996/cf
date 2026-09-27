import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpnonline_app/services/local_prefs.dart';
import 'package:vpnonline_app/services/update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Страница releases/latest отвечает переадресацией на тег релиза.
  ReleaseProbe redirectTo(String location, {List<Uri>? calls}) => (url) async {
        calls?.add(url);
        return (status: 302, location: location);
      };

  // Настоящий вид переадресации с постоянной ссылки на файл последнего
  // релиза — именно такой ответ GitHub вернул на такую же ссылку чужого
  // репозитория при проверке.
  const latestTag = 'https://github.com/Ghosts1996/cf/releases/download/'
      'build-340/app-release.apk';

  var clock = DateTime(2026, 9, 27, 12);
  DateTime now() => clock;

  Future<void> resetPrefs() async {
    SharedPreferences.setMockInitialValues({});
    // LocalPrefs держит значения в памяти — сбрасываем явно.
    for (final key in [
      PrefKeys.updateLastCheckMs,
      PrefKeys.updateLatestBuild,
      PrefKeys.updateDismissedBuild,
    ]) {
      await LocalPrefs.instance.setInt(key, 0);
    }
  }

  setUp(() async {
    clock = DateTime(2026, 9, 27, 12);
    await resetPrefs();
  });

  group('номер сборки из переадресации', () {
    test('ссылка на файл релиза', () {
      expect(UpdateService.buildFromLocation(latestTag), 340);
    });
    test('страница тега', () {
      expect(
          UpdateService.buildFromLocation(
              'https://github.com/Ghosts1996/cf/releases/tag/build-340'),
          340);
    });
    test('релизов нет — GitHub отправляет на общий список, это не версия', () {
      // Ровно так ответил настоящий GitHub на releases/latest этого
      // репозитория, пока в нём не было ни одного релиза.
      expect(
          UpdateService.buildFromLocation(
              'https://github.com/Ghosts1996/cf/releases'),
          isNull);
    });
    test('относительный адрес и слэш в конце', () {
      expect(UpdateService.buildFromLocation('/Ghosts1996/cf/releases/tag/build-7/'), 7);
    });
    test('чужой вид тега не принимается за номер', () {
      expect(UpdateService.buildFromLocation('https://github.com/x/y/releases/tag/v1.2.3'), isNull);
      expect(UpdateService.buildFromLocation(null), isNull);
      expect(UpdateService.buildFromLocation(''), isNull);
    });
  });

  test('вышла новая сборка — плашка появляется со ссылкой на APK', () async {
    final service = UpdateService(
        probe: redirectTo(latestTag), currentBuild: 330, now: now);
    final update = await service.check();
    expect(update, isNotNull);
    expect(update!.build, 340);
    expect(update.downloadUrl.toString(),
        'https://github.com/Ghosts1996/cf/releases/download/build-340/app-release.apk');
    expect(service.available.value?.build, 340);
  });

  test('запрос идёт на постоянную ссылку файла, а не в API GitHub', () async {
    final calls = <Uri>[];
    final service = UpdateService(
        probe: redirectTo(latestTag, calls: calls), currentBuild: 330, now: now);
    await service.check();
    expect(calls.single.toString(),
        'https://github.com/Ghosts1996/cf/releases/latest/download/app-release.apk');
    expect(calls.single.host, isNot('api.github.com'),
        reason: 'у API лимит 60 запросов в час на IP — на общем выходе VPN он кончится');
  });

  test('установлена последняя — плашки нет', () async {
    final service = UpdateService(
        probe: redirectTo(latestTag), currentBuild: 340, now: now);
    expect(await service.check(), isNull);
    expect(service.available.value, isNull);
  });

  test('установлена сборка новее релиза — плашки нет', () async {
    final service = UpdateService(
        probe: redirectTo(latestTag), currentBuild: 351, now: now);
    expect(await service.check(), isNull);
  });

  test('сборка без номера (локальная) ни о чём не спрашивает', () async {
    final calls = <Uri>[];
    final service = UpdateService(
        probe: redirectTo(latestTag, calls: calls), currentBuild: 0, now: now);
    expect(await service.check(force: true), isNull);
    expect(calls, isEmpty);
  });

  test('релизов ещё нет (404, как отвечает GitHub) — плашки нет', () async {
    final service = UpdateService(
        probe: (_) async => (status: 404, location: null),
        currentBuild: 330,
        now: now);
    expect(await service.check(), isNull);
  });

  test('нет сети — тихо, без плашки и без исключения', () async {
    final service = UpdateService(
        probe: (_) async => throw Exception('нет сети'),
        currentBuild: 330,
        now: now);
    expect(await service.check(), isNull);
  });

  test('после сбоя сети пробуем снова сразу, а не через шесть часов', () async {
    var fail = true;
    final calls = <Uri>[];
    final service = UpdateService(
        probe: (url) async {
          calls.add(url);
          if (fail) throw Exception('нет сети');
          return (status: 302, location: latestTag);
        },
        currentBuild: 330,
        now: now);
    await service.check();
    fail = false;
    clock = clock.add(const Duration(minutes: 1));
    final update = await service.check();
    expect(calls.length, 2);
    expect(update?.build, 340);
  });

  test('чаще раза в шесть часов не спрашивает, но плашку помнит', () async {
    final calls = <Uri>[];
    final service = UpdateService(
        probe: redirectTo(latestTag, calls: calls), currentBuild: 330, now: now);
    await service.check();
    clock = clock.add(const Duration(hours: 2));
    final again = await service.check();
    expect(calls.length, 1, reason: 'повторный запрос раньше срока');
    expect(again?.build, 340, reason: 'найденное обновление не должно теряться');
    clock = clock.add(const Duration(hours: 5));
    await service.check();
    expect(calls.length, 2);
  });

  test('«×» скрывает эту версию, а следующая показывается снова', () async {
    var tag = latestTag;
    final service = UpdateService(
        probe: (_) async => (status: 302, location: tag),
        currentBuild: 330,
        now: now);
    await service.check();
    await service.dismiss();
    expect(service.available.value, isNull);
    expect(await service.check(force: true), isNull,
        reason: 'скрытая версия не должна появляться снова');
    tag = 'https://github.com/Ghosts1996/cf/releases/download/build-355/app-release.apk';
    final next = await service.check(force: true);
    expect(next?.build, 355, reason: 'новая версия — снова плашка');
  });
}
