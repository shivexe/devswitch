package com.himphen.playground.developeroptionstoggle.remote

import android.app.Notification
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import androidx.core.app.NotificationCompat
import androidx.core.graphics.drawable.toBitmap
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap

// One listener for OTPs, notification mirroring, and Mac dismiss/reply (research Part A §1–§2). Never logs text.
class NotifListener : NotificationListenerService() {
    companion object {
        @Volatile private var instance: NotifListener? = null
        // Latest posted notification per mirrored key, so the Mac's dismiss/reply can find it by key.
        private val latest = ConcurrentHashMap<String, StatusBarNotification>()
        private val icons = ConcurrentHashMap<String, String>() // iconHash → package
        private val iconsSent = ConcurrentHashMap.newKeySet<String>()
        private val skippedCategories = setOf(Notification.CATEGORY_TRANSPORT, Notification.CATEGORY_PROGRESS,
            Notification.CATEGORY_SERVICE, Notification.CATEGORY_SYSTEM, Notification.CATEGORY_CALL)

        fun dismiss(key: String): Pair<String, Boolean> {
            val listener = instance ?: return "Notification access is off" to false
            if (latest[key] == null) return "Notification is gone" to false
            listener.cancelNotification(key)
            return "" to true
        }

        fun reply(context: Context, key: String, index: Int, text: String): Pair<String, Boolean> {
            val sbn = latest[key] ?: return "Notification is gone" to false
            val action = sbn.notification.actions?.getOrNull(index) ?: return "Action is gone" to false
            if (text.isEmpty()) { action.actionIntent.send(); return "" to true }
            val inputs = action.remoteInputs?.takeIf { it.isNotEmpty() } ?: return "This action takes no reply" to false
            val results = Bundle().apply { inputs.forEach { putCharSequence(it.resultKey, text.take(1000)) } }
            val intent = Intent().also { RemoteInput.addResultsToIntent(inputs, it, results) }
            action.actionIntent.send(context, 0, intent)
            return "" to true
        }

        /** The Mac's reply `needIcons`: queue each requested icon again on that app's next notification. */
        fun sendIcons(hashes: Collection<String>) = hashes.forEach { hash -> icons[hash]?.let(iconsSent::remove) }
    }

    private val handler = Handler(Looper.getMainLooper())
    private val pending = HashMap<String, StatusBarNotification>()
    private val lastSent = HashMap<String, Long>()
    private val sentByPackage = HashMap<String, ArrayDeque<Long>>()

    override fun onListenerConnected() {
        instance = this
        RemoteService.statusExtras["listenerConnected"] = true
        SmsSender.refreshSims(this)
        Outbox.kick()
    }

    override fun onListenerDisconnected() {
        instance = null
        RemoteService.statusExtras["listenerConnected"] = false
        Outbox.kick()
        requestRebind(ComponentName(this, NotifListener::class.java))
    }

