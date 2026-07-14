import CryptoKit
import Flutter
import Security
import UIKit

/// ADR-012 §2.8 H 档：Keychain 对称 KEK wrap/unwrap DEK（对齐 Android AES-GCM 布局）。
/// 出参：12-byte IV ‖ ciphertext+tag。KEK 不回传 Dart。
/// 🔒 红线 #1 — 须人工 + 真机审。
final class HardwareKeystorePlugin: NSObject, FlutterPlugin {
  static let channelName = "elecon/keystore"
  private static let kekAccount = "elecon_h_kek_v1"
  private static let kekService = "dev.nancunchild.elecon.keystore"

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
      result(Self.ensureKek() != nil)
    case "wrapDek":
      guard let data = call.arguments as? FlutterStandardTypedData,
            data.data.count == 32 else {
        result(FlutterError(code: "bad_args", message: "DEK must be 32 bytes", details: nil))
        return
      }
      do {
        let out = try Self.wrapDek(Array(data.data))
        result(FlutterStandardTypedData(bytes: Data(out)))
      } catch {
        result(FlutterError(code: "keystore", message: error.localizedDescription, details: nil))
      }
    case "unwrapDek":
      guard let data = call.arguments as? FlutterStandardTypedData,
            data.data.count >= 12 + 16 else {
        result(FlutterError(code: "bad_args", message: "wrapped DEK too short", details: nil))
        return
      }
      do {
        let out = try Self.unwrapDek(Array(data.data))
        result(FlutterStandardTypedData(bytes: Data(out)))
      } catch {
        result(FlutterError(code: "keystore", message: error.localizedDescription, details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func ensureKek() -> Data? {
    if let existing = loadKek() { return existing }
    return createKek()
  }

  private static func loadKek() -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: kekAccount,
      kSecAttrService as String: kekService,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data, data.count == 32 else {
      return nil
    }
    return data
  }

  private static func createKek() -> Data? {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else { return nil }
    let data = Data(bytes)

    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: kekAccount,
      kSecAttrService as String: kekService,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    if addStatus == errSecDuplicateItem {
      return loadKek()
    }
    guard addStatus == errSecSuccess else { return nil }
    return data
  }

  /// AES-256-GCM：12B IV ‖ CT+tag（与 Android HardwareKeystorePlugin 一致）。
  private static func wrapDek(_ dek: [UInt8]) throws -> [UInt8] {
    guard let kek = ensureKek() else {
      throw NSError(domain: "elecon.keystore", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "no hardware KEK",
      ])
    }
    let key = SymmetricKey(data: kek)
    let sealed = try AES.GCM.seal(Data(dek), using: key)
    guard let combined = sealed.combined else {
      throw NSError(domain: "elecon.keystore", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "GCM seal failed",
      ])
    }
    return Array(combined)
  }

  private static func unwrapDek(_ wrapped: [UInt8]) throws -> [UInt8] {
    guard let kek = ensureKek() else {
      throw NSError(domain: "elecon.keystore", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "no hardware KEK",
      ])
    }
    let key = SymmetricKey(data: kek)
    let box = try AES.GCM.SealedBox(combined: Data(wrapped))
    let clear = try AES.GCM.open(box, using: key)
    return Array(clear)
  }
}
