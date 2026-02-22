#include "my_application.h"

#include <cstdlib>
#include <cstring>

int main(int argc, char** argv) {
  // If --cli or --help is specified, use offscreen GDK backend to avoid
  // requiring a display. This fixes headless environments (e.g. WSL,
  // Raspberry Pi) and prevents a black window in --cli mode (#79, #85).
  bool is_cli_mode = false;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--cli") == 0 || strcmp(argv[i], "--help") == 0 ||
        strcmp(argv[i], "-h") == 0) {
      is_cli_mode = true;
      setenv("GDK_BACKEND", "offscreen", 0);
      break;
    }
  }

  // In truly headless environments (no DISPLAY, no WAYLAND_DISPLAY), force
  // software OpenGL so Flutter's EGL initialisation succeeds without a
  // hardware GPU (e.g. WSL without WSLg) (#85).
  if (is_cli_mode) {
    const char* display = getenv("DISPLAY");
    const char* wayland  = getenv("WAYLAND_DISPLAY");
    if (display == nullptr && wayland == nullptr) {
      setenv("LIBGL_ALWAYS_SOFTWARE", "1", 0);
    }
  }

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
