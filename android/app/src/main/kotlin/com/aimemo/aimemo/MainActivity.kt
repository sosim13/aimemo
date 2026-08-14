package com.aimemo.aimemo

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
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
                "getPendingItems" -> {
                    @Suppress("UNCHECKED_CAST")
                    val pending = AimemoQueue.pending(applicationContext) as List<Map<String, String>>
                    result.success(pending)
                }
                "pendingCount" -> {
                    result.success(AimemoQueue.pendingCount(applicationContext))
                }
                "clearAll" -> {
                    AimemoQueue.clearAll(applicationContext)
                    result.success(null)
                }
                "removeById" -> {
                    val id = call.argument<String>("id")
                    if (id != null) AimemoQueue.removeById(applicationContext, id)
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
        if (Intent.ACTION_SEND != intent.action) return

        when {
            intent.type == "text/plain" -> {
                sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)
            }
            intent.type?.startsWith("image/") == true -> {
                val imageUri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (imageUri != null) {
                    val persisted = try {
                        contentResolver.takePersistableUriPermission(
                            imageUri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION,
                        )
                        true
                    } catch (_: SecurityException) {
                        false
                    }

                    val uriToUse = if (persisted) {
                        imageUri
                    } else {
                        copyImageToCache(imageUri)
                    }

                    if (uriToUse != null) {
                        AimemoQueue.enqueue(
                            applicationContext,
                            listOf(QueueItem(content = uriToUse.toString(), type = "image")),
                        )
                        AimemoBackgroundService.start(applicationContext)
                    }
                }
            }
        }
    }

    private fun copyImageToCache(uri: Uri): Uri? {
        return try {
            val inputStream = contentResolver.openInputStream(uri) ?: return null
            val cacheDir = java.io.File(cacheDir, "shared_images")
            cacheDir.mkdirs()
            val cacheFile = java.io.File(cacheDir, "img_${java.util.UUID.randomUUID()}.tmp")
            java.io.FileOutputStream(cacheFile).use { output ->
                inputStream.copyTo(output)
            }
            inputStream.close()
            Uri.fromFile(cacheFile)
        } catch (_: Exception) {
            null
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
