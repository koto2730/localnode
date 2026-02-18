#include "my_application.h"

#include <cstdlib>
#include <cstring>

int main(int argc, char** argv) {
  // If --cli or --help is specified, use offscreen GDK backend to avoid
  // requiring a display. This fixes headless environments (e.g. Raspberry Pi)
  // and prevents a black window from appearing in --cli mode on desktop Linux.
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--cli") == 0 || strcmp(argv[i], "--help") == 0 ||
        strcmp(argv[i], "-h") == 0) {
      setenv("GDK_BACKEND", "offscreen", 0);
      break;
    }
  }

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
