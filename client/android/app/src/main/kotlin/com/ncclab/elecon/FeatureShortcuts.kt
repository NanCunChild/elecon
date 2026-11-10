package com.ncclab.elecon

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** ADR-085: fixed navigation only; no identities, query arguments or results. */
class FeatureShortcuts(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "elecon/shortcuts")
    private var pending: String? = null
    private var ready = false

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialFeature" -> {
                    val initial = pending
                    pending = null
                    ready = true
                    result.success(initial)
                }
                "canPin" -> result.success(canPin())
                "pinState" -> result.success(pinState())
                "pinFeature" -> {
                    val id = call.arguments as? String
                    val spec = features[id]
                    if (id == null || spec == null) result.success("invalid")
                    else if (!canPin()) result.success("unsupported")
                    else try {
                        val manager = activity.getSystemService(ShortcutManager::class.java)
                        if (manager.pinnedShortcuts.any { it.id == id }) {
                            result.success("pinned")
                            return@setMethodCallHandler
                        }
                        val intent = Intent(activity, MainActivity::class.java)
                            .setAction(Intent.ACTION_VIEW)
                            .setData(Uri.parse("elecon://feature/$id"))
                        val shortcut = ShortcutInfo.Builder(activity, id)
                            .setShortLabel(activity.getString(spec.first))
                            .setIcon(Icon.createWithResource(activity, spec.second))
                            .setIntent(intent)
                            .build()
                        val callback = Intent(activity, ShortcutPinnedReceiver::class.java)
                            .setAction("${activity.packageName}.SHORTCUT_PINNED")
                            .setData(Uri.parse("elecon://shortcut-pinned/$id"))
                        val sender = PendingIntent.getBroadcast(activity, 0, callback,
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE).intentSender
                        result.success(if (manager.requestPinShortcut(shortcut, sender)) "requested" else "unsupported")
                    } catch (_: SecurityException) {
                        result.success("restricted")
                    } catch (_: IllegalStateException) {
                        result.success("unavailable")
                    } catch (_: RuntimeException) {
                        result.success("failed")
                    }
                }
                else -> result.notImplemented()
            }
        }
        active = this
    }

    fun accept(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val value = intent.dataString ?: return
        val id = value.removePrefix("elecon://feature/")
        if (value != "elecon://feature/$id" || !features.containsKey(id)) return
        // Rotation/process restoration must not replay an already handled Intent.
        activity.intent = Intent(activity, MainActivity::class.java).setAction(Intent.ACTION_MAIN)
        if (ready) channel.invokeMethod("openFeature", value) else pending = value
    }

    private fun canPin(): Boolean = try {
        Build.VERSION.SDK_INT >= 26 &&
            activity.getSystemService(ShortcutManager::class.java)?.isRequestPinShortcutSupported == true
    } catch (_: RuntimeException) { false }

    private fun pinState(): Map<String, Any> = try {
        val manager = activity.getSystemService(ShortcutManager::class.java)
        mapOf("supported" to (Build.VERSION.SDK_INT >= 26 && manager?.isRequestPinShortcutSupported == true), "pinned" to if (Build.VERSION.SDK_INT >= 25)
            activity.getSystemService(ShortcutManager::class.java)?.pinnedShortcuts
                ?.map { it.id }?.filter { features.containsKey(it) }.orEmpty() else emptyList<String>())
    } catch (_: SecurityException) {
        mapOf("supported" to false, "pinned" to emptyList<String>(), "error" to "restricted")
    } catch (_: RuntimeException) {
        mapOf("supported" to false, "pinned" to emptyList<String>(), "error" to "unavailable")
    }

    fun dispose() {
        if (active === this) active = null
        channel.setMethodCallHandler(null)
    }

    companion object {
        private var active: FeatureShortcuts? = null
        fun pinned(context: Context, intent: Intent) {
            val id = intent.data?.lastPathSegment ?: return
            if (intent.action != "${context.packageName}.SHORTCUT_PINNED" ||
                intent.dataString != "elecon://shortcut-pinned/$id" || !features.containsKey(id)) return
            active?.channel?.invokeMethod("pinStateChanged", null)
        }
        private val features = mapOf(
            "schedule" to (R.string.shortcut_schedule to R.drawable.shortcut_schedule),
            "grades" to (R.string.shortcut_grades to R.drawable.shortcut_grades),
            "exam" to (R.string.shortcut_exam to R.drawable.shortcut_exam),
            "classroom" to (R.string.shortcut_classroom to R.drawable.shortcut_classroom),
            "card" to (R.string.shortcut_card to R.drawable.shortcut_feature),
            "library" to (R.string.shortcut_library to R.drawable.shortcut_feature),
            "energy" to (R.string.shortcut_energy to R.drawable.shortcut_feature),
            "climate" to (R.string.shortcut_climate to R.drawable.shortcut_feature),
            "notice" to (R.string.shortcut_notice to R.drawable.shortcut_feature),
            "faculty" to (R.string.shortcut_faculty to R.drawable.shortcut_feature),
            "directory" to (R.string.shortcut_directory to R.drawable.shortcut_feature),
        )
    }
}

/** An explicit immutable PendingIntent is the only external path to this receiver. */
class ShortcutPinnedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = FeatureShortcuts.pinned(context, intent)
}
