package dev.nancunchild.elecon

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * ADR-012 §2.8：credentials 路径侧二次确认。
 * Manifest 已 allowBackup=false；本插件供 Dart FileBlobStore 统一调用 no-op 成功。
 */
class BackupExcludePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "excludeFromBackup" -> {
                val path = call.arguments as? String
                if (path == null) {
                    result.error("bad_args", "path required", null)
                    return
                }
                // Android：全应用 allowBackup=false；仅确保目录存在。
                File(path).mkdirs()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        const val CHANNEL = "elecon/backup"
    }
}
