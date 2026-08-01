package com.lucasgenoud.skippy

import android.content.Context
import android.content.SharedPreferences
import es.antonborri.home_widget.HomeWidgetPlugin
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/**
 * The shared store the app publishes notes into and this widget reads.
 *
 * The keys and payload shape are a contract with `widget_payload.dart` (and
 * with the Swift side on iOS); changing one means changing all of them. Values
 * are JSON strings, written through the home_widget plugin's own
 * SharedPreferences file so app and widget agree on where the data lives.
 *
 * Deliberately tolerant throughout: this parses a document another language
 * wrote, and a widget that renders nothing is a worse failure than one that
 * renders a note with a field missing.
 */
object SkippyWidgetStore {
    const val KEY_NOTES = "skippy_widget_notes"
    const val KEY_INDEX = "skippy_widget_index"
    const val KEY_SESSION = "skippy_widget_session"
    const val KEY_OPS = "skippy_widget_ops"
    const val KEY_WANTED = "skippy_widget_wanted"

    /** Bounded so a note deleted long ago can't keep the app publishing forever. */
    private const val MAX_WANTED = 20

    fun prefs(context: Context): SharedPreferences = HomeWidgetPlugin.getData(context)

    /** Which note a given widget instance shows, written by the configuration screen. */
    fun noteIdKey(appWidgetId: Int) = "skippy_widget_${appWidgetId}_note"

    fun noteIdFor(context: Context, appWidgetId: Int): String? =
        readString(prefs(context), noteIdKey(appWidgetId))

    // ---------------------------------------------------------------- reading

    private fun readString(prefs: SharedPreferences, key: String): String? {
        val raw = prefs.getString(key, null) ?: return null
        return try {
            // Written by Dart as a JSON document, so a bare string arrives quoted.
            JSONArray("[$raw]").optString(0, "").takeIf { it.isNotEmpty() }
        } catch (e: Exception) {
            raw.takeIf { it.isNotEmpty() }
        }
    }

    private fun readObject(prefs: SharedPreferences, key: String): JSONObject? {
        val raw = prefs.getString(key, null) ?: return null
        return try {
            JSONObject(raw)
        } catch (e: Exception) {
            null
        }
    }

    private fun readArray(prefs: SharedPreferences, key: String): JSONArray =
        try {
            JSONArray(prefs.getString(key, null) ?: "[]")
        } catch (e: Exception) {
            JSONArray()
        }

    private fun notesMap(prefs: SharedPreferences): JSONObject? =
        readObject(prefs, KEY_NOTES)?.optJSONObject("notes")

    /**
     * The note a widget is configured to show, or null if the app has not
     * published it (yet, or ever).
     */
    fun note(context: Context, noteId: String): WidgetNote? {
        val prefs = prefs(context)
        val raw = notesMap(prefs)?.optJSONObject(noteId)
        if (raw == null) {
            // Tell the app we still need this one: it publishes a bounded set of
            // recent notes, and a widget can outlive a note's stay in that window.
            markWanted(prefs, noteId)
            return null
        }
        return WidgetNote.from(raw)
    }

    /** The picker list backing the configuration screen. */
    fun index(context: Context): List<NoteSummary> {
        val array = readArray(prefs(context), KEY_INDEX)
        val out = ArrayList<NoteSummary>(array.length())
        for (i in 0 until array.length()) {
            array.optJSONObject(i)?.let { NoteSummary.from(it)?.let(out::add) }
        }
        return out
    }

    private fun markWanted(prefs: SharedPreferences, noteId: String) {
        val current = readArray(prefs, KEY_WANTED)
        val ids = ArrayList<String>(current.length() + 1)
        for (i in 0 until current.length()) {
            current.optString(i).takeIf { it.isNotEmpty() }?.let(ids::add)
        }
        if (ids.contains(noteId)) return
        ids.add(noteId)
        while (ids.size > MAX_WANTED) ids.removeAt(0)
        prefs.edit().putString(KEY_WANTED, JSONArray(ids).toString()).apply()
    }

    // ---------------------------------------------------------- ticking an item

    /**
     * Flip one checklist item in the published document.
     *
     * Mutates the parsed JSON rather than rebuilding it from a typed model, so
     * fields this version of the widget does not know about survive the write.
     * Returns the note's full item list afterwards, which is what the server
     * patch has to send, or null when there was nothing to flip.
     */
    fun setItemDone(context: Context, noteId: String, itemId: String, done: Boolean): JSONArray? {
        val prefs = prefs(context)
        val doc = readObject(prefs, KEY_NOTES) ?: return null
        val notes = doc.optJSONObject("notes") ?: return null
        val note = notes.optJSONObject(noteId) ?: return null
        val items = note.optJSONArray("items") ?: return null

        var found = false
        var pending = 0
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            if (item.optString("id") == itemId) {
                item.put("done", done)
                found = true
            }
            if (!item.optBoolean("done", false)) pending++
        }
        if (!found) return null

