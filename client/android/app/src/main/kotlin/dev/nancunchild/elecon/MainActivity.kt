package dev.nancunchild.elecon

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var featureShortcuts: FeatureShortcuts? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(HardwareKeystorePlugin())
        flutterEngine.plugins.add(BackupExcludePlugin())
        flutterEngine.plugins.add(AppFunctionsPlugin())
        featureShortcuts = FeatureShortcuts(this, flutterEngine.dartExecutor.binaryMessenger)
        featureShortcuts?.accept(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        featureShortcuts?.accept(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        featureShortcuts?.dispose()
        featureShortcuts = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
