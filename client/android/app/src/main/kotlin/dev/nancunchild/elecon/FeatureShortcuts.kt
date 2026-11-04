package dev.nancunchild.elecon

import android.app.Activity
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
                "pinFeature" -> {
                    val id = call.arguments as? String
                    val spec = features[id]
                    if (id == null || spec == null || !canPin()) result.success(false)
                    else try {
                        val intent = Intent(activity, MainActivity::class.java)
                            .setAction(Intent.ACTION_VIEW)
                            .setData(Uri.parse("elecon://feature/$id"))
                        val shortcut = ShortcutInfo.Builder(activity, id)
                            .setShortLabel(activity.getString(spec.first))
                            .setIcon(Icon.createWithResource(activity, spec.second))
                            .setIntent(intent)
                            .build()
                        result.success(activity.getSystemService(ShortcutManager::class.java)
                            .requestPinShortcut(shortcut, null))
                    } catch (_: RuntimeException) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
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

    private fun canPin(): Boolean = Build.VERSION.SDK_INT >= 26 &&
        activity.getSystemService(ShortcutManager::class.java)?.isRequestPinShortcutSupported == true

    fun dispose() { channel.setMethodCallHandler(null) }

    companion object {
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
