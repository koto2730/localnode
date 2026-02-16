import Cocoa
import FlutterMacOS
import Foundation

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // CLIモード時はウィンドウを非表示にしているため、falseを返す
    let args = ProcessInfo.processInfo.arguments
    if args.contains("--cli") {
      return false
    }
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

    // Folder channel for opening folders
    let folderChannel = FlutterMethodChannel(name: "com.ictglab.localnode/folder",
                                             binaryMessenger: controller.engine.binaryMessenger)
    folderChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      switch call.method {
      case "openFolder":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "ARGUMENT_ERROR",
                              message: "Path is required.",
                              details: nil))
          return
        }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    })
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
