#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>

// Saved console input mode for restoration on exit (#78).
static DWORD g_savedConsoleInputMode = 0;
static bool g_consoleModesSaved = false;

// Configures the Win32 stdin handle and console input mode for CLI use.
// Dart's dart:io reads via GetStdHandle(STD_INPUT_HANDLE) directly, so
// freopen_s alone is insufficient for a WIN32-subsystem process.
static void SetupConsoleInput() {
  HANDLE hConIn = ::CreateFile(
      L"CONIN$", GENERIC_READ | GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (hConIn == INVALID_HANDLE_VALUE) {
    return;
  }
  // Update the Win32 stdin handle so Dart's dart:io can read from it (#76).
  ::SetStdHandle(STD_INPUT_HANDLE, hConIn);

  // Save the original mode before any modification, for restoration on
  // exit to prevent the terminal from being left in a broken state (#78).
  DWORD mode = 0;
  if (::GetConsoleMode(hConIn, &mode)) {
    g_savedConsoleInputMode = mode;
    g_consoleModesSaved = true;
    // ENABLE_PROCESSED_INPUT ensures Ctrl+C generates a CTRL_C_EVENT signal
    // rather than being delivered as a raw character, allowing Dart's
    // ProcessSignal.sigint handler to fire reliably (#77).
    // Explicitly set ENABLE_ECHO_INPUT and ENABLE_LINE_INPUT in case the
    // parent shell had modified these flags, ensuring typed characters are
    // echoed during IP selection prompts (#84).
    ::SetConsoleMode(hConIn,
        mode | ENABLE_PROCESSED_INPUT | ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT);
  }
}

void SaveConsoleInputMode() {
  HANDLE hIn = ::GetStdHandle(STD_INPUT_HANDLE);
  if (hIn != INVALID_HANDLE_VALUE && !g_consoleModesSaved) {
    if (::GetConsoleMode(hIn, &g_savedConsoleInputMode)) {
      g_consoleModesSaved = true;
    }
  }
}

void RestoreConsoleInputMode() {
  if (!g_consoleModesSaved) return;
  HANDLE hIn = ::GetStdHandle(STD_INPUT_HANDLE);
  if (hIn != INVALID_HANDLE_VALUE) {
    ::SetConsoleMode(hIn, g_savedConsoleInputMode);
  }
}

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    freopen_s(&unused, "CONIN$", "r", stdin);
    SetupConsoleInput();
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

bool AttachParentConsole() {
  if (::AttachConsole(ATTACH_PARENT_PROCESS)) {
    FILE *unused;
    freopen_s(&unused, "CONOUT$", "w", stdout);
    freopen_s(&unused, "CONOUT$", "w", stderr);
    freopen_s(&unused, "CONIN$", "r", stdin);
    SetupConsoleInput();
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
    return true;
  }
  return false;
}

bool HasCliFlag() {
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return false;
  }
  bool found = false;
  for (int i = 1; i < argc; i++) {
    if (wcscmp(argv[i], L"--cli") == 0 || wcscmp(argv[i], L"--help") == 0 ||
        wcscmp(argv[i], L"-h") == 0) {
      found = true;
      break;
    }
  }
  ::LocalFree(argv);
  return found;
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  unsigned int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      -1, nullptr, 0, nullptr, nullptr)
    -1; // remove the trailing null character
  int input_length = (int)wcslen(utf16_string);
  std::string utf8_string;
  if (target_length == 0 || target_length > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}
