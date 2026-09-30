package com.himphen.playground.developeroptionstoggle.remote

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.os.Build
import androidx.annotation.RequiresApi
import java.net.Inet4Address
import java.net.NetworkInterface

// Android discovers its own ADB service, then reports the endpoint over the paired encrypted channel.
// An advertisement is accepted only when its address belongs to this phone.
@Suppress("DEPRECATION")
class WirelessEndpoint(context: Context) {
    private val manager = context.getSystemService(NsdManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var listener: NsdManager.DiscoveryListener? = null
    private var generation = 0
    private var enabled = false
    private var ownService = ""
    private val subscriptions = mutableMapOf<String, NsdManager.ServiceInfoCallback>()
    @Volatile var endpoint = ""
        private set

    fun update(wifiEnabled: Boolean, force: Boolean = false) {
        if (!wifiEnabled || force) endpoint = ""
        main.post {
            if (!force && enabled == wifiEnabled) return@post
            enabled = wifiEnabled
            generation++
            val current = generation
            if (Build.VERSION.SDK_INT >= 34) {
                subscriptions.values.forEach { try { manager.unregisterServiceInfoCallback(it) } catch (_: Exception) { } }
                subscriptions.clear()
            }
            listener?.let { try { manager.stopServiceDiscovery(it) } catch (_: Exception) { } }
            listener = null; ownService = ""; endpoint = ""
            if (!wifiEnabled) return@post
            val queue = java.util.ArrayDeque<NsdServiceInfo>()
            var resolving = false
            fun resolveNext() {
                if (current != generation || resolving || queue.isEmpty()) return
                resolving = true
                val service = queue.removeFirst()
                try {
                    manager.resolveService(service, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                            main.post { if (current == generation) { resolving = false; resolveNext() } }
                        }
                        override fun onServiceResolved(info: NsdServiceInfo) {
                            main.post {
                                if (current != generation) return@post
                                accept(info)
                                resolving = false; resolveNext()
                            }
                        }
                    })
                } catch (_: Exception) { resolving = false; resolveNext() }
            }
            val discovery = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(type: String) { }
                override fun onDiscoveryStopped(type: String) { }
                override fun onStartDiscoveryFailed(type: String, errorCode: Int) { }
                override fun onStopDiscoveryFailed(type: String, errorCode: Int) { }
                override fun onServiceFound(info: NsdServiceInfo) {
                    main.post {
                        if (current != generation) return@post
                        if (Build.VERSION.SDK_INT >= 34) {
                            subscribe(info, current)
                        } else if (queue.size < 16) { queue.add(info); resolveNext() }
                    }
                }
                override fun onServiceLost(info: NsdServiceInfo) {
                    main.post {
                        if (current != generation) return@post
                        if (ownService == info.serviceName) endpoint = ""
                        if (Build.VERSION.SDK_INT >= 34) {
                            subscriptions.remove(info.serviceName)?.let {
                                try { manager.unregisterServiceInfoCallback(it) } catch (_: Exception) { }
                            }
                        }
                    }
                }
            }
            listener = discovery
            try { manager.discoverServices("_adb-tls-connect._tcp.", NsdManager.PROTOCOL_DNS_SD, discovery) }
            catch (_: Exception) { listener = null; enabled = false }
        }
    }

    private fun accept(info: NsdServiceInfo) {
        val local = try {
            NetworkInterface.getNetworkInterfaces().toList().flatMap { it.inetAddresses.toList() }
        } catch (_: Exception) { emptyList() }
        val addresses = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses else listOfNotNull(info.host)
        val ip = addresses.firstOrNull { it is Inet4Address && it in local }?.hostAddress
        if (ownService == info.serviceName) endpoint = ""
        if (ip == null || info.port !in 1..65535) return
        val candidate = "$ip:${info.port}"
        try {
            Protocol.origin("http://$candidate")
            endpoint = candidate
            ownService = info.serviceName
        } catch (_: Exception) { }
    }

    // ADB keeps its service name when restarting on a new port. One-shot resolution
    // can return the cached old port; keep listening for the replacement SRV record.
    @RequiresApi(34)
    private fun subscribe(info: NsdServiceInfo, current: Int) {
        val name = info.serviceName
        if (name in subscriptions || subscriptions.size >= 16) return
        val callback = object : NsdManager.ServiceInfoCallback {
            override fun onServiceUpdated(updated: NsdServiceInfo) {
                if (current == generation && subscriptions[name] === this) accept(updated)
            }
            override fun onServiceLost() {
                if (current == generation && subscriptions[name] === this && ownService == name) endpoint = ""
            }
            override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                if (subscriptions[name] === this) subscriptions.remove(name)
            }
            override fun onServiceInfoCallbackUnregistered() { }
        }
        subscriptions[name] = callback
        try { manager.registerServiceInfoCallback(info, { main.post(it) }, callback) }
        catch (_: Exception) { subscriptions.remove(name) }
    }

    fun close() = update(false, force = true)
}