        note.put("pendingCount", pending)
        prefs.edit().putString(KEY_NOTES, doc.toString()).apply()
        return items
    }

    // ------------------------------------------------------------- the outbound queue

    /**
     * Queue a tick so the app can replay it if this device cannot reach the
     * server. Every op names an absolute state, so replaying one twice is safe.
     * Returns the op's id, for [removeOp] once the server has taken it.
     */
    fun appendOp(context: Context, noteId: String, itemId: String, done: Boolean): String {
        val prefs = prefs(context)
        val ops = readArray(prefs, KEY_OPS)
        val opId = UUID.randomUUID().toString()
        val stamp =
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
        ops.put(
            JSONObject()
                .put("opId", opId)
                .put("noteId", noteId)
                .put("itemId", itemId)
                .put("done", done)
                .put("at", stamp.format(Date()))
        )
        prefs.edit().putString(KEY_OPS, ops.toString()).apply()
        return opId
    }

    fun removeOp(context: Context, opId: String) {
        val prefs = prefs(context)
        val ops = readArray(prefs, KEY_OPS)
        val kept = JSONArray()
        for (i in 0 until ops.length()) {
            val op = ops.optJSONObject(i) ?: continue
            if (op.optString("opId") != opId) kept.put(op)
        }
        prefs.edit().putString(KEY_OPS, kept.toString()).apply()
    }

    // ------------------------------------------------------------------ session

    /**
     * The server and credential to sync a tick with, mirrored by the app. Absent
     * when signed out, in which case a tick waits in the queue instead.
     */
    fun session(context: Context): Session? {
        val raw = readObject(prefs(context), KEY_SESSION) ?: return null
        val baseUrl = raw.optString("baseUrl")
        val token = raw.optString("token")
        if (baseUrl.isEmpty() || token.isEmpty()) return null
        return Session(baseUrl, token)
    }

    data class Session(val baseUrl: String, val token: String)
}

/** One checklist row on a widget. */
data class WidgetItem(val id: String, val text: String, val done: Boolean)

/** A note trimmed to what a widget can render. */
data class WidgetNote(
    val id: String,
    val title: String,
    val kind: String,
    val colorLight: String?,
    val colorDark: String?,
    val items: List<WidgetItem>,
    /** Totals for the whole note, not the published slice. */
    val itemCount: Int,
    val pendingCount: Int,
    val content: String,
) {
    val isChecklist: Boolean
        get() = kind == "checklist"

    companion object {
        fun from(json: JSONObject): WidgetNote? {
            val id = json.optString("id")
            if (id.isEmpty()) return null
            val rows = json.optJSONArray("items") ?: JSONArray()
            val items = ArrayList<WidgetItem>(rows.length())
            for (i in 0 until rows.length()) {
                val row = rows.optJSONObject(i) ?: continue
                val itemId = row.optString("id")
                if (itemId.isEmpty()) continue
                items.add(
                    WidgetItem(itemId, row.optString("text"), row.optBoolean("done", false))
                )
            }
            return WidgetNote(
                id = id,
                title = json.optString("title", "Untitled note"),
                kind = json.optString("kind", "text"),
                colorLight = json.optString("colorLight").takeIf { it.isNotEmpty() },
                colorDark = json.optString("colorDark").takeIf { it.isNotEmpty() },
                items = items,
                itemCount = json.optInt("itemCount", items.size),
                pendingCount = json.optInt("pendingCount", items.count { !it.done }),
                content = json.optString("content"),
            )
        }
    }
}

/** A row in the widget's note picker. */
data class NoteSummary(
    val id: String,
    val title: String,
    val kind: String,
    val itemCount: Int,
    val pendingCount: Int,
) {
    companion object {
        fun from(json: JSONObject): NoteSummary? {
            val id = json.optString("id")
            if (id.isEmpty()) return null
            return NoteSummary(
                id = id,
                title = json.optString("title", "Untitled note"),
                kind = json.optString("kind", "text"),
                itemCount = json.optInt("itemCount", 0),
                pendingCount = json.optInt("pendingCount", 0),
            )
        }
    }
}
