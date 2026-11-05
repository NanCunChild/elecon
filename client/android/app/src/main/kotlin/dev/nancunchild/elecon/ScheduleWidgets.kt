package dev.nancunchild.elecon

import android.app.Activity
import android.app.KeyguardManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.view.View
import android.widget.LinearLayout
import android.widget.Button
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.RemoteViews
import android.widget.ScrollView
import android.widget.TextView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** ADR-090: an app-private, bounded projection, never a credential or script bridge. */
class ScheduleWidgets(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "elecon/schedule_widgets")
    private var pending: Int? = null
    private var ready = false
    private val screen = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = ScheduleWidgetStore.redraw(context)
    }

    init {
        ScheduleWidgetStore.changed = { channel.invokeMethod("widgetsChanged", null) }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
            addAction(Intent.ACTION_DATE_CHANGED)
            addAction(Intent.ACTION_TIMEZONE_CHANGED)
            addAction(Intent.ACTION_TIME_CHANGED)
        }
        if (Build.VERSION.SDK_INT >= 33) activity.registerReceiver(screen, filter, Context.RECEIVER_NOT_EXPORTED)
        else activity.registerReceiver(screen, filter)
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "beginSession" -> {
                        ScheduleWidgetStore.begin(activity)
                        ready = true
                        result.success(pending)
                        pending = null
                    }
                    "invalidate" -> {
                        ScheduleWidgetStore.invalidate(activity, (call.arguments as Number).toLong())
                        result.success(null)
                    }
                    "synchronize" -> {
                        val args = call.arguments as Map<*, *>
                        result.success(ScheduleWidgetStore.synchronize(activity,
                            (args["revision"] as Number).toLong(), args["contexts"] as List<*>))
                    }
                    "schoolDate" -> {
                        val zone = call.arguments as? String
                        result.success(try { LocalDate.now(ZoneId.of(zone)).toString() } catch (_: Exception) { null })
                    }
                    "publish" -> {
                        val args = call.arguments as Map<*, *>
                        ScheduleWidgetStore.publish(activity, (args["revision"] as Number).toLong(),
                            args["scope"] as String, (args["snapshot"] as? Map<*, *>)?.let { JSONObject(it) })
                        result.success(null)
                    }
                    "widgetScope" -> {
                        val id = (call.arguments as Number).toInt()
                        val binding = ScheduleWidgetStore.binding(activity, id)
                        result.success(binding?.optString("scope"))
                        if (binding == null && ScheduleWidgetStore.ids(activity).contains(id)) {
                            activity.startActivity(Intent(activity, ScheduleWidgetConfigureActivity::class.java)
                                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id))
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                // No exception text, course content, identity or raw arguments cross diagnostics.
                result.error("widget_unavailable", "Widget data unavailable", null)
            }
        }
    }

    fun accept(intent: Intent?) {
        if (intent?.action != "${activity.packageName}.OPEN_SCHEDULE_WIDGET") return
        val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        activity.intent = Intent(activity, MainActivity::class.java).setAction(Intent.ACTION_MAIN)
        if (!ScheduleWidgetStore.ids(activity).contains(id)) return
        if (ready) channel.invokeMethod("openWidget", id) else pending = id
    }

    fun dispose() {
        ScheduleWidgetStore.changed = null
        channel.setMethodCallHandler(null)
        activity.unregisterReceiver(screen)
    }
}

internal object ScheduleWidgetStore {
    var changed: (() -> Unit)? = null
    private var verified = false
    private var revision = 0L
    private val contexts = linkedMapOf<String, JSONObject>()
    private val records = mutableMapOf<Int, JSONObject>()
    private val scopePattern = Regex("^[a-f0-9]{64}$")
    private const val maxBytes = 256 * 1024
    private const val keyAlias = "elecon.schedule-widgets.v1"

    fun ids(context: Context): IntArray = AppWidgetManager.getInstance(context)
        .getAppWidgetIds(ComponentName(context, ScheduleWidgetProvider::class.java))

    fun begin(context: Context) {
        verified = false
        revision = 0
        contexts.clear()
        records.clear()
        redraw(context)
    }

    fun invalidate(context: Context, next: Long) {
        if (next < revision) return
        revision = next
        verified = false
        contexts.clear()
        for (id in ids(context)) remove(context, id)
        records.clear()
        redraw(context)
    }

