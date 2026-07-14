import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HardwareKeystorePlugin")
    if let registrar = registrar {
      HardwareKeystorePlugin.register(with: registrar)
    }
    let backupRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "BackupExcludePlugin")
    if let backupRegistrar = backupRegistrar {
      BackupExcludePlugin.register(with: backupRegistrar)
    }
  }
}
