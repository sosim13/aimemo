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

    /// 큐에 쌓인 모든 pending 아이템을 삭제한다.
    /// 사용자 취소 / 처리 기록 삭제 시 호출되어 멈춰있는 아이템이
    /// UI에 계속 표시되는 문제를 해결한다.
    fun clearAll(context: Context) {
        synchronized(this) {
            writeArray(context, JSONArray())
        }
    }

    /// 지정한 id의 아이템을 큐에서 제거한다.
    /// backgroundMain이 처리 중 hang되어 markComplete가 호출되지 못한
    /// 아이템을 다음 시작 시 강제로 제거할 때 사용한다.
    fun removeById(context: Context, id: String) {
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
