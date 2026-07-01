package com.aimemo.aimemo

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

object AimemoQueue {
    private const val PREFS = "aimemo_background_queue"
    private const val KEY_ITEMS = "items"

    fun enqueue(context: Context, items: List<QueueItem>): Int {
        if (items.isEmpty()) return pendingCount(context)

        synchronized(this) {
            val array = readArray(context)
            items.forEach { item ->
                array.put(
                    JSONObject()
                        .put("id", UUID.randomUUID().toString())
                        .put("content", item.content)
                        .put("type", item.type)
                )
            }
            writeArray(context, array)
            return array.length()
        }
    }

    fun pending(context: Context): List<Map<String, String>> {
        synchronized(this) {
            val array = readArray(context)
            return (0 until array.length()).mapNotNull { index ->
                val item = array.optJSONObject(index) ?: return@mapNotNull null
                mapOf(
                    "id" to item.optString("id"),
                    "content" to item.optString("content"),
                    "type" to item.optString("type", "text")
                )
            }
        }
    }

    fun complete(context: Context, id: String) {
        synchronized(this) {
            val array = readArray(context)
            val next = JSONArray()
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                if (item.optString("id") != id) {
                    next.put(item)
                }
            }
            writeArray(context, next)
        }
    }

    fun pendingCount(context: Context): Int = readArray(context).length()

    private fun readArray(context: Context): JSONArray {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_ITEMS, "[]")
        return JSONArray(raw)
    }

    private fun writeArray(context: Context, array: JSONArray) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_ITEMS, array.toString())
            .apply()
    }
}

data class QueueItem(
    val content: String,
    val type: String,
)
