package com.ncclab.elecon

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var featureShortcuts: FeatureShortcuts? = null
    private var scheduleWidgets: ScheduleWidgets? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(HardwareKeystorePlugin())
        flutterEngine.plugins.add(BackupExcludePlugin())
        flutterEngine.plugins.add(AppFunctionsPlugin())
        featureShortcuts = FeatureShortcuts(this, flutterEngine.dartExecutor.binaryMessenger)
        scheduleWidgets = ScheduleWidgets(this, flutterEngine.dartExecutor.binaryMessenger)
        scheduleWidgets?.accept(intent)
        featureShortcuts?.accept(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        scheduleWidgets?.accept(intent)
        featureShortcuts?.accept(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        featureShortcuts?.dispose()
        featureShortcuts = null
        scheduleWidgets?.dispose()
        scheduleWidgets = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