    override fun onNotificationPosted(sbn: StatusBarNotification, rankingMap: RankingMap) {
        if (sbn.packageName == packageName) return
        val n = sbn.notification
        val (title, text) = content(n)
        // An OTP becomes an `otp` event only; mirroring it would put the digits into macOS's notification store.
        OtpExtractor.extract("$title $text", null)?.let { otp ->
            if (OtpDedupe.isNew(otp.code)) Outbox.add("otp", JSONObject().put("code", otp.code).put("source", label(sbn.packageName))
                .put("app", sbn.packageName), priority = true)
            return
        }
        if (n.flags and (Notification.FLAG_ONGOING_EVENT or Notification.FLAG_FOREGROUND_SERVICE) != 0 || !sbn.isClearable) return
        if (n.category in skippedCategories || MutedApps.isMuted(this, sbn.packageName)) return
        val ranking = Ranking()
        if (rankingMap.getRanking(sbn.key, ranking) && ranking.importance <= android.app.NotificationManager.IMPORTANCE_MIN) return
        // Children carry the content; a summary is mirrored only when it is alone (e.g. a collapsed Gmail bundle).
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0 &&
            activeNotifications.orEmpty().any { it.groupKey == sbn.groupKey && it.key != sbn.key }) return
        if (title.isEmpty() && text.isEmpty()) return
        schedule(sbn)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification, rankingMap: RankingMap, reason: Int) {
        pending.remove(sbn.key)
        if (latest.remove(sbn.key) != null) Outbox.add("notificationRemoved", JSONObject().put("key", sbn.key))
    }

    // Coalesce updates to one key within 1.5 s and allow 5 events per app per 10 s; the latest version wins.
    private fun schedule(sbn: StatusBarNotification) {
        val waiting = pending.put(sbn.key, sbn) != null
        if (waiting) return
        val now = SystemClock.elapsedRealtime()
        val recent = sentByPackage.getOrPut(sbn.packageName) { ArrayDeque() }.apply { while (isNotEmpty() && now - first() > 10_000) removeFirst() }
        val wait = maxOf((lastSent[sbn.key] ?: Long.MIN_VALUE / 2) + 1500 - now, if (recent.size >= 5) recent.first() + 10_000 - now else 0)
        if (wait <= 0) send(sbn.key) else handler.postDelayed({ send(sbn.key) }, wait)
    }

    private fun send(key: String) {
        val sbn = pending.remove(key) ?: return
        val now = SystemClock.elapsedRealtime()
        lastSent[key] = now
        sentByPackage.getOrPut(sbn.packageName) { ArrayDeque() }.addLast(now)
        val n = sbn.notification
        val (title, text) = content(n)
        val event = JSONObject().put("key", key).put("pkg", sbn.packageName).put("app", label(sbn.packageName))
            .put("title", title.take(120)).put("text", text.take(1024)).put("postedAt", sbn.postTime / 1000)
            .put("silent", n.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0 && latest.containsKey(key))
        val actions = JSONArray()
        n.actions.orEmpty().take(3).forEachIndexed { i, action ->
            actions.put(JSONObject().put("i", i).put("title", action.title?.toString().orEmpty().take(40))
                .put("input", !action.remoteInputs.isNullOrEmpty()))
        }
        if (actions.length() > 0) event.put("actions", actions)
        icon(sbn.packageName)?.let { (hash, png) ->
            event.put("iconHash", hash)
            if (iconsSent.add(sbn.packageName)) event.put("icon", png)
        }
        latest[key] = sbn
        Outbox.add("notification", event)
    }

    // Title and body; MessagingStyle gives the newest message (with its sender in group chats).
    private fun content(n: Notification): Pair<String, String> {
        val extras = n.extras
        // Another app's malformed extras (e.g. a CallStyle without its Person) must not crash the listener.
        val messaging = runCatching { NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n) }.getOrNull()
        val title = (messaging?.conversationTitle ?: extras.getCharSequence(Notification.EXTRA_TITLE))?.toString().orEmpty()
        val text = messaging?.messages?.lastOrNull()?.let { message ->
            if (messaging.isGroupConversation) "${message.person?.name ?: ""}: ${message.text ?: ""}" else message.text?.toString()
        } ?: (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString()
            ?: extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.joinToString("\n")
        return title to text.orEmpty()
    }

    private fun label(pkg: String): String = try {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) { pkg }

    // 48×48 PNG of the app icon (a few KB) and the first 16 hex chars of its SHA-256.
    private fun icon(pkg: String): Pair<String, String>? = try {
        val png = ByteArrayOutputStream().also { packageManager.getApplicationIcon(pkg).toBitmap(48, 48).compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        val hash = MessageDigest.getInstance("SHA-256").digest(png).joinToString("") { "%02x".format(it) }.take(16)
        icons[hash] = pkg
        hash to Base64.getEncoder().encodeToString(png)
    } catch (_: Exception) { null }
}
