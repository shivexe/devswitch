package com.himphen.playground.developeroptionstoggle.remote

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.Patterns
import android.widget.Toast
import androidx.activity.ComponentActivity
import org.json.JSONObject

// Share sheet target: a link becomes a `link` event, other text a `clipboard` event, files go through FileTransfer.
class ShareToMacActivity : ComponentActivity() {
    private class Shared(val uri: Uri, val name: String, val size: Long, val mime: String)

    // Sends straight away; the share sheet tap is the confirmation.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = intent.getStringExtra(Intent.EXTRA_TEXT).orEmpty().take(16 * 1024)
        val link = Patterns.WEB_URL.matcher(text).let { m -> generateSequence { if (m.find()) m.group() else null }.firstOrNull { it.startsWith("http://") || it.startsWith("https://") } }
        val files = streams().mapNotNull(::describe)
        val macName = try { PairStore.load(this)?.getString("desktopName") } catch (_: Exception) { null } ?: "your Mac"
        val error = if (files.isEmpty() && text.isEmpty()) "Nothing to send." else send(text, link, files)
        Toast.makeText(this, error.ifEmpty { if (files.isNotEmpty()) "Sending to $macName" else "Sent to $macName" }, Toast.LENGTH_SHORT).show()
        finish()
    }

    // Returns an error message, or "" when everything was queued.
    private fun send(text: String, link: String?, files: List<Shared>): String {
        if (RemoteService.session == null) return "Your Mac is not connected. Open DevSwitch on both devices on the same Wi-Fi."
        if (files.isNotEmpty()) {
            // The read grant belongs to this activity; hand it to the running service so the upload can read after finish().
            val clip = ClipData.newRawUri("", files[0].uri).apply { files.drop(1).forEach { addItem(ClipData.Item(it.uri)) } }
            startService(Intent(this, RemoteService::class.java).also { it.clipData = clip }.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
            files.forEach { FileTransfer.upload(applicationContext, it.uri, it.name, it.size, it.mime) }
        } else {
            // Shared text always lands on the Mac clipboard; a link also gets an Open notification.
            ClipboardBridge.send(text, force = true)
            if (link != null) Outbox.add("link", JSONObject().put("url", link.take(2048)).put("title", intent.getStringExtra(Intent.EXTRA_SUBJECT).orEmpty().take(200)))
        }
        return ""
    }

    private fun streams(): List<Uri> = if (Build.VERSION.SDK_INT >= 33) {
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
        else listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java))
    } else @Suppress("DEPRECATION") {
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
        else listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM))
    }

    private fun describe(uri: Uri): Shared? = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst() || cursor.isNull(1)) null
            else Shared(uri, cursor.getString(0) ?: "File", cursor.getLong(1), contentResolver.getType(uri) ?: "application/octet-stream")
        }
    } catch (_: Exception) { null }
}
