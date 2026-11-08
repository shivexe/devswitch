package com.himphen.playground.developeroptionstoggle.remote

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

class RemoteService : Service() {
    companion object {
        @Volatile var connectionState = "Not connected"
        /** Route to the paired Mac from the last successful v2 poll, for the file channel. Null before that or on a v1-only Mac. */
        @Volatile var session: Session? = null
        /** Status fields filled in by feature services; merged into every status. */
        val statusExtras: MutableMap<String, Any> = ConcurrentHashMap(mapOf("ringing" to false, "listenerConnected" to false, "sims" to JSONArray()))
        fun start(context: Context) = context.startForegroundService(Intent(context, RemoteService::class.java))
    }
    class Session(val origin: String, val deviceId: String, val key: ByteArray)
    @Volatile private var running = false
    private var worker: Thread? = null
    private var wirelessEnabled: Boolean? = null
    private lateinit var wireless: WirelessEndpoint
    private lateinit var pairingService: WirelessEndpoint
    private lateinit var connectionWakeLock: PowerManager.WakeLock
    private var lastWakeRenewal = 0L
    override fun onCreate() {
        super.onCreate()
        wireless = WirelessEndpoint(this)
        // Some routers drop this announcement before it reaches the Mac; the phone always sees its own.
        pairingService = WirelessEndpoint(this, "_adb-tls-pairing._tcp.")
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
        startForeground(71, notification, if (Build.VERSION.SDK_INT >= 34)
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING
            else ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        running = true
        worker = Thread({ loop() }, "DevSwitch connection").also { it.start() }
        return START_STICKY
    }
    private fun status(link: LocalLink.Link?): JSONObject {
        val wifi = Settings.Global.getInt(contentResolver, "adb_wifi_enabled", 0) == 1
        // NSD only needs a nudge when Wireless debugging flips; its callbacks keep the endpoints current.
        if (wifi != wirelessEnabled) { wireless.update(wifi); pairingService.update(wifi); wirelessEnabled = wifi }
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val connectivity = getSystemService(ConnectivityManager::class.java)
        val network = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
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
        .put("adbTrustPersistent", keepAdbTrust())
        .put("pairingName", if (wifi) pairingService.ownService else "")
        .put("pairingEndpoint", if (wifi) pairingService.endpoint else "")
        .put("battery", if (level >= 0 && scale > 0) level * 100 / scale else null)
        .put("charging", (battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0)
        .put("network", when {
            network?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true -> "wifi"
            network?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true -> "cellular"
            else -> "none"
        })
        .also { status -> statusExtras.forEach { (name, value) -> status.put(name, value) } }
    }
    internal fun restartWireless(enabled: Boolean) {
        wireless.update(enabled, force = true); pairingService.update(enabled, force = true)
    }
    // Android revokes ADB trust after 7 days without a connection by default. 0 disables
    // that expiry; reapply it because the user or the OEM can reset the setting.
    private fun keepAdbTrust(): Boolean = try {
        val key = "adb_allowed_connection_time"
        if (checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED &&
            Settings.Global.getLong(contentResolver, key, 604800000L) != 0L) Settings.Global.putLong(contentResolver, key, 0L)
        Settings.Global.getLong(contentResolver, key, 604800000L) == 0L
    } catch (_: Exception) { false }
    private fun loop() {
        try {
            val pairing = PairStore.load(this) ?: return
            val id = pairing.getString("deviceId")
            val key = Protocol.decode(pairing.getString("key"), 32)
            val url = pairing.getString("url")
            var desktopIPv6 = pairing.optString("desktopIPv6", "")
            var useIPv6 = true
            var ipv6RetryAt = 0L
            // An older Mac answers /v2/poll with 403; confirm with one v1 poll before staying on v1.
            var v1Only = false
            var tryV1 = false
            var sentStatus = ""
            var statusAt = 0L
            var needStatus = true
            val receipts = ArrayList<JSONObject>()
            val recent = LinkedHashSet<String>()
            fun run(command: JSONObject, ahead: Long) {
                val commandId = command.optString("id")
                if (commandId.isEmpty() || !recent.add(commandId)) return
                if (recent.size > 64) recent.remove(recent.first())
                val expiry = command.optLong("expiresAt")
                val now = System.currentTimeMillis() / 1000
                // The Mac accepts polls within 30s of clock skew; accept its commands across the same skew.
                receipts += if (expiry in (now - 30)..(now + ahead)) Commands.execute(this, command)
                    else JSONObject().put("id", commandId).put("ok", false).put("message", "Expired")
                if (receipts.size > 64) receipts.removeAt(0)
            }
            var lastPoll = android.os.SystemClock.elapsedRealtime()
            var lastUptime = android.os.SystemClock.uptimeMillis()
            var delay = 0L
            var pollAgain: Boolean
            while (running) {
                // Wait for the next poll, or until Outbox.kick(). Interrupting the wait still stops the loop; onDestroy relies on it.
                try { if (delay > 0) Outbox.wake.tryAcquire(delay, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { break }
                if (!running) break
                val started = android.os.SystemClock.elapsedRealtime()
                val uptime = android.os.SystemClock.uptimeMillis()
                // Keep the transport that last worked; retry a failed IPv6 path once a minute.
                if (!useIPv6 && started >= ipv6RetryAt) useIPv6 = true
                var triedIPv6 = false
                delay = 2000L
                pollAgain = false
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
                    val v1 = v1Only || tryV1
                    val requestId = Protocol.encode(Protocol.bytes(32))
                    val request = JSONObject().put("requestId", requestId).put("sentAt", System.currentTimeMillis() / 1000)
                    // v2 sends the full status only when it changed, every 30 s, or when the Mac asks for it.
                    val statusText = phoneStatus.toString()
                    val sendStatus = v1 || needStatus || statusText != sentStatus || started - statusAt >= 30000
                    if (sendStatus) request.put("status", phoneStatus)
                    val sent = receipts.take(if (v1) receipts.size else 16)
                    if (v1) receipts.lastOrNull()?.let { request.put("receipt", it) }
                    else {
                        if (sent.isNotEmpty()) request.put("receipts", JSONArray(sent))
                        val events = Outbox.batch()
                        if (events.isNotEmpty()) request.put("events", JSONArray(events))
                        Outbox.takeDropped().takeIf { it > 0 }?.let { request.put("eventsDropped", it) }
                    }
                    val version = if (v1) 1 else 2
                    val envelope = Protocol.seal(request, key, "devswitch/poll/v$version/$id").put("deviceId", id)
                    triedIPv6 = useIPv6 && ipv6Url != null
                    val target = if (triedIPv6) ipv6Url!! else url
                    val (code, response) = Protocol.post(target, "/v$version/poll", envelope)
                    // These answers came from the Mac, so they never count against the transport.
                    if (!v1 && (code == 403 || code == 404)) { tryV1 = true; delay = 0; continue }
                    if (code == 409 || code == 429) { delay = response.optLong("nextPollMs", 2000).coerceIn(150, 2000); continue }
                    if (v1 && code != 200) tryV1 = false
                    check(code == 200) { "Mac returned HTTP $code" }
                    val reply = Protocol.open(response, key, "devswitch/reply/v$version/$id")
                    check(reply.getString("requestId") == requestId) { "Response does not match" }
                    if (tryV1) { v1Only = true; tryV1 = false; session = null }
                    // Learn an alternate address only from the authenticated paired Mac.
                    val offered = reply.optString("desktopIPv6", "")
                    if (LocalLink.isLinkLocal(offered) && offered != desktopIPv6) {
                        desktopIPv6 = offered
                        pairing.put("desktopIPv6", offered)
                        PairStore.save(this, pairing)
                    }
                    if (!running) break
                    renewConnectionWakeLock()
                    connectionState = "Connected to ${pairing.getString("desktopName")}"
                    if (sendStatus) { sentStatus = statusText; statusAt = started }
                    receipts.removeAll(sent.toSet())
                    if (v1) reply.optJSONObject("command")?.let { run(it, 60) }
                    else {
                        session = Session(target, id, key)
                        val ack = reply.optJSONArray("ack") ?: JSONArray()
                        Outbox.ack((0 until ack.length()).map(ack::getString))
                        needStatus = reply.optBoolean("needStatus")
                        val icons = reply.optJSONArray("needIcons") ?: JSONArray()
                        NotifListener.sendIcons((0 until minOf(icons.length(), 32)).map(icons::getString))
                        // Commands TTLs reach 120 s; allow the same 30 s clock skew on top.
                        val commands = reply.optJSONArray("commands") ?: JSONArray()
                        for (i in 0 until minOf(commands.length(), 16)) run(commands.getJSONObject(i), 130)
                        val next = reply.optLong("nextPollMs", 2000)
                        delay = if (next == 0L) 0 else next.coerceIn(150, 2000)
                        pollAgain = true
                    }
                } catch (error: Exception) {
                    android.util.Log.w("DevSwitchConnection", "${if (triedIPv6) "IPv6" else "IPv4"}: ${error.javaClass.simpleName}: ${error.message?.take(160)}")
                    if (triedIPv6) { useIPv6 = false; ipv6RetryAt = android.os.SystemClock.elapsedRealtime() + 60000 }
                    else useIPv6 = true
                    if (running) connectionState = "Waiting for your Mac on the same Wi-Fi"
                    needStatus = true
                } finally {
                    // Drain kicks that arrived during this poll; anything still queued after a successful v2 poll goes out at once.
                    Outbox.wake.drainPermits()
                    if (pollAgain && !Outbox.isEmpty()) delay = 0
                }
            }
        } catch (_: Exception) { connectionState = "Pair your Mac again" }
        finally { running = false; releaseConnectionWakeLock(); stopSelf() }
    }
    override fun onDestroy() {
        running = false; session = null; worker?.interrupt(); wireless.close(); pairingService.close(); connectionState = "Mac control paused"
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
