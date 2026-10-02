package com.himphen.playground.developeroptionstoggle.remote

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import org.json.JSONObject

class RemoteService : Service() {
    companion object {
        @Volatile var connectionState = "Not connected"
        fun start(context: Context) = context.startForegroundService(Intent(context, RemoteService::class.java))
    }
    @Volatile private var running = false
    private var worker: Thread? = null
    private var receipt: JSONObject? = null
    private lateinit var wireless: WirelessEndpoint
    private lateinit var connectionWakeLock: PowerManager.WakeLock
    private var lastWakeRenewal = 0L
    override fun onCreate() {
        super.onCreate()
        wireless = WirelessEndpoint(this)
        connectionWakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "DevSwitch:MacConnection")
            .apply { setReferenceCounted(false) }
    }
    // A foreground service alone does not keep the polling thread running during CPU sleep.
    // Renew only after authenticated replies; an absent Mac cannot hold the CPU indefinitely.
    @Synchronized private fun renewConnectionWakeLock() {
        if (!running) return
        val now = SystemClock.elapsedRealtime()
        if (!connectionWakeLock.isHeld || now - lastWakeRenewal >= 30000) {
            connectionWakeLock.acquire(60000)
            lastWakeRenewal = now
        }
    }
    @Synchronized private fun releaseConnectionWakeLock() {
        if (connectionWakeLock.isHeld) connectionWakeLock.release()
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") {
            getSharedPreferences("devswitch", MODE_PRIVATE).edit().putBoolean("paused", true).apply()
            stopSelf(); return START_NOT_STICKY
        }
        if (running) return START_STICKY
        if (getSharedPreferences("devswitch", MODE_PRIVATE).getBoolean("paused", false)) { stopSelf(); return START_NOT_STICKY }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("connection", "Mac connection", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, PairingActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 1, Intent(this, RemoteService::class.java).setAction("STOP"), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(this, "connection").setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("DevSwitch Mac control").setContentText("Your paired Mac can switch developer settings.")
            .setContentIntent(open).setOngoing(true).addAction(Notification.Action.Builder(null, "Pause", stop).build()).build()
        startForeground(71, notification)
        running = true
        worker = Thread({ loop() }, "DevSwitch connection").also { it.start() }
        return START_STICKY
    }
    private fun status(link: LocalLink.Link?): JSONObject {
        val wifi = Settings.Global.getInt(contentResolver, "adb_wifi_enabled", 0) == 1
        wireless.update(wifi)
        val port = wireless.endpoint.substringAfterLast(':', "").toIntOrNull()
        return JSONObject()
        .put("developer", Settings.Global.getInt(contentResolver, "development_settings_enabled", 0) == 1)
        .put("usb", Settings.Global.getInt(contentResolver, "adb_enabled", 0) == 1)
        .put("wifi", Settings.Global.getInt(contentResolver, "adb_wifi_enabled", 0) == 1)
        .put("permission", checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED)
        .put("wifiEndpoint", if (wifi) wireless.endpoint else "")
        .put("lanIPv4", link?.ipv4 ?: "")
        .put("wifiIPv6Endpoint", if (wifi && link?.ipv6 != null && port != null &&
            wireless.endpoint.substringBefore(':') == link.ipv4) "[${link.ipv6}]:$port" else "")
    }
    private fun loop() {
        try {
            val pairing = PairStore.load(this) ?: return
            val id = pairing.getString("deviceId")
            val key = Protocol.decode(pairing.getString("key"), 32)
            val url = pairing.getString("url")
            var desktopIPv6 = pairing.optString("desktopIPv6", "")
            var useIPv6 = true
            var lastPoll = android.os.SystemClock.elapsedRealtime()
            var lastUptime = android.os.SystemClock.uptimeMillis()
            while (running) {
                val started = android.os.SystemClock.elapsedRealtime()
                val uptime = android.os.SystemClock.uptimeMillis()
                if (started - lastPoll > 10000) {
                    val power = getSystemService(android.os.PowerManager::class.java)
                    android.util.Log.w("DevSwitchConnection", "Heartbeat gap: elapsedMs=${started-lastPoll} awakeMs=${uptime-lastUptime} interactive=${power.isInteractive} idle=${power.isDeviceIdleMode}")
                }
                lastPoll = started; lastUptime = uptime
                try {
                    val link = LocalLink.current(this)
                    val phoneStatus = status(link)
                    val ipv6Url = LocalLink.origin(link, desktopIPv6, Protocol.origin(url).port)
                    val prepared = android.os.SystemClock.elapsedRealtime()
                    if (prepared - started > 1000) android.util.Log.w("DevSwitchConnection", "Slow status preparation: ${prepared-started}ms")
                    // Timestamp only after local status preparation, immediately before sending.
                    val requestId = Protocol.encode(Protocol.bytes(32))
                    val request = JSONObject().put("requestId", requestId).put("sentAt", System.currentTimeMillis() / 1000).put("status", phoneStatus)
                    receipt?.let { request.put("receipt", it) }
                    val envelope = Protocol.seal(request, key, "devswitch/poll/v1/$id").put("deviceId", id)
                    val target = if (useIPv6 && ipv6Url != null) ipv6Url else url
                    val (code, response) = Protocol.post(target, "/v1/poll", envelope)
                    check(code == 200) { "Mac returned HTTP $code" }
                    val reply = Protocol.open(response, key, "devswitch/reply/v1/$id")
                    check(reply.getString("requestId") == requestId) { "Response does not match" }
                    // Learn an alternate address only from the authenticated paired Mac.
                    val offered = reply.optString("desktopIPv6", "")
                    if (LocalLink.isLinkLocal(offered) && offered != desktopIPv6) {
                        desktopIPv6 = offered
                        pairing.put("desktopIPv6", offered)
                        PairStore.save(this, pairing)
                    }
                    useIPv6 = true
                    if (!running) break
                    renewConnectionWakeLock()
                    connectionState = "Connected to ${pairing.getString("desktopName")}"
                    val command = reply.optJSONObject("command")
                    if (command != null && command.getString("id") != receipt?.optString("id")) {
                        val expiry = command.getLong("expiresAt")
                        val now = System.currentTimeMillis() / 1000
                        if (expiry in now..(now + 30)) execute(command)
                    }
                } catch (error: Exception) {
                    android.util.Log.w("DevSwitchConnection", "${if (useIPv6 && desktopIPv6.isNotEmpty()) "IPv6" else "IPv4"}: ${error.javaClass.simpleName}: ${error.message?.take(160)}")
                    useIPv6 = !useIPv6
                    if (running) connectionState = "Waiting for your Mac on the same Wi-Fi"
                }
                try { Thread.sleep(2000) } catch (_: InterruptedException) { break }
            }
        } catch (_: Exception) { connectionState = "Pair your Mac again" }
        finally { running = false; releaseConnectionWakeLock(); stopSelf() }
    }
    private fun execute(command: JSONObject) {
        var success = false
        var message = ""
        try {
            check(checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED) { "Settings permission missing" }
            val action = command.getString("action")
            val changes = when (action) {
                "enable" -> listOf("development_settings_enabled" to 1, "adb_enabled" to 1, "adb_wifi_enabled" to 1)
                "disable" -> listOf("adb_wifi_enabled" to 0, "adb_enabled" to 0, "development_settings_enabled" to 0)
                else -> error("Unsupported command")
            }
            for ((setting, value) in changes) check(Settings.Global.putInt(contentResolver, setting, value)) { "Setting write rejected" }
            wireless.update(action == "enable", force = true)
            Thread.sleep(1200)
            success = changes.all { (setting, value) -> Settings.Global.getInt(contentResolver, setting, -1) == value }
            if (!success) message = if (action == "enable") "Open Wireless debugging on your phone and allow this Wi-Fi network, then retry." else "Android did not retain the requested settings."
        } catch (_: Exception) { message = "Android rejected a setting change. Check the settings permission." }
        receipt = JSONObject().put("id", command.getString("id")).put("ok", success).put("message", message)
    }
    override fun onDestroy() {
        running = false; worker?.interrupt(); wireless.close(); connectionState = "Mac control paused"
        releaseConnectionWakeLock()
        super.onDestroy()
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        try { if (PairStore.load(context) != null && !context.getSharedPreferences("devswitch", Context.MODE_PRIVATE).getBoolean("paused", false)) RemoteService.start(context) }
        catch (_: Exception) { RemoteService.connectionState = "Open DevSwitch to resume Mac control" }
    }
}
