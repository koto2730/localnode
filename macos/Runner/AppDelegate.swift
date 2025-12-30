import Cocoa
import FlutterMacOS
import Foundation

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = mainFlutterWindow?.contentViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "com.ictglab.localnode/storage",
                                       binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      switch call.method {
      case "getDownloadsDirectory":
        guard let downloadsUrl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
          result(FlutterError(code: "UNAVAILABLE",
                              message: "Downloads directory not available.",
                              details: nil))
          return
        }
        let resolvedPath = (downloadsUrl.path as NSString).resolvingSymlinksInPath
        result(resolvedPath)
      default:
        result(FlutterMethodNotImplemented)
      }
    })
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
