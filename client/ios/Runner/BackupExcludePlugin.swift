import Flutter
import UIKit

/// 将 credentials 目录标记 isExcludedFromBackup（ADR-012 §2.8）。
final class BackupExcludePlugin: NSObject, FlutterPlugin {
  static let channelName = "elecon/backup"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = BackupExcludePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "excludeFromBackup" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let path = call.arguments as? String else {
      result(FlutterError(code: "bad_args", message: "path required", details: nil))
      return
    }
    do {
      try Self.exclude(path: path)
      result(nil)
    } catch {
      result(FlutterError(code: "backup", message: error.localizedDescription, details: nil))
    }
  }

  static func exclude(path: String) throws {
    let fm = FileManager.default
    if !fm.fileExists(atPath: path) {
      try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    var url = URL(fileURLWithPath: path, isDirectory: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }
}
