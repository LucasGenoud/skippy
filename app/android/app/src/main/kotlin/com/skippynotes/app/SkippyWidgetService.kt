package com.skippynotes.app

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.graphics.Paint
import android.widget.RemoteViews
import android.widget.RemoteViewsService

/**
 * Supplies the checklist rows for one widget instance.
 *
 * This is what makes the Android widget scrollable: a `ListView` fed by a
 * `RemoteViewsFactory`, so the whole checklist is present and can be scrolled
 * on the home screen, which WidgetKit cannot do on iOS.
 */
class SkippyWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        SkippyRemoteViewsFactory(applicationContext, intent)
}

private class SkippyRemoteViewsFactory(
    private val context: Context,
    intent: Intent,
) : RemoteViewsService.RemoteViewsFactory {

    private val appWidgetId =
        intent.getIntExtra(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID,
        )

    private var noteId: String? = null
    private var items: List<WidgetItem> = emptyList()

    override fun onCreate() {}

    /**
     * Called on every `notifyAppWidgetViewDataChanged`, including right after a
     * tick, so the list is always rebuilt from what is actually stored rather
     * than from anything this factory remembered.
     */
    override fun onDataSetChanged() {
        val id = SkippyWidgetStore.noteIdFor(context, appWidgetId)
        noteId = id
        val note = id?.let { SkippyWidgetStore.note(context, it) }
        items = if (note != null && note.isChecklist) note.items else emptyList()
    }

    override fun onDestroy() {
        items = emptyList()
    }

    override fun getCount(): Int = items.size

    override fun getViewAt(position: Int): RemoteViews {
        val row = RemoteViews(context.packageName, R.layout.skippy_widget_row)
        val item = items.getOrNull(position) ?: return row
        val note = noteId ?: return row

        row.setTextViewText(R.id.row_text, item.text)
        row.setImageViewResource(
            R.id.row_check,
            if (item.done) R.drawable.ic_widget_checked else R.drawable.ic_widget_unchecked,
        )
        // Completed items read as done at a glance, matching the app's checklist.
        row.setInt(
            R.id.row_text,
            "setPaintFlags",
            if (item.done) Paint.ANTI_ALIAS_FLAG or Paint.STRIKE_THRU_TEXT_FLAG
            else Paint.ANTI_ALIAS_FLAG,
        )
        row.setFloat(R.id.row_text, "setAlpha", if (item.done) 0.6f else 1f)

        // Collection children cannot carry their own PendingIntent; they fill in
        // the template the provider set on the list. Intentionally attach it to
        // the checkbox and label only: the rest of a row remains safe to touch
        // while scrolling or reaching for another item.
        val toggle = Intent().apply {
            putExtra(SkippyWidgetProvider.EXTRA_NOTE_ID, note)
            putExtra(SkippyWidgetProvider.EXTRA_ITEM_ID, item.id)
            putExtra(SkippyWidgetProvider.EXTRA_DONE, !item.done)
        }
        row.setOnClickFillInIntent(R.id.row_check, toggle)
        row.setOnClickFillInIntent(R.id.row_text, toggle)
        return row
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 1

    override fun getItemId(position: Int): Long =
        items.getOrNull(position)?.id?.hashCode()?.toLong() ?: position.toLong()

    override fun hasStableIds(): Boolean = true
}
