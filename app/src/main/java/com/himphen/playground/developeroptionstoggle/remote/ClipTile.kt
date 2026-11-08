package com.himphen.playground.developeroptionstoggle.remote

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.TileService

// Quick Settings "Send clipboard to Mac": opens ClipboardBridge, which can read the clipboard because it has focus.
class ClipTile : TileService() {
    @SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        val intent = Intent(this, ClipboardBridge::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // Android 14 throws for the Intent overload.
        if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        else @Suppress("DEPRECATION") startActivityAndCollapse(intent)
    }
}
