package dev.nancunchild.elecon

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * ADR-012 §2.8 H 档：Android Keystore 对称 KEK wrap/unwrap DEK。
 * StrongBox → TEE fallback；KEK 永不出 Keystore。
 * 🔒 红线 #1 — 须人工 + 安全清单审。
 */
class HardwareKeystorePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var appContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "isHardwareAvailable" -> result.success(ensureKek() != null)
                "wrapDek" -> {
                    val dek = call.arguments as? ByteArray
                    if (dek == null || dek.size != 32) {
                        result.error("bad_args", "DEK must be 32 bytes", null)
                        return
                    }
                    result.success(wrapDek(dek))
                }
                "unwrapDek" -> {
                    val wrapped = call.arguments as? ByteArray
                    if (wrapped == null || wrapped.size < 12 + 16) {
                        result.error("bad_args", "wrapped DEK too short", null)
                        return
                    }
                    result.success(unwrapDek(wrapped))
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("keystore", e.message, null)
        }
    }

    private fun ensureKek(): SecretKey? {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        if (ks.containsAlias(KEK_ALIAS)) {
            val entry = ks.getEntry(KEK_ALIAS, null) as? KeyStore.SecretKeyEntry
            return entry?.secretKey
        }
        // StrongBox first, then TEE.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                return generateKek(strongBox = true)
            } catch (_: Exception) {
                // fall through
            }
        }
        return try {
            generateKek(strongBox = false)
        } catch (_: Exception) {
            null
        }
    }

    private fun generateKek(strongBox: Boolean): SecretKey {
        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val builder = KeyGenParameterSpec.Builder(
            KEK_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(false)
            .setRandomizedEncryptionRequired(true)
        if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setIsStrongBoxBacked(true)
        }
        kg.init(builder.build())
        return kg.generateKey()
    }

    /** 产出：12-byte IV ‖ ciphertext+tag（GCM）。 */
    private fun wrapDek(dek: ByteArray): ByteArray {
        val kek = ensureKek() ?: throw IllegalStateException("no hardware KEK")
        val cipher = Cipher.getInstance(AES_GCM)
        cipher.init(Cipher.ENCRYPT_MODE, kek)
        val iv = cipher.iv
        val ct = cipher.doFinal(dek)
        return iv + ct
    }

    private fun unwrapDek(wrapped: ByteArray): ByteArray {
        val kek = ensureKek() ?: throw IllegalStateException("no hardware KEK")
        val iv = wrapped.copyOfRange(0, 12)
        val ct = wrapped.copyOfRange(12, wrapped.size)
        val cipher = Cipher.getInstance(AES_GCM)
        cipher.init(Cipher.DECRYPT_MODE, kek, GCMParameterSpec(128, iv))
        return cipher.doFinal(ct)
    }

    companion object {
        const val CHANNEL = "elecon/keystore"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEK_ALIAS = "elecon_h_kek_v1"
        private const val AES_GCM = "AES/GCM/NoPadding"
    }
}
