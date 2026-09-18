// Значок приложения в системном трее (Windows/macOS/Linux):
//   1) иконка из assets/tray/app_icon.ico;
//   2) меню по правому клику — показать/скрыть окно, подключить/отключить,
//      выход (единственное место, где процесс завершается осознанно);
//   3) клик левой кнопкой разворачивает окно и выводит его на передний план;
//   4) иконка и подсказка синхронизированы со статусом туннеля.
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
    // Перехватываем крестик сами (см. onWindowClose ниже): при штатном
    // закрытии процесс завершился бы вместе с окном и трею было бы нечего
    // сворачивать.
    await windowManager.setPreventClose(true);

    trayManager.addListener(this);
    // trayManager на Windows ждёт реальный файл на диске, а не ключ ассета.
    // Flutter кладёт объявленные в pubspec.yaml ассеты в
    // 'data/flutter_assets/<путь>' рядом с .exe, поэтому путь строим от
    // Platform.resolvedExecutable.
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
    // Иконка одна на оба статуса — отдельной "отключённой" версии в
    // репозитории нет. Статус виден в подсказке при наведении и в пункте меню
    // "Подключить"/"Отключить" (см. _rebuildMenu()).
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
        // Подключение отсюда не запускаем: TunnelService.connect() нужна строка
        // подключения активного ключа, которую знает только ConnectScreen
        // (_effectiveConnectionString). Разворачиваем окно — дальше обычная кнопка
        // на экране сделает это правильно.
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
    // Выход из трея должен остановить туннель: на Windows это отдельный
    // процесс sing-box.exe, иначе он осиротеет и продолжит держать
    // TUN-адаптер (см. disconnect() в tunnel_service.dart).
    if (TunnelService.instance.isConnected) {
      await TunnelService.instance.disconnect();
    }
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowClose() async {
    // Крестик прячет окно в трей; явный выход — только через пункт "Выход"
    // (см. _quit() выше).
    final isPreventClose = await windowManager.isPreventClose();
    if (isPreventClose) {
      await windowManager.hide();
    }
  }
}