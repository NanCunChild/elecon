import Flutter
import UIKit

/// iOS 暂不提供 ADR-012 §2.8 H 档。
/// Generic Password Keychain 中的可导出对称 KEK 不满足 H 档，故检测与操作均 fail-closed；
/// Dart bootstrap 会将旧版误标 H 的 blob 擦除并要求重新登录（ADR-012 §2.8）。
/// 🔒 红线 #1 — 须人工 + 真机审。
final class HardwareKeystorePlugin: NSObject, FlutterPlugin {
  static let channelName = "elecon/keystore"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = HardwareKeystorePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isHardwareAvailable":
      result(false)
    case "wrapDek":
      result(Self.unavailableError())
    case "unwrapDek":
      result(Self.unavailableError())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func unavailableError() -> FlutterError {
    FlutterError(
      code: "hardware_unavailable",
      message: "iOS hardware-backed DEK wrapping is unavailable",
      details: nil
    )
  }
}
