// [НОВОЕ — значок в системном трее Windows] До этого файла у приложения
// вообще не было ни одной строчки кода про трей — ни пакета в pubspec.yaml,
// ни обработчика закрытия окна. Пользователь видел пустое место рядом с
// часами не из-за бага, а потому что эта функциональность физически не
// была реализована. Этот файл добавляет её:
//   1) значок в трее (реальный .ico, тот же, что и у самого приложения —
//      см. assets/tray/app_icon.ico, скопирован из
//      windows/runner/resources/app_icon.ico);
//   2) меню по правому клику: Показать/Скрыть окно, Подключить/Отключить
//      (сразу дергает TunnelService, без необходимости разворачивать окно),
//      Выход (реально завершает процесс — единственное место, где это
//      происходит осознанно, а не через крестик на окне);
//   3) клик левой кнопкой по значку — показать и вывести окно на передний
//      план (стандартное поведение трей-иконок в Windows);
//   4) синхронизацию иконки/подсказки (tooltip) с реальным статусом
//      туннеля — трей показывает "VPN onLine — подключено (сервер)" или
//      "VPN onLine — отключено", а не статичную надпись.
//
// [ВАЖНО — то, что нельзя сделать одной правкой .dart-файла]
// Пакеты window_manager/tray_manager нужно подтянуть командой
// `flutter pub get` (уже добавлены в pubspec.yaml) и пересобрать Windows-
// приложение — без пересборки трей не появится, просто правка исходников
// его не создаст на уже собранном .exe.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'tunnel_service.dart';

class TrayService with TrayListener, WindowListener {
  TrayService._();
  static final TrayService instance = TrayService._();

  bool _initialized = false;

  bool get _supported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  Future<void> init() async {
    if (!_supported || _initialized) return;
    _initialized = true;

    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    // [НОВОЕ] Перехватываем нажатие крестика самостоятельно (см.
    // onWindowClose ниже) вместо стандартного немедленного закрытия —
    // иначе окно закрылось бы штатно и процесс завершился бы вместе с ним,
    // трей был бы бессмысленным (нечего было бы "сворачивать").
    await windowManager.setPreventClose(true);

    trayManager.addListener(this);
    // [НОВОЕ] Путь к .ico на диске, а не просто ключ ассета — trayManager
    // на Windows ожидает реальный файл. Flutter кладёт объявленные в
    // pubspec.yaml assets в 'data/flutter_assets/<путь>' рядом с .exe при
    // сборке релиза/дебага, поэтому путь строим относительно
    // Platform.resolvedExecutable, а не через AssetBundle.
    await trayManager.setIcon(_iconPath);
    await trayManager.setToolTip('VPN onLine');
    await _rebuildMenu();

    TunnelService.instance.status.addListener(_onTunnelChanged);
    TunnelService.instance.connectedServerName.addListener(_onTunnelChanged);
    _onTunnelChanged();
  }

  String get _iconPath {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    return '$exeDir${sep}data${sep}flutter_assets${sep}assets${sep}tray${sep}app_icon.ico';
  }

  Future<void> _rebuildMenu() async {
    final connected = TunnelService.instance.isConnected;
    final busy = TunnelService.instance.isBusy;
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(
            key: 'show',
            label: 'Показать VPN onLine',
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'toggle_connection',
            label: connected ? 'Отключить' : 'Подключить',
            disabled: busy,
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'exit',
            label: 'Выход',
          ),
        ],
      ),
    );
  }

  void _onTunnelChanged() {
    if (!_supported) return;
    final connected = TunnelService.instance.isConnected;
    final serverName = TunnelService.instance.connectedServerName.value;
    unawaited(trayManager.setToolTip(
      connected
          ? 'VPN onLine — подключено${serverName != null ? ' ($serverName)' : ''}'
          : 'VPN onLine — отключено',
    ));
    // [НОВОЕ] Тот же .ico на обоих статусах намеренно — отдельной
    // "отключённой" версии иконки в репозитории нет, а рисовать новую
    // самому — не мой файл принять решение о дизайне. Статус всё равно
    // честно виден в подсказке при наведении и в самом меню (пункт
    // "Подключить"/"Отключить" уже меняется см. _rebuildMenu()).
    unawaited(_rebuildMenu());
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_showWindow());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(_showWindow());
        break;
      case 'toggle_connection':
        if (TunnelService.instance.isBusy) return;
        if (TunnelService.instance.isConnected) {
          unawaited(TunnelService.instance.disconnect());
        }
        // [НОВОЕ] Подключение из трея намеренно не запускается отсюда —
        // TunnelService.connect() требует строку подключения конкретного
        // активного ключа, которую сейчас знает только ConnectScreen (см.
        // _effectiveConnectionString в connect_screen.dart). Дёргать
        // подключение вслепую отсюда без этого контекста означало бы либо
        // дублировать логику выбора ключа, либо рисковать подключением не
        // к тому серверу. Вместо этого просто разворачиваем окно — дальше
        // обычная кнопка "Подключиться" на экране сделает это правильно.
        else {
          unawaited(_showWindow());
        }
        break;
      case 'exit':
        unawaited(_quit());
        break;
    }
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    await trayManager.destroy();
    // [НОВОЕ] Реальный выход из трея должен по-настоящему остановить
    // туннель (отдельный процесс sing-box.exe на Windows) — иначе он
    // осиротеет и продолжит держать TUN-адаптер после закрытия приложения
    // (см. разбор именно этого сценария в disconnect() —
    // tunnel_service.dart). setPreventClose(true) не даёт это сделать
    // через обычный exitCode(0)/окно — закрываем явно и осознанно только
    // здесь.
    if (TunnelService.instance.isConnected) {
      await TunnelService.instance.disconnect();
    }
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowClose() async {
    // [НОВОЕ] Крестик на окне теперь прячет окно в трей вместо выхода —
    // явный выход возможен только через пункт "Выход" в меню трея (см.
    // _quit() выше). Это стандартное поведение большинства десктопных
    // VPN-клиентов (и было явно то, чего просил пользователь — значок в
    // трее, а не просто окно, сворачивающееся в панель задач).
    final isPreventClose = await windowManager.isPreventClose();
    if (isPreventClose) {
      await windowManager.hide();
    }
  }
}