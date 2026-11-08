package com.himphen.playground.developeroptionstoggle.remote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper

// Rings at full alarm volume, through silent mode, and through DND on Android 14 with DND access (research §3).
object FindMyPhone {
    private const val NOTIFICATION_ID = 72
    private val handler = Handler(Looper.getMainLooper())
    private var player: Ringtone? = null
    private var savedVolume = -1
    private var savedFilter = NotificationManager.INTERRUPTION_FILTER_UNKNOWN

    @Synchronized fun ring(context: Context): Pair<String, Boolean> {
        if (player != null) return "" to true
        val app = context.applicationContext
        val audio = app.getSystemService(AudioManager::class.java)
        val notifications = app.getSystemService(NotificationManager::class.java)
        // Android 15+ apps targeting 35+ can no longer change global DND; there alarms ring if DND allows alarms.
        if (Build.VERSION.SDK_INT < 35 && notifications.isNotificationPolicyAccessGranted) {
            savedFilter = notifications.currentInterruptionFilter
            notifications.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_ALL)
        }
        savedVolume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
        audio.setStreamVolume(AudioManager.STREAM_ALARM, audio.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
        // Default URIs are served from the system's cached copy; the actual file is often a custom
        // MediaStore track this app cannot read ("no access to content://media/..."). Ringtone also
        // falls back to the system's player when this process can't create one.
        player = listOf(RingtoneManager.TYPE_ALARM, RingtoneManager.TYPE_RINGTONE, RingtoneManager.TYPE_NOTIFICATION).firstNotNullOfOrNull { type ->
            RingtoneManager.getRingtone(app, RingtoneManager.getDefaultUri(type))?.apply {
                audioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
                isLooping = true; play()
            }?.takeIf { it.isPlaying }
        }
        if (player?.isPlaying != true) { player?.stop(); player = null; restore(app); return "No ringtone to play" to false }
        notifications.createNotificationChannel(NotificationChannel("ring", "Find my phone", NotificationManager.IMPORTANCE_HIGH)
            .apply { setSound(null, null) })
        val stop = PendingIntent.getBroadcast(app, 0, Intent(app, StopRingReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        notifications.notify(NOTIFICATION_ID, Notification.Builder(app, "ring").setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("Your Mac is ringing this phone").setCategory(Notification.CATEGORY_ALARM).setOngoing(true)
            .setContentIntent(stop).addAction(Notification.Action.Builder(null, "Stop", stop).build()).build())
        handler.postDelayed({ stop(app) }, 60_000)
        return "" to true
    }

    @Synchronized fun stop(context: Context): Pair<String, Boolean> {
        val app = context.applicationContext
        handler.removeCallbacksAndMessages(null)
        player?.stop()
        player = null
        restore(app)
        app.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
        return "" to true
    }

    private fun restore(app: Context) {
        if (savedVolume >= 0) app.getSystemService(AudioManager::class.java).setStreamVolume(AudioManager.STREAM_ALARM, savedVolume, 0)
        savedVolume = -1
        if (savedFilter != NotificationManager.INTERRUPTION_FILTER_UNKNOWN) {
            app.getSystemService(NotificationManager::class.java).setInterruptionFilter(savedFilter)
            savedFilter = NotificationManager.INTERRUPTION_FILTER_UNKNOWN
        }
    }
}

class StopRingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) { FindMyPhone.stop(context) }
}
