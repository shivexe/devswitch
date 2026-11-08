package com.himphen.playground.developeroptionstoggle.remote

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicInteger

// `sendSms{to, body, subId?}` from the Mac (research §4). Results come back as `smsStatus` events. Never retries,
// never logs the body.
object SmsSender {
    private val requestCodes = AtomicInteger(1000)
    private val recent = ArrayDeque<Long>()

    fun send(context: Context, command: JSONObject): Pair<String, Boolean> {
        if (context.checkSelfPermission(Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) return "Allow SMS in DevSwitch" to false
        val to = command.optString("to").trim()
        val body = command.optString("body")
        if (to.isEmpty() || to.length > 40 || body.isEmpty() || body.length > 1600) return "Invalid message" to false
        synchronized(recent) {
            val now = System.currentTimeMillis()
            while (recent.isNotEmpty() && now - recent.first() > 60_000) recent.removeFirst()
            if (recent.size >= 10) return "Too many messages; wait a minute" to false
            recent.addLast(now)
        }
        val subId = command.optInt("subId", -1)
        // SmsManager is a system service only from API 31; 29–30 use the deprecated factories.
        val manager = if (Build.VERSION.SDK_INT >= 31) context.getSystemService(SmsManager::class.java).let { if (subId < 0) it else it.createForSubscriptionId(subId) }
            else @Suppress("DEPRECATION") if (subId < 0) SmsManager.getDefault() else SmsManager.getSmsManagerForSubscriptionId(subId)
        val parts = manager.divideMessage(body)
        fun intents(kind: String) = ArrayList(parts.indices.map { part ->
            val intent = Intent(context, SmsStatusReceiver::class.java).setAction(kind)
                .putExtra("commandId", command.getString("id")).putExtra("part", part)
            PendingIntent.getBroadcast(context, requestCodes.incrementAndGet(), intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT)
        })
        return try {
            manager.sendMultipartTextMessage(to, null, parts, intents("sent"), intents("delivered"))
            "Sending ${parts.size} part${if (parts.size == 1) "" else "s"}" to true
        } catch (_: Exception) { "Android refused to send the message" to false }
    }

    /** Active SIMs into the status as [{subId, name}] so the Mac can offer a SIM picker. */
    fun refreshSims(context: Context) {
        if (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) return
        val sims = JSONArray()
        try {
            context.getSystemService(SubscriptionManager::class.java).activeSubscriptionInfoList.orEmpty().forEach {
                sims.put(JSONObject().put("subId", it.subscriptionId).put("name", "${it.displayName ?: "SIM ${it.simSlotIndex + 1}"}".take(80)))
            }
        } catch (_: SecurityException) { return }
        RemoteService.statusExtras["sims"] = sims
    }
}

class SmsStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val commandId = intent.getStringExtra("commandId") ?: return
        val result = when {
            intent.action == "delivered" -> "delivered"
            resultCode == Activity.RESULT_OK -> "sent"
            else -> "failed"
        }
        val event = JSONObject().put("commandId", commandId).put("part", intent.getIntExtra("part", 0)).put("result", result)
        if (result == "failed") event.put("error", resultCode)
        Outbox.add("smsStatus", event)
    }
}
