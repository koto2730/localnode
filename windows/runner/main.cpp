#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  bool cli_mode = HasCliFlag();

  if (cli_mode) {
    // CLI mode: attach to parent console for stdout/stderr output.
    // Register console mode restoration before attaching so it runs on exit,
    // preventing the terminal from being left in a broken state (#78).
    atexit(RestoreConsoleInputMode);
    if (!AttachParentConsole()) {
      CreateAndAttachConsole();
    }
  } else {
    // GUI mode: attach to console when present (e.g., 'flutter run') or create
    // a new console when running with a debugger.
    if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
      CreateAndAttachConsole();
    }
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"localnode", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // In CLI mode, hide the window since we only need the Flutter engine.
  if (cli_mode) {
    ::ShowWindow(window.GetHandle(), SW_HIDE);
    window.SetHeadless(true);
    // Restore focus to the parent console after hiding the Flutter window
    // so IP selection prompts receive keyboard input correctly (#84).
    HWND hConsole = ::GetConsoleWindow();
    if (hConsole != nullptr) {
      ::SetForegroundWindow(hConsole);
    }
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
