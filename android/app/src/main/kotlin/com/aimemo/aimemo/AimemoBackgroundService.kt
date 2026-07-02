package com.aimemo.aimemo

import android.app.NotificationChannel
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.IBinder
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import java.io.File
import java.io.FileOutputStream
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.util.concurrent.atomic.AtomicBoolean

class AimemoBackgroundService : Service() {
    private var flutterEngine: FlutterEngine? = null
    private val running = AtomicBoolean(false)

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
        startForeground(PROCESSING_NOTIFICATION_ID, processingNotification())
        startFlutterWorker()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startFlutterWorker()
        return START_STICKY
    }

    override fun onDestroy() {
        flutterEngine?.destroy()
        flutterEngine = null
        running.set(false)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startFlutterWorker() {
        if (!running.compareAndSet(false, true)) return

        val engine = FlutterEngine(this)
        flutterEngine = engine
        setupChannel(engine)
        GeneratedPluginRegistrant.registerWith(engine)

        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(this)
        loader.ensureInitializationComplete(this, null)
        val entrypoint = DartExecutor.DartEntrypoint(
            loader.findAppBundlePath(),
            "backgroundMain",
        )
        engine.dartExecutor.executeDartEntrypoint(entrypoint)
    }

    private fun setupChannel(engine: FlutterEngine) {
        MethodChannel(
            engine.dartExecutor.binaryMessenger,
            BACKGROUND_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getPendingItems" -> result.success(AimemoQueue.pending(this))
                "markComplete" -> {
                    val id = call.argument<String>("id")
                    if (id != null) AimemoQueue.complete(this, id)
                    result.success(null)
                }
                "notifyComplete" -> {
                    val title = call.argument<String>("title") ?: "메모"
                    val success = call.argument<Boolean>("success") ?: true
                    val error = call.argument<String>("error")
                    showCompleteNotification(title, success, error)
                    result.success(null)
                }
                "stopServiceIfIdle" -> {
                    if (AimemoQueue.pendingCount(this) == 0) {
                        stopForeground(STOP_FOREGROUND_REMOVE)
                        stopSelf()
                    } else {
                        running.set(false)
                        startFlutterWorker()
                    }
                    result.success(null)
                }
                "performOcr" -> {
                    val imageUri = call.argument<String>("imageUri")
                    if (imageUri == null) {
                        result.error("INVALID_ARGUMENT", "imageUri is required", null)
                        return@setMethodCallHandler
                    }
                    performOcr(imageUri, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Run ML Kit OCR on the image at the given content URI.
    /// Also saves the image to app-internal storage for persistent display.
    /// Returns a map with:
    ///   - text: recognized text (empty string if none)
    ///   - hasText: whether any text was found
    ///   - localPath: path to the saved image file (or null if save failed)
    private fun performOcr(imageUri: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(imageUri)
            val inputStream = contentResolver.openInputStream(uri)
                ?: run {
                    result.error("IO_ERROR", "Cannot open image URI: $imageUri", null)
                    return
                }

            val bitmap = BitmapFactory.decodeStream(inputStream)
            inputStream.close()

            if (bitmap == null) {
                result.error("IO_ERROR", "Failed to decode bitmap from URI: $imageUri", null)
                return
            }

            // Save image to app-internal storage for persistent display
            val savedPath = try {
                val imagesDir = File(filesDir, "images")
                imagesDir.mkdirs()
                val imageFile = File(imagesDir, "memo_${System.currentTimeMillis()}.jpg")
                val out = FileOutputStream(imageFile)
                try {
                    bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, out)
                } finally {
                    out.close()
                }
                imageFile.absolutePath
            } catch (_: Exception) {
                null
            }

            val image = InputImage.fromBitmap(bitmap, 0)
            val recognizer = TextRecognition.getClient(KoreanTextRecognizerOptions.Builder().build())

            recognizer.process(image)
                .addOnSuccessListener { visionText ->
                    val recognizedText = visionText.text.trim()
                    val response = mutableMapOf<String, Any>(
                        "text" to recognizedText,
                        "hasText" to (recognizedText.isNotEmpty()),
                    )
                    if (savedPath != null) {
                        response["localPath"] = savedPath
                    }
                    result.success(response)
                    recognizer.close()
                }
                .addOnFailureListener { e ->
                    result.error("OCR_FAILED", "OCR processing failed: ${e.message}", null)
                    recognizer.close()
                }
        } catch (e: Exception) {
            result.error("OCR_ERROR", "OCR error: ${e.message}", null)
        }
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(NotificationManager::class.java)

        // Processing channel — IMPORTANCE_MIN: foreground service 필수 알림, 사용자 눈에 안 띔
        val processingChannel = NotificationChannel(
            PROCESSING_CHANNEL_ID,
            "Aimemo 처리",
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = "백그라운드 처리 상태 (사용자 표시 안 함)"
        }
        manager.createNotificationChannel(processingChannel)

        // Completion channel — IMPORTANCE_DEFAULT: 완료 시에만 푸시
        val completionChannel = NotificationChannel(
            COMPLETION_CHANNEL_ID,
            "Aimemo 완료",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "요약 완료 알림"
        }
        manager.createNotificationChannel(completionChannel)
    }

    private fun processingNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, PROCESSING_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            // 차단 없음. IMPORTANCE_MIN 채널 + setOngoing(true) 상태바 아이콘만 표시,
            // 소리/진동/팝업 없이 조용히 백그라운드 처리됨
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("")
            .setContentText("")
            .setOngoing(true)
            .setLocalOnly(true)
            .build()
    }

    private fun showCompleteNotification(title: String, success: Boolean, error: String?) {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, COMPLETION_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val notification = builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(if (success) "AI 메모 저장 완료" else "AI 메모 저장 실패")
            .setContentText(if (success) title else error ?: title)
            .setStyle(Notification.BigTextStyle().bigText(if (success) title else error ?: title))
            .setAutoCancel(true)
            .setContentIntent(openAppIntent())
            .build()

        val manager = getSystemService(NotificationManager::class.java)
        manager.notify((System.currentTimeMillis() % Int.MAX_VALUE).toInt(), notification)
    }

    private fun openAppIntent(): PendingIntent {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        return PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    companion object {
        private const val PROCESSING_CHANNEL_ID = "aimemo_processing"
        private const val COMPLETION_CHANNEL_ID = "aimemo_completion"
        private const val BACKGROUND_CHANNEL = "com.aimemo.aimemo/background_queue"
        private const val PROCESSING_NOTIFICATION_ID = 1001

        fun start(context: Context) {
            val intent = Intent(context, AimemoBackgroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}
