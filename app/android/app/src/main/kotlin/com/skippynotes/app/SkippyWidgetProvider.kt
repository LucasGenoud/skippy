package com.skippynotes.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent

/**
 * The Skippy home-screen widget.
 *
 * Unlike iOS, Android widgets can scroll, so a checklist is a real
 * `ListView`-backed collection: the whole list is there and can be scrolled and
 * ticked in place. [SkippyWidgetService] supplies the rows.
 *
 * Everything rendered comes from what the app published into shared storage, so
 * the widget works offline and without the app running.
 */
class SkippyWidgetProvider : AppWidgetProvider() {

    companion object {
        const val ACTION_TOGGLE = "com.skippynotes.app.action.TOGGLE_ITEM"
        const val EXTRA_NOTE_ID = "noteId"
        const val EXTRA_ITEM_ID = "itemId"
        const val EXTRA_DONE = "done"

        /** Ask every Skippy widget to redraw. */
        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids =
                manager.getAppWidgetIds(ComponentName(context, SkippyWidgetProvider::class.java))
            if (ids.isEmpty()) return
            manager.notifyAppWidgetViewDataChanged(ids, R.id.widget_list)
            val intent =
                Intent(context, SkippyWidgetProvider::class.java).apply {
                    action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                }
            context.sendBroadcast(intent)
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, buildViews(context, id))
        }
        appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetIds, R.id.widget_list)
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        // Forget which note a removed widget was bound to, so its id can't leak
        // into a later widget that happens to reuse the same slot.
        val editor = SkippyWidgetStore.prefs(context).edit()
        for (id in appWidgetIds) editor.remove(SkippyWidgetStore.noteIdKey(id))
        editor.apply()
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action != ACTION_TOGGLE) return

        val noteId = intent.getStringExtra(EXTRA_NOTE_ID) ?: return
        val itemId = intent.getStringExtra(EXTRA_ITEM_ID) ?: return
        val done = intent.getBooleanExtra(EXTRA_DONE, false)

        // Same order as the iOS intent, and for the same reason: flip it locally
        // so the row responds instantly and correctly offline, queue it so it
        // cannot be lost, and only then try the network.
        val items = SkippyWidgetStore.setItemDone(context, noteId, itemId, done) ?: return
        val opId = SkippyWidgetStore.appendOp(context, noteId, itemId, done)
        refreshAll(context)
        SkippyWidgetSync.pushItems(context, noteId, items, opId)
    }

    private fun buildViews(context: Context, appWidgetId: Int): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.skippy_widget)
        val noteId = SkippyWidgetStore.noteIdFor(context, appWidgetId)
        val note = noteId?.let { SkippyWidgetStore.note(context, it) }

        if (note == null) {
            views.setTextViewText(
                R.id.widget_title,
                if (noteId == null) "Choose a note" else "Open Skippy to sync",
            )
        } else {
            views.setTextViewText(R.id.widget_title, note.title)
            applyColor(context, views, note)
        }

        // The list adapter. A unique data URI per widget id is required, or
        // Android reuses one factory for every instance and they all show the
        // same note.
        val serviceIntent =
            Intent(context, SkippyWidgetService::class.java).apply {
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
            }
        views.setRemoteAdapter(R.id.widget_list, serviceIntent)
        views.setEmptyView(R.id.widget_list, R.id.widget_empty)
        views.setTextViewText(
            R.id.widget_empty,
            when {
                noteId == null -> "Touch and hold to choose a note."
                note == null -> "Open Skippy to sync this note."
                note.isChecklist -> "No items"
                else -> note.content.ifEmpty { "Empty note" }
            },
        )

        // Tapping the header opens the note in the app. The `homeWidget` query
        // item is required: the plugin ignores any launch URL without it.
        val launchUri =
            noteId?.let { Uri.parse("skippy://note/$it?homeWidget=1") }
        views.setOnClickPendingIntent(
            R.id.widget_header,
            HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, launchUri),
        )

        // "Add item" opens the note with an empty row focused. A widget has no
        // editable view, so the text itself is typed in the app; `add=1` is
        // what tells it to put the caret on a new row. The differing query
        // string is also what keeps this distinct from the header's intent:
        // `PendingIntent`s are matched on their data URI, and two that compared
        // equal would collapse into one.
        val checklist = note?.isChecklist == true
        views.setViewVisibility(R.id.widget_add, if (checklist) View.VISIBLE else View.GONE)
        if (checklist && noteId != null) {
            views.setOnClickPendingIntent(
                R.id.widget_add,
                HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("skippy://note/$noteId?homeWidget=1&add=1"),
                ),
            )
        }

        // One template for the whole collection; each row fills in its own ids.
        // Mutable because that is exactly what a fill-in intent does to it.
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        flags =
            if (Build.VERSION.SDK_INT >= 31) flags or PendingIntent.FLAG_MUTABLE
            else flags
        val template =
            PendingIntent.getBroadcast(
                context,
                0,
                Intent(context, SkippyWidgetProvider::class.java).setAction(ACTION_TOGGLE),
                flags,
            )
        views.setPendingIntentTemplate(R.id.widget_list, template)
        return views
    }

    /** Paint the note's own colour behind the widget, matching the app's card. */
    private fun applyColor(context: Context, views: RemoteViews, note: WidgetNote) {
        val night =
            (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES
        val hex = (if (night) note.colorDark else note.colorLight) ?: return
        val color =
            try {
                Color.parseColor(hex)
            } catch (e: IllegalArgumentException) {
                return // Malformed colour: keep the default background.
            }
        if (Build.VERSION.SDK_INT >= 31) {
            // Tints the rounded background drawable, keeping its corners.
            views.setColorStateList(
                R.id.widget_root,
                "setBackgroundTintList",
                android.content.res.ColorStateList.valueOf(color),
            )
        } else {
            // No tint API this far back; a flat fill loses the rounded corners
            // but keeps the note recognizable, which matters more.
            views.setInt(R.id.widget_root, "setBackgroundColor", color)
        }
    }
}
