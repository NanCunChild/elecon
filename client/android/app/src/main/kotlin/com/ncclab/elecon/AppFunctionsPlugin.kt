package com.ncclab.elecon

import android.os.Handler
import android.os.Looper
import android.os.Build
import androidx.appfunctions.AppFunctionManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/** A live-engine bridge. It never starts an engine, unlocks storage or keeps query results. */
class AppFunctionsPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "elecon/app_functions")
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(
                    Build.VERSION.SDK_INT >= 36 &&
                        AppFunctionManager.getInstance(binding.applicationContext) != null,
                )
                "validateSchoolTimeZone" -> {
                    val arguments = call.arguments as? Map<*, *>
                    result.success(if (Build.VERSION.SDK_INT >= 26) SchoolQueryTimeZone.validate(
                        arguments?.get("timeZone") as? String,
                        arguments?.get("startAt") as? String,
                        arguments?.get("endAt") as? String,
                    ) else "unknown")
                }
                else -> result.notImplemented()
            }
        }
        AppFunctionsGateway.attach(channel!!)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.let { AppFunctionsGateway.detach(it) }
        channel?.setMethodCallHandler(null)
        channel = null
    }
}

internal object AppFunctionsGateway {
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var channel: MethodChannel? = null

    fun attach(value: MethodChannel) { channel = value }
    fun detach(value: MethodChannel) { if (channel === value) channel = null }

    suspend fun query(function: String, arguments: Map<String, Any?>): String {
        val owner = channel ?: return unavailable
        val requestId = UUID.randomUUID().toString()
        return withTimeoutOrNull(30_000) {
            suspendCancellableCoroutine { continuation ->
                continuation.invokeOnCancellation {
                    main.post { owner.invokeMethod("cancel", mapOf("requestId" to requestId)) }
                }
                main.post {
                    if (!continuation.isActive) return@post
                    if (channel !== owner) {
                        continuation.resume(unavailable)
                        return@post
                    }
                    owner.invokeMethod("execute", mapOf(
                        "requestId" to requestId,
                        "function" to function,
                        "arguments" to arguments,
                    ), object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            if (continuation.isActive) {
                                val json = result as? String
                                continuation.resume(if (json != null && json.toByteArray().size <= 131072) json else unavailable)
                            }
                        }
                        override fun error(code: String, message: String?, details: Any?) {
                            if (continuation.isActive) continuation.resume(unavailable)
                        }
                        override fun notImplemented() {
                            if (continuation.isActive) continuation.resume(unavailable)
                        }
                    })
                }
            }
        } ?: "{\"status\":\"cancelled\",\"reason\":\"timeout\"}"
    }

    private const val unavailable = "{\"status\":\"unavailable\",\"reason\":\"openApp\"}"
}
