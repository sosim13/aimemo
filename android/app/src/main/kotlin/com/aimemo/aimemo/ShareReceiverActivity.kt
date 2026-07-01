package com.aimemo.aimemo

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.view.LayoutInflater
import android.widget.Toast

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

        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            ?: intent.getStringExtra(Intent.EXTRA_SUBJECT)
            ?: return emptyList()

        return parseSharedText(text)
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