    fun synchronize(context: Context, next: Long, raw: List<*>): List<String> {
        if (next < revision || raw.size > 16) return emptyList()
        val fresh = linkedMapOf<String, JSONObject>()
        for (entry in raw) {
            val row = entry as? Map<*, *> ?: continue
            val scope = row["scope"] as? String ?: continue
            val label = row["label"] as? String ?: continue
            if (!scopePattern.matches(scope) || label.length > 600 || row["persistent"] !is Boolean) continue
            fresh[scope] = JSONObject(mapOf("scope" to scope, "label" to label, "persistent" to row["persistent"]))
        }
        revision = next
        contexts.clear()
        contexts.putAll(fresh)
        verified = true
        val granted = linkedSetOf<String>()
        for (id in ids(context)) {
            val record = binding(context, id)
            // A locked device is temporarily unreadable, not revoked consent.
            if (record == null && !locked(context)) remove(context, id)
            else if (record != null) granted.add(record.getString("scope"))
        }
        redraw(context)
        return granted.toList()
    }

    fun choices(): List<JSONObject> = if (verified) contexts.values.toList() else emptyList()

    fun binding(context: Context, id: Int): JSONObject? {
        if (!verified || !ids(context).contains(id)) return null
        val record = records[id] ?: read(context, id)?.also { records[id] = it } ?: return null
        val scope = record.optString("scope")
        val active = contexts[scope] ?: return null
        if (record.optInt("version") != 1 || active.optBoolean("persistent") != record.optBoolean("persistent")) return null
        return record
    }

    fun bind(context: Context, id: Int, scope: String): Boolean {
        val active = contexts[scope] ?: return false
        if (!verified || !ids(context).contains(id)) return false
        val record = JSONObject().put("version", 1).put("scope", scope)
            .put("persistent", active.getBoolean("persistent"))
        records[id] = record
        if (!save(context, id, record)) { records.remove(id); return false }
        redraw(context)
        changed?.invoke()
        return true
    }

    fun publish(context: Context, expected: Long, scope: String, snapshot: JSONObject?) {
        if (!verified || expected != revision || !contexts.containsKey(scope)) return
        if (snapshot != null && !validSnapshot(snapshot)) throw IllegalArgumentException("invalid widget snapshot")
        for (id in ids(context)) {
            val record = binding(context, id) ?: continue
            if (record.optString("scope") != scope) continue
            record.remove("snapshot")
            if (snapshot != null) record.put("snapshot", snapshot)
            if (!save(context, id, record)) remove(context, id)
        }
        redraw(context)
    }

    private fun validSnapshot(data: JSONObject): Boolean = try {
        if (data.toString().toByteArray(Charsets.UTF_8).size > maxBytes || data.getInt("version") != 1) false
        else {
            ZoneId.of(data.getString("timeZone"))
            val fetched = data.getLong("fetchedAt")
            val fresh = data.getLong("freshUntil")
            val days = data.getJSONArray("days")
            val seen = mutableSetOf<String>()
            require(fetched > 0 && fetched <= System.currentTimeMillis() + 60_000 && fresh >= fetched && days.length() <= 7)
            for (i in 0 until days.length()) {
                val day = days.getJSONObject(i)
                require(seen.add(LocalDate.parse(day.getString("date")).toString()))
                day.getBoolean("known")
                val courses = day.getJSONArray("courses")
                require(courses.length() <= 32)
                for (j in 0 until courses.length()) {
                    val course = courses.getJSONObject(j)
                    require(course.getString("name").length in 1..240)
                    require(course.getString("location").length <= 240 && course.getString("label").length <= 160)
                    if (course.has("start") || course.has("end")) {
                        require(LocalTime.parse(course.getString("start")) < LocalTime.parse(course.getString("end")))
                    }
                }
            }
            true
        }
    } catch (_: Exception) { false }

