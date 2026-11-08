package com.himphen.playground.developeroptionstoggle.remote

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.widget.Toast
import com.himphen.playground.developeroptionstoggle.R
import org.json.JSONObject
import java.security.MessageDigest

// Android 10+ lets only the focused app read the clipboard, so phone→Mac needs this transparent activity
// (opened by the Quick Settings tile); Mac→phone writes work from the background.
class ClipboardBridge : Activity() {
    companion object {
        @Volatile private var lastFromMac = ""

        fun set(context: Context, command: JSONObject): Pair<String, Boolean> {
            val text = command.optString("text")
            if (text.isEmpty() || text.length > 16 * 1024) return "Invalid clipboard" to false
            val clip = ClipData.newPlainText("From Mac", text)
            if (command.optBoolean("sensitive")) clip.description.extras = PersistableBundle().apply {
                putBoolean(if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE", true)
            }
            lastFromMac = hash(text)
            Handler(Looper.getMainLooper()).post { context.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip) }
            notifyArrived(context, if (command.optBoolean("sensitive")) null else text)
            return "" to true
        }

        // Tells the user the Mac's text is ready to paste; sensitive text gets no preview.
        private fun notifyArrived(context: Context, text: String?) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel("clipboard", "Clipboard from Mac", NotificationManager.IMPORTANCE_DEFAULT))
            val preview = text?.replace(Regex("\\s+"), " ")?.trim()?.let { if (it.length > 80) it.take(80) + "…" else it }
            manager.notify(NOTIFICATION_ID, Notification.Builder(context, "clipboard").setSmallIcon(R.drawable.ic_copy)
                .setContentTitle("Clipboard from your Mac").setContentText(preview ?: "Copied. Ready to paste.")
                .setTimeoutAfter(60_000).build())
        }
        private const val NOTIFICATION_ID = 0x0c11b

        /** Queues a `clipboard` event unless the text just came from the Mac. False when there was nothing to send. */
        fun send(text: String, force: Boolean = false): Boolean {
            if (text.isEmpty() || text.length > 16 * 1024) return false
            val hash = hash(text)
            if (!force && hash == lastFromMac) return false
            Outbox.add("clipboard", JSONObject().put("mime", "text/plain").put("text", text).put("hash", hash))
            return true
        }

        private fun hash(text: String) = MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus) return
        val text = getSystemService(ClipboardManager::class.java).primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.toString().orEmpty()
        Toast.makeText(this, when {
            RemoteService.session == null -> "Mac is not connected"
            send(text) -> "Clipboard sent to Mac"
            text.isEmpty() -> "Clipboard is empty"
            else -> "Nothing new to send"
        }, Toast.LENGTH_SHORT).show()
        finish()
    }
}
