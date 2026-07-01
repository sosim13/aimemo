package com.aimemo.aimemo

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.LayoutInflater
import android.widget.Toast
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class ShareReceiverActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
        finish()
        overridePendingTransition(0, 0)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
        finish()
        overridePendingTransition(0, 0)
    }

    private fun handleIntent(intent: Intent?) {
        val items = extractItems(intent)
        if (items.isEmpty()) return

        AimemoQueue.enqueue(applicationContext, items)
        showProcessingToast()
        AimemoBackgroundService.start(applicationContext)
    }

    private fun showProcessingToast() {
        val inflater = LayoutInflater.from(this)
        val layout = inflater.inflate(R.layout.custom_toast, null)
        val toast = Toast(this)
        toast.setGravity(Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL, 0, 80)
        toast.duration = Toast.LENGTH_SHORT
        toast.view = layout
        toast.show()
    }

    private fun extractItems(intent: Intent?): List<QueueItem> {
        if (intent == null || intent.action != Intent.ACTION_SEND) return emptyList()

        // Handle image shares
        if (intent.type?.startsWith("image/") == true) {
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

                // Some providers don't support persistable permission (e.g. Google Photos).
                // In that case, copy to internal cache so the background service can read it.
                val uriToUse = if (persisted) {
                    imageUri
                } else {
                    copyToCache(imageUri)
                }

                if (uriToUse != null) {
                    return listOf(QueueItem(content = uriToUse.toString(), type = "image"))
                }
            }
            return emptyList()
        }

        // Handle text shares
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            ?: intent.getStringExtra(Intent.EXTRA_SUBJECT)
            ?: return emptyList()

        return parseSharedText(text)
    }

    /// Copy image URI content to internal cache and return the cached file URI.
    /// Returns null if copy fails.
    private fun copyToCache(uri: Uri): Uri? {
        return try {
            val inputStream = contentResolver.openInputStream(uri) ?: return null
            val cacheDir = File(cacheDir, "shared_images")
            cacheDir.mkdirs()
            val cacheFile = File(cacheDir, "img_${UUID.randomUUID()}.tmp")
            FileOutputStream(cacheFile).use { output ->
                inputStream.copyTo(output)
            }
            inputStream.close()
            Uri.fromFile(cacheFile)
        } catch (_: Exception) {
            null
        }
    }

    private fun parseSharedText(text: String): List<QueueItem> {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return emptyList()

        val urls = Regex("""https?://[^\s<>"']+""", RegexOption.IGNORE_CASE)
            .findAll(trimmed)
            .map { trimUrlPunctuation(it.value) }
            .filter { it.isNotBlank() }
            .distinct()
            .toList()

        if (urls.isNotEmpty()) {
            return urls.map { QueueItem(content = it, type = "url") }
        }

        return listOf(QueueItem(content = trimmed, type = "text"))
    }

    private fun trimUrlPunctuation(url: String): String {
        var value = url
        while (value.isNotEmpty() && ".,);]}>".contains(value.last())) {
            value = value.dropLast(1)
        }
        return value
    }
}
