package com.himphen.playground.developeroptionstoggle.remote

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import android.system.Os

object LocalLink {
    data class Link(val ipv4: String, val ipv6: String?, val index: Int)
    fun current(context: Context): Link? {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        for (network in manager.allNetworks) {
            if (manager.getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) != true) continue
            val properties = manager.getLinkProperties(network) ?: continue
            val name = properties.interfaceName ?: continue
            // getByName enumerates every interface on Android and can stall the heartbeat.
            // LinkProperties already contains this Wi-Fi network's addresses.
            val index = Os.if_nametoindex(name)
            if (index <= 0) continue
            val addresses = properties.linkAddresses.map { it.address }
            val ipv4 = addresses.filterIsInstance<Inet4Address>().firstOrNull { it.isSiteLocalAddress }?.hostAddress ?: continue
            val ipv6 = addresses.filterIsInstance<Inet6Address>().firstOrNull { it.isLinkLocalAddress }?.hostAddress?.substringBefore('%')
            return Link(ipv4, ipv6, index)
        }
        return null
    }
    fun isLinkLocal(host: String): Boolean = try {
        host.length <= 39 && host.contains(':') && host.all { it in "0123456789abcdefABCDEF:" } &&
            InetAddress.getByName(host).let { it is Inet6Address && it.isLinkLocalAddress }
    } catch (_: Exception) { false }

    fun origin(link: Link?, host: String, port: Int): String? {
        if (!isLinkLocal(host) || port !in 1..65535) return null
        if (link == null) return null
        return "http://[$host%${link.index}]:$port"
    }
}
