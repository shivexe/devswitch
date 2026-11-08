package com.himphen.playground.developeroptionstoggle.remote

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import org.json.JSONObject

// Backup OTP source: the SMS broadcast carries the true DLT sender. Never logs the message.
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val parts = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        val sender = parts.firstOrNull()?.displayOriginatingAddress
        val otp = OtpExtractor.extract(parts.joinToString("") { it.displayMessageBody.orEmpty() }, sender) ?: return
        if (OtpDedupe.isNew(otp.code)) Outbox.add("otp", JSONObject().put("code", otp.code).put("source", otp.source), priority = true)
    }
}