    private fun file(context: Context, id: Int): AtomicFile = AtomicFile(File(context.noBackupFilesDir, "schedule-widgets/$id.bin"))

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(keyAlias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(keyAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true).build())
        return generator.generateKey()
    }

    private fun save(context: Context, id: Int, record: JSONObject): Boolean {
        val target = file(context, id)
        if (!record.optBoolean("persistent")) { target.delete(); return true }
        return try {
            val plaintext = record.toString().toByteArray(Charsets.UTF_8)
            require(plaintext.size <= maxBytes)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key())
            cipher.updateAAD("elecon.schedule-widget.v1:$id".toByteArray(Charsets.UTF_8))
            val ciphertext = cipher.doFinal(plaintext)
            target.baseFile.parentFile?.mkdirs()
            val stream = target.startWrite()
            try {
                stream.write(cipher.iv)
                stream.write(ciphertext)
                target.finishWrite(stream)
            } catch (error: Exception) { target.failWrite(stream); throw error }
            true
        } catch (_: Exception) { target.delete(); false }
    }

    private fun read(context: Context, id: Int): JSONObject? {
        if (!verified || locked(context)) return null
        val target = file(context, id)
        return try {
            if (!target.baseFile.exists()) return null
            require(target.baseFile.length() in 28..(maxBytes + 28).toLong())
            val bytes = target.readFully()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            cipher.updateAAD("elecon.schedule-widget.v1:$id".toByteArray(Charsets.UTF_8))
            JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
                .takeIf { it.optBoolean("persistent") && it.optInt("version") == 1 &&
                    (it.optJSONObject("snapshot")?.let(::validSnapshot) ?: true) }
        } catch (_: Exception) { target.delete(); null }
    }

    fun remove(context: Context, id: Int) { records.remove(id); file(context, id).delete() }
    fun locked(context: Context): Boolean = context.getSystemService(KeyguardManager::class.java)?.isDeviceLocked != false

    fun redraw(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        for (id in ids(context)) render(context, manager, id)
    }

    fun render(context: Context, manager: AppWidgetManager, id: Int) {
        val view = RemoteViews(context.packageName, R.layout.schedule_widget)
        val options = manager.getAppWidgetOptions(id)
        val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 180).coerceAtLeast(1)
        val scale = context.resources.configuration.fontScale.coerceAtLeast(1f)
        val compact = height < 170 * scale
        val padding = if (compact) 8 else 12
        val gap = if (compact) 4 else 8
        fun px(value: Int) = (value * context.resources.displayMetrics.density).toInt()
        view.setViewPadding(R.id.widget_root, px(padding), px(padding), px(padding), px(padding))
        view.setViewPadding(R.id.widget_courses, 0, px(gap), 0, 0)
        view.setViewVisibility(R.id.widget_title, if (compact) View.GONE else View.VISIBLE)
        view.setInt(R.id.widget_status, "setMaxLines", if (compact) 1 else 2)
        // Budget every visible line, including the cache status. Extremely large
        // text may leave status-only space; never force a row that cannot fit.
        val header = padding * 2 + gap + (if (compact) 14 else 50) * scale
        val rowHeight = (if (compact) 18 else 50) * scale + (if (compact) 4 else 8)
        val count = ((height - header) / rowHeight).toInt().coerceIn(0, 4)
        val open = Intent(context, MainActivity::class.java)
            .setAction("${context.packageName}.OPEN_SCHEDULE_WIDGET")
            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
            .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        view.setOnClickPendingIntent(R.id.widget_root, PendingIntent.getActivity(context, id, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        view.setTextViewText(R.id.widget_title, context.getString(R.string.widget_schedule_title))
        view.setTextViewText(R.id.widget_status, context.getString(R.string.widget_open_to_update))
        view.removeAllViews(R.id.widget_courses)
        if (!locked(context)) {
            val record = binding(context, id)
            val data = record?.optJSONObject("snapshot")
            if (data != null && validSnapshot(data)) {
                val zone = ZoneId.of(data.getString("timeZone"))
                val now = Instant.now().atZone(zone)
                val days = data.getJSONArray("days")
                val today = (0 until days.length()).map { days.getJSONObject(it) }
                    .firstOrNull { it.optString("date") == now.toLocalDate().toString() }
                val fetched = Instant.ofEpochMilli(data.getLong("fetchedAt")).atZone(zone)
                val age = if (System.currentTimeMillis() >= data.getLong("freshUntil"))
                    R.string.widget_cached_stale else R.string.widget_cached
                val cacheStatus = context.getString(age, DateTimeFormatter.ofPattern("MM-dd HH:mm").format(fetched))
                view.setTextViewText(R.id.widget_status, cacheStatus)
                view.setTextViewText(R.id.widget_title, context.getString(R.string.widget_schedule_date, now.toLocalDate().toString()))
                val courses = today?.optJSONArray("courses") ?: JSONArray()
                if (today == null || !today.optBoolean("known")) {
                    val label = context.getString(R.string.widget_unknown)
                    if (count > 0) addRow(context, view, label, "", compact)
                    else view.setTextViewText(R.id.widget_status, "$cacheStatus · $label")
                }
                else if (courses.length() == 0) {
                    val label = context.getString(R.string.widget_no_classes)
                    if (count > 0) addRow(context, view, label, "", compact)
                    else view.setTextViewText(R.id.widget_status, "$cacheStatus · $label")
                }
                else {
                    val all = (0 until courses.length()).map { courses.getJSONObject(it) }
                        .sortedBy { it.optString("start", "99:99") }
                    val next = all.firstOrNull { it.has("end") && LocalTime.parse(it.getString("end")) > now.toLocalTime() }
                    val selected = if (next != null) all.drop(all.indexOf(next)).take(count) else all.takeLast(count)
                    for (course in selected) {
                        val label = if (course === next) context.getString(
                            if (LocalTime.parse(course.getString("start")) <= now.toLocalTime()) R.string.widget_current else R.string.widget_next,
                            course.getString("name")) else course.getString("name")
                        addRow(context, view, label, listOf(course.getString("label"), course.getString("location")).filter { it.isNotEmpty() }.joinToString(" · "), compact)
                    }
                    if (all.size > selected.size) {
                        // Reuse the already budgeted status lines, never append an
                        // additional course-height row after filling the widget.
                        view.setTextViewText(R.id.widget_status,
                            "$cacheStatus · ${context.getString(R.string.widget_more, all.size - selected.size)}")
                    }
                }
            }
        }
        manager.updateAppWidget(id, view)
    }

    private fun addRow(context: Context, view: RemoteViews, title: String, detail: String, compact: Boolean) {
        val row = RemoteViews(context.packageName, R.layout.schedule_widget_course)
        row.setViewPadding(R.id.widget_course_row, 0, 0, 0,
            ((if (compact) 4 else 8) * context.resources.displayMetrics.density).toInt())
        row.setTextViewText(R.id.widget_course_name, title)
        row.setTextViewText(R.id.widget_course_detail, detail)
        row.setViewVisibility(R.id.widget_course_detail, if (compact || detail.isEmpty()) View.GONE else View.VISIBLE)
        view.addView(R.id.widget_courses, row)
    }
}

class ScheduleWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) ScheduleWidgetStore.render(context, manager, id)
    }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) =
        ScheduleWidgetStore.render(context, manager, id)
    override fun onDeleted(context: Context, ids: IntArray) { for (id in ids) ScheduleWidgetStore.remove(context, id) }
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action in listOf(Intent.ACTION_DATE_CHANGED, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED, Intent.ACTION_USER_PRESENT)) ScheduleWidgetStore.redraw(context)
    }
}

class ScheduleWidgetConfigureActivity : Activity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setResult(RESULT_CANCELED)
        widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID || !ScheduleWidgetStore.ids(this).contains(widgetId)) finish()
    }
    override fun onResume() {
        super.onResume()
        if (isFinishing) return
        val choices = if (ScheduleWidgetStore.locked(this)) emptyList() else ScheduleWidgetStore.choices()
        var selected = 0
        fun px(value: Int) = (value * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(px(16), px(16), px(16), px(16))
            setOnApplyWindowInsetsListener { view, insets ->
                @Suppress("DEPRECATION")
                view.setPadding(px(16) + insets.systemWindowInsetLeft, px(16) + insets.systemWindowInsetTop,
                    px(16) + insets.systemWindowInsetRight, px(16) + insets.systemWindowInsetBottom)
                insets
            }
        }
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(TextView(this@ScheduleWidgetConfigureActivity).apply {
                text = getString(R.string.widget_schedule_title)
                textSize = 22f
                setPadding(0, 0, 0, px(16))
            })
            addView(TextView(this@ScheduleWidgetConfigureActivity).apply {
                text = getString(R.string.widget_consent)
                textSize = 16f
                setPadding(0, 0, 0, px(16))
            })
            if (choices.isNotEmpty()) addView(RadioGroup(this@ScheduleWidgetConfigureActivity).apply {
                for ((index, choice) in choices.withIndex()) addView(RadioButton(this@ScheduleWidgetConfigureActivity).apply {
                    id = View.generateViewId()
                    text = choice.getString("label")
                    textSize = 16f
                    isChecked = index == 0
                    setOnClickListener { selected = index }
                    minHeight = px(48)
                })
            })
        }
        root.addView(ScrollView(this).apply { addView(body) },
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(Button(this).apply {
            setText(if (choices.isEmpty()) R.string.widget_open_app else R.string.widget_allow)
            setOnClickListener {
                if (choices.isEmpty()) {
                    startActivity(Intent(this@ScheduleWidgetConfigureActivity, MainActivity::class.java).setAction(Intent.ACTION_MAIN))
                } else {
                    if (ScheduleWidgetStore.bind(this@ScheduleWidgetConfigureActivity, widgetId, choices[selected].getString("scope"))) {
                        setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
                    }
                    finish()
                }
            }
        }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        root.addView(Button(this).apply {
            setText(android.R.string.cancel)
            setOnClickListener { finish() }
        }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        setContentView(root)
        root.requestApplyInsets()
    }
}
