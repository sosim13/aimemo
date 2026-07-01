package com.aimemo.aimemo

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val SHARE_CHANNEL = "com.aimemo.aimemo/share"
    private val BACKGROUND_CHANNEL = "com.aimemo.aimemo/background_queue"
    private var sharedText: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermission()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // --- Shared text channel ---
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

        val backgroundChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKGROUND_CHANNEL)
        backgroundChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "enqueueItems" -> {
                    val rawItems = call.arguments as? List<*>
                    val items = rawItems.orEmpty().mapNotNull { raw ->
                        val map = raw as? Map<*, *> ?: return@mapNotNull null
                        val content = map["content"] as? String ?: return@mapNotNull null
                        val type = map["type"] as? String ?: "text"
                        QueueItem(content = content, type = type)
                    }
                    AimemoQueue.enqueue(applicationContext, items)
                    AimemoBackgroundService.start(applicationContext)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Process intent that started the activity
        handleIntent(intent)
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

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            return
        }
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2001)
    }
}
