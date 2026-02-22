#include "my_application.h"

#include <cstdio>
#include <cstring>

int main(int argc, char** argv) {
  // On Linux the standalone localnode-cli binary handles CLI/headless mode
  // without any GTK dependency.  Redirect users before GTK is initialised,
  // because library constructors (GTK, EGL) may run before we can inspect
  // argv if we let execution continue to my_application_new() (#79, #85).
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--cli") == 0 || strcmp(argv[i], "--help") == 0 ||
        strcmp(argv[i], "-h") == 0) {
      puts("CLI mode is not supported by the localnode GUI binary on Linux.\n"
           "Please use the localnode-cli binary included in this bundle:\n"
           "\n"
           "  localnode-cli [options]\n"
           "  localnode-cli --help\n"
           "\n"
           "localnode-cli runs without a display and has no GTK dependency.");
      return 0;
    }
  }

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
