package com.himphen.playground.developeroptionstoggle.remote

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject

// Runs one Mac→phone command on the poll thread and returns its receipt {id, ok, message}.
// Long actions must hand off to their own thread and return at once.
object Commands {
    fun execute(context: Context, command: JSONObject): JSONObject {
        val id = command.getString("id")
        // v1 replies name the action "action"; v2 uses "a". A failing feature must never stop the poll loop.
        val result = try { when (val action = command.optString("a").ifEmpty { command.optString("action") }) {
            "enable", "disable" -> developerSettings(context, action)
            "fileAccept", "fileDecline" ->
                if (FileTransfer.answer(command.optString("transferId"), action == "fileAccept")) "" to true else "Unknown transfer" to false
            "fileOffer" -> Received.receive(context, command)
            "ring" -> FindMyPhone.ring(context)
            "stopRing" -> FindMyPhone.stop(context)
            "sendSms" -> SmsSender.send(context, command)
            "dismiss" -> NotifListener.dismiss(command.optString("key"))
            "reply" -> NotifListener.reply(context, command.optString("key"), command.optInt("action", -1), command.optString("text"))
            "declineCall" -> CallWatcher.decline(context, command.optString("callId"))
            "silenceCall" -> CallWatcher.silence(context, command.optString("callId"))
            "setClipboard" -> ClipboardBridge.set(context, command)
            "setMuted" -> {
                val pkgs = command.optJSONArray("pkgs") ?: JSONArray()
                MutedApps.setFromMac(context, (0 until pkgs.length()).map(pkgs::getString)); "" to true
            }
            else -> "Unsupported" to false
        } } catch (_: Exception) { "Android rejected the command" to false }
        return JSONObject().put("id", id).put("ok", result.second).put("message", result.first)
    }

    private fun developerSettings(context: Context, action: String): Pair<String, Boolean> = try {
        check(context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED) { "Settings permission missing" }
        val resolver = context.contentResolver
        val changes = when (action) {
            "enable" -> listOf("development_settings_enabled" to 1, "adb_enabled" to 1, "adb_wifi_enabled" to 1)
            else -> listOf("adb_wifi_enabled" to 0, "adb_enabled" to 0, "development_settings_enabled" to 0)
        }
        for ((setting, value) in changes) check(Settings.Global.putInt(resolver, setting, value)) { "Setting write rejected" }
        (context as? RemoteService)?.restartWireless(action == "enable")
        Thread.sleep(1200)
        val success = changes.all { (setting, value) -> Settings.Global.getInt(resolver, setting, -1) == value }
        (if (success) "" else if (action == "enable") "Open Wireless debugging on your phone and allow this Wi-Fi network, then retry."
            else "Android did not retain the requested settings.") to success
    } catch (_: Exception) { "Android rejected a setting change. Check the settings permission." to false }
}
