package com.himphen.playground.developeroptionstoggle.remote

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.provider.ContactsContract
import android.telecom.TelecomManager
import android.telephony.TelephonyManager
import org.json.JSONObject
import java.util.UUID

// PHONE_STATE fires twice per change (with and without the number); one `call` event per state,
// plus one update when the number arrives late.
class CallWatcher : BroadcastReceiver() {
    companion object {
        private var state = TelephonyManager.EXTRA_STATE_IDLE
        private var callId = ""
        private var number = ""
        private var silenced = false

        fun decline(context: Context, id: String): Pair<String, Boolean> {
            if (!current(id)) return "Call ended" to false
            if (context.checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS) != PackageManager.PERMISSION_GRANTED)
                return "Allow Phone access in DevSwitch" to false
            @Suppress("DEPRECATION")
            return if (context.getSystemService(TelecomManager::class.java).endCall()) "" to true else "Android refused to end the call" to false
        }

        // Best effort: TelecomManager.silenceRinger needs the dialer role, so mute the ring stream until idle.
        fun silence(context: Context, id: String): Pair<String, Boolean> {
            if (!current(id)) return "Call ended" to false
            context.getSystemService(AudioManager::class.java).adjustStreamVolume(AudioManager.STREAM_RING, AudioManager.ADJUST_MUTE, 0)
            synchronized(this) { silenced = true }
            return "" to true
        }

        @Synchronized private fun current(id: String) = state == TelephonyManager.EXTRA_STATE_RINGING && (id.isEmpty() || id == callId)
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return
        val newState = intent.getStringExtra(TelephonyManager.EXTRA_STATE) ?: return
        @Suppress("DEPRECATION")
        val newNumber = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER).orEmpty()
        val event = synchronized(CallWatcher) {
            val lateNumber = newState == state && number.isEmpty() && newNumber.isNotEmpty()
            if (newState == state && !lateNumber) return
            if (newState == TelephonyManager.EXTRA_STATE_RINGING && !lateNumber) { callId = UUID.randomUUID().toString(); number = "" }
            if (newNumber.isNotEmpty() && newState != TelephonyManager.EXTRA_STATE_IDLE) number = newNumber
            if (newState == TelephonyManager.EXTRA_STATE_IDLE && silenced) {
                context.getSystemService(AudioManager::class.java).adjustStreamVolume(AudioManager.STREAM_RING, AudioManager.ADJUST_UNMUTE, 0)
                silenced = false
            }
            state = newState
            if (callId.isEmpty()) return // offhook/idle for an outgoing call we never saw ring
            JSONObject().put("callId", callId).put("number", number)
                .put("state", when (newState) { TelephonyManager.EXTRA_STATE_RINGING -> "ringing"; TelephonyManager.EXTRA_STATE_OFFHOOK -> "offhook"; else -> "idle" })
                .also { if (newState == TelephonyManager.EXTRA_STATE_IDLE) callId = "" }
        }
        RemoteService.statusExtras["ringing"] = newState == TelephonyManager.EXTRA_STATE_RINGING
        val name = contactName(context, event.getString("number"))
        if (name.isNotEmpty()) event.put("name", name)
        Outbox.add("call", event, priority = true)
    }

    private fun contactName(context: Context, number: String): String {
        if (number.isEmpty() || context.checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) return ""
        return try {
            context.contentResolver.query(Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number)),
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0).orEmpty() else "" }.orEmpty()
        } catch (_: Exception) { "" }
    }
}
