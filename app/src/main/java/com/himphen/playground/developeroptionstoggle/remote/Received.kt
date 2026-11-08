package com.himphen.playground.developeroptionstoggle.remote

import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import org.json.JSONObject

// Mac→phone files land in Downloads/DevSwitch through MediaStore (no storage permission on API 29+).
object Received {
    class Item(val uri: Uri, val name: String, val size: Long, val addedSeconds: Long, val mime: String)

    /** The newest files from the Mac. The app sees only its own Downloads rows, so no storage permission is needed. */
    fun recent(context: Context, limit: Int = 5): List<Item> {
        val columns = arrayOf(MediaStore.Downloads._ID, MediaStore.Downloads.DISPLAY_NAME, MediaStore.Downloads.SIZE,
            MediaStore.Downloads.DATE_ADDED, MediaStore.Downloads.MIME_TYPE)
        val selection = "${MediaStore.Downloads.RELATIVE_PATH} = ? AND ${MediaStore.Downloads.OWNER_PACKAGE_NAME} = ?"
        val args = arrayOf(Environment.DIRECTORY_DOWNLOADS + "/DevSwitch/", context.packageName)
        return try {
            context.contentResolver.query(MediaStore.Downloads.EXTERNAL_CONTENT_URI, columns, selection, args,
                "${MediaStore.Downloads.DATE_ADDED} DESC")?.use { c ->
                generateSequence { if (c.moveToNext()) c else null }.take(limit).map {
                    Item(ContentUris.withAppendedId(MediaStore.Downloads.EXTERNAL_CONTENT_URI, it.getLong(0)), it.getString(1).orEmpty(),
                        it.getLong(2), it.getLong(3), it.getString(4) ?: "application/octet-stream")
                }.toList()
            }.orEmpty()
        } catch (_: Exception) { emptyList() }
    }

    /** Opens a received file in its default app, or a chooser when there is no default. */
    fun open(context: Context, uri: Uri, mime: String, name: String) {
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try { context.startActivity(view) } catch (_: ActivityNotFoundException) { context.startActivity(Intent.createChooser(view, name)) }
    }

    /** Shows Downloads/DevSwitch in the Files app, or Downloads when that folder view is unavailable. */
    fun showAll(context: Context) {
        val folder = Uri.parse("content://com.android.externalstorage.documents/document/primary%3ADownload%2FDevSwitch")
        try { context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(folder, DocumentsContract.Document.MIME_TYPE_DIR)) }
        catch (_: ActivityNotFoundException) { context.startActivity(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS)) }
    }
    /** Runs a `fileOffer` command: checks space, then downloads on its own thread. The receipt only says it started. */
    fun receive(context: Context, offer: JSONObject): Pair<String, Boolean> {
        val app = context.applicationContext
        val name = offer.optString("name").replace(Regex("[/\\\\\\p{Cntrl}]"), "_").trim().take(120).ifEmpty { "File from Mac" }
        val size = offer.optLong("size", -1)
        if (size < 0 || size > 2L shl 30) return "File too large" to false
        if (StatFs(Environment.getExternalStorageDirectory().path).availableBytes < size + 50L * 1024 * 1024) return "Not enough space on the phone" to false
        val mime = offer.optString("mime").ifEmpty { "application/octet-stream" }
        Thread({
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name); put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/DevSwitch")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = app.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return@Thread
            try {
                checkNotNull(resolver.openOutputStream(uri)).use { FileTransfer.download(app, offer, it) }
                resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
                notify(app, name, uri, mime)
            } catch (error: Exception) {
                resolver.delete(uri, null, null)
                Log.w("DevSwitchConnection", "Download: ${error.javaClass.simpleName}")
            }
        }, "DevSwitch download").start()
        return "Receiving" to true
    }

    private fun notify(context: Context, name: String, uri: Uri, mime: String) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("received", "Files from Mac", NotificationManager.IMPORTANCE_DEFAULT))
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        val open = PendingIntent.getActivity(context, uri.hashCode(), Intent.createChooser(view, name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE)
        manager.notify(uri.hashCode(), Notification.Builder(context, "received").setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Received $name from Mac").setContentText("Saved to Downloads/DevSwitch").setContentIntent(open).setAutoCancel(true).build())
    }
}
