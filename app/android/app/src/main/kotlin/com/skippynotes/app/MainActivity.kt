package com.skippynotes.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != COPY_IMAGE) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val bytes = call.arguments as? ByteArray
                if (bytes == null) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                result.success(copyImage(bytes))
            }
    }

    /// Android's clipboard holds a content URI, not bytes: the picture is
    /// written to the cache and offered through this app's FileProvider.
    private fun copyImage(png: ByteArray): Boolean {
        val dir = File(cacheDir, "clipboard").apply { mkdirs() }
        val file = File(dir, "image.png").apply { writeBytes(png) }
        val uri = FileProvider.getUriForFile(this, "$packageName.clipboard", file)
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newUri(contentResolver, "Image", uri))
        return true
    }

    private companion object {
        const val CHANNEL = "skippy/clipboard"
        const val COPY_IMAGE = "copyImage"
    }
}
