package com.skippynotes.app

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import es.antonborri.home_widget.HomeWidgetLaunchIntent

/// Quick-settings tile that opens the app on a new note of the default kind.
///
/// It sends the same `skippy://new` link as the launcher shortcuts, through the
/// action the home_widget plugin hands to Dart, so a tap reaches the app on a
/// cold start and while it runs alike.
class NewNoteTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        // An action, not a toggle: the tile never shows itself switched on.
        val tile = qsTile ?: return
        tile.state = Tile.STATE_INACTIVE
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        // A note is written in the app, so a locked phone unlocks first.
        if (isLocked) {
            unlockAndRun { openNewNote() }
            return
        }
        openNewNote()
    }

    private fun openNewNote() {
        val intent = Intent(this, MainActivity::class.java).apply {
            action = HomeWidgetLaunchIntent.HOME_WIDGET_LAUNCH_ACTION
            data = Uri.parse(NEW_NOTE_LINK)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        // Android 14 takes only a PendingIntent here.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pending = PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            startActivityAndCollapse(pending)
            return
        }
        @Suppress("DEPRECATION")
        startActivityAndCollapse(intent)
    }

    private companion object {
        const val NEW_NOTE_LINK = "skippy://new?homeWidget=1"
    }
}
