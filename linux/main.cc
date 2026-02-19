#include "my_application.h"

#include <cstdlib>
#include <cstring>

// Registers the bundled fonts/ directory next to the binary with fontconfig
// so that CJK and other multibyte characters render correctly on minimal
// Linux systems (e.g. WSL, Raspberry Pi) that lack system CJK fonts (#72).
// Generates a temporary fonts.conf that prepends the bundled font directory
// to the system font search path, then sets FONTCONFIG_FILE to point to it.
// Only runs when FONTCONFIG_FILE is not already set by the user.
static void setup_bundled_fonts() {
  if (g_getenv("FONTCONFIG_FILE") != nullptr) {
    return;  // Respect user-defined fontconfig.
  }

  gchar* exe_path = g_file_read_link("/proc/self/exe", nullptr);
  if (exe_path == nullptr) return;

  gchar* exe_dir   = g_path_get_dirname(exe_path);
  gchar* fonts_dir = g_build_filename(exe_dir, "fonts", nullptr);
  g_free(exe_path);
  g_free(exe_dir);

  if (!g_file_test(fonts_dir, G_FILE_TEST_IS_DIR)) {
    g_free(fonts_dir);
    return;  // No bundled fonts directory; rely on system fonts.
  }

  gchar* conf = g_strdup_printf(
      "<?xml version=\"1.0\"?>\n"
      "<!DOCTYPE fontconfig SYSTEM \"fonts.dtd\">\n"
      "<fontconfig>\n"
      "  <!-- Bundled CJK fonts for systems without system CJK fonts. -->\n"
      "  <dir>%s</dir>\n"
      "  <!-- Include system fonts for everything else. -->\n"
      "  <include ignore_missing=\"yes\">/etc/fonts/fonts.conf</include>\n"
      "</fontconfig>\n",
      fonts_dir);
  g_free(fonts_dir);

  gchar* conf_path = g_build_filename(g_get_tmp_dir(),
                                       "localnode-fonts.conf", nullptr);
  if (g_file_set_contents(conf_path, conf, -1, nullptr)) {
    g_setenv("FONTCONFIG_FILE", conf_path, FALSE);
  }
  g_free(conf_path);
  g_free(conf);
}

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

  // Register bundled CJK fonts before GTK/Flutter initialise fontconfig.
  setup_bundled_fonts();

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
