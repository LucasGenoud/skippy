package com.skippynotes.app

import android.content.Context
import android.util.Log
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONArray
import org.json.JSONObject

/**
 * Pushes a tick made on the widget straight to the server.
 *
 * Deliberately the only network call the widget makes: everything it renders
 * comes from what the app already published.
 *
 * Failure is not an error here. The tick is already queued in shared storage
 * and the app drains that queue on its next launch, so an offline phone or a
 * sleeping server costs nothing but a delay. That fallback is also why this
 * uses a plain thread rather than WorkManager: there is already a durable
 * retry, and a widget tick does not warrant a scheduled job.
 */
object SkippyWidgetSync {
    private const val TAG = "SkippyWidget"
    private const val TIMEOUT_MS = 10_000

    /**
     * Send the note's full item list, off the main thread. Matches what the
     * app's own edit path sends, so the server sees an ordinary content patch.
     */
    fun pushItems(context: Context, noteId: String, items: JSONArray, opId: String) {
        val app = context.applicationContext
        Thread {
                if (push(app, noteId, items)) {
                    SkippyWidgetStore.removeOp(app, opId)
                }
            }
            .start()
    }

    private fun push(context: Context, noteId: String, items: JSONArray): Boolean {
        val session = SkippyWidgetStore.session(context) ?: return false
        val base = session.baseUrl.trimEnd('/')
        var connection: HttpURLConnection? = null
        return try {
            connection = (URL("$base/api/notes/$noteId").openConnection() as HttpURLConnection)
            // PATCH is rejected by the Oracle JDK's HttpURLConnection but is in
            // Android's permitted set (its implementation is OkHttp-backed), so
            // this is safe here and would not be in a desktop JVM. If a future
            // Android ever tightened that, the throw lands in the catch below
            // and the queued op still reaches the server when the app opens.
            connection.requestMethod = "PATCH"
            connection.connectTimeout = TIMEOUT_MS
            connection.readTimeout = TIMEOUT_MS
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Authorization", "Bearer ${session.token}")

            val body = JSONObject().put("items", items).toString()
            OutputStreamWriter(connection.outputStream, Charsets.UTF_8).use { it.write(body) }

            val code = connection.responseCode
            if (code !in 200..299) {
                Log.w(TAG, "note patch rejected: HTTP $code")
                return false
            }
            true
        } catch (e: Exception) {
            // Offline, DNS, a sleeping self-hosted server: the queued op covers it.
            Log.w(TAG, "note patch failed: ${e.message}")
            false
        } finally {
            connection?.disconnect()
        }
    }
}
