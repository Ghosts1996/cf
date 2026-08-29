#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // [ИЗМЕНЕНО] Было 1280x720 в углу экрана (10,10) — для приложения с
  // мобильным (телефонным) UI это выглядело как гигантское почти пустое
  // окно. Берём компактный "телефонный" размер и центрируем окно на
  // экране пользователя вместо фиксированного угла.
  const int screen_w = ::GetSystemMetrics(SM_CXSCREEN);
  const int screen_h = ::GetSystemMetrics(SM_CYSCREEN);
  const unsigned int window_w = 420;
  // [ИЗМЕНЕНО] Было 860 — по просьбе пользователя окно слишком вытянуто по
  // вертикали на обычном Full HD экране (почти во весь экран по высоте).
  // 720 по-прежнему укладывает весь UI без внутренней прокрутки контента
  // ConnectScreen, но оставляет разумные отступы сверху/снизу на типичном
  // 1080p мониторе. Пользователь всё ещё может вручную растянуть окно.
  const unsigned int window_h = 720;
  Win32Window::Point origin(
      screen_w > static_cast<int>(window_w)
          ? (screen_w - static_cast<int>(window_w)) / 2
          : 10,
      screen_h > static_cast<int>(window_h)
          ? (screen_h - static_cast<int>(window_h)) / 2
          : 10);
  Win32Window::Size size(window_w, window_h);
  if (!window.Create(L"vpnonline_app", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}