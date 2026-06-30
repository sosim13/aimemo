package com.aimemo.aimemo

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val SHARE_CHANNEL = "com.aimemo.aimemo/share"
    private val LITERT_CHANNEL = "com.aimemo.aimemo/litert"
    private var sharedText: String? = null
    private var litertEngine: LiteRtEngine? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // --- Shared text channel (existing) ---
        val shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
        shareChannel.setMethodCallHandler { call, result ->
            if (call.method == "getSharedText") {
                val text = sharedText
                sharedText = null
                result.success(text)
            } else {
                result.notImplemented()
            }
        }

        // --- LiteRT-LM channel (on-device LLM) ---
        val litertChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LITERT_CHANNEL)
        litertChannel.setMethodCallHandler { call, result ->
            handleLiteRtCall(call, result)
        }

        // Initialize LiteRT engine
        if (litertEngine == null) {
            litertEngine = LiteRtEngine(this)
        }

        // Process intent that started the activity
        handleIntent(intent)
    }

    private fun handleLiteRtCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> {
                result.success(litertEngine?.isAvailable() ?: false)
            }
            "initEngine" -> {
                val modelPath = call.argument<String>("modelPath")
                if (modelPath != null) {
                    Thread {
                        try {
                            val success = litertEngine?.initEngine(modelPath) ?: false
                            result.success(success)
                        } catch (e: Throwable) {
                            android.util.Log.e("LiteRtChannel", "initEngine error: ${e.message} (${e.javaClass.simpleName})")
                            result.success(false)
                        }
                    }.start()
                } else {
                    result.success(false)
                }
            }
            "generate" -> {
                val prompt = call.argument<String>("prompt") ?: ""
                val maxTokens = call.argument<Int>("maxTokens") ?: 1500
                val temperature = call.argument<Double>("temperature") ?: 0.2
                Thread {
                    try {
                        val response = litertEngine?.generate(prompt, maxTokens, temperature)
                        result.success(response)
                    } catch (e: Throwable) {
                        android.util.Log.e("LiteRtChannel", "generate error: ${e.message} (${e.javaClass.simpleName})")
                        result.success(null)
                    }
                }.start()
            }
            "close" -> {
                Thread {
                    try {
                        litertEngine?.close()
                        litertEngine = null
                    } catch (e: Throwable) {
                        android.util.Log.e("LiteRtChannel", "close error: ${e.message}")
                    }
                }.start()
                result.success(null)
            }
            "getDiagLog" -> {
                try {
                    val f = java.io.File(applicationContext.filesDir, "litert_diag.txt")
                    if (f.exists()) {
                        result.success(f.readText())
                    } else {
                        result.success(null)
                    }
                } catch (e: Exception) {
                    result.success(null)
                }
            }
            "clearDiagLog" -> {
                try {
                    val f = java.io.File(applicationContext.filesDir, "litert_diag.txt")
                    if (f.exists()) f.delete()
                    result.success(null)
                } catch (e: Exception) {
                    result.success(null)
                }
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent) {
        if (Intent.ACTION_SEND == intent.action && intent.type == "text/plain") {
            sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)
        }
    }

    override fun onDestroy() {
        litertEngine?.close()
        litertEngine = null
        super.onDestroy()
    }
}
