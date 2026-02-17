import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // CLIモード時はウィンドウを非表示にする
    let args = ProcessInfo.processInfo.arguments
    if args.contains("--cli") || args.contains("--help") || args.contains("-h") {
      self.orderOut(nil)
      self.setIsVisible(false)
      // Dockアイコンも非表示
      NSApp.setActivationPolicy(.prohibited)
    }

    super.awakeFromNib()
  }
}
