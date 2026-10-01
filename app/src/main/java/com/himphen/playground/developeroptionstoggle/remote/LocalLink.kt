package com.himphen.playground.developeroptionstoggle.remote

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.NetworkInterface

object LocalLink {
    data class Link(val ipv4: String, val ipv6: String?, val index: Int)
    fun current(context: Context): Link? {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        for (network in manager.allNetworks) {
            if (manager.getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) != true) continue
            val name = manager.getLinkProperties(network)?.interfaceName ?: continue
            val iface = NetworkInterface.getByName(name) ?: continue
            val addresses = iface.inetAddresses.toList()
            val ipv4 = addresses.filterIsInstance<Inet4Address>().firstOrNull { it.isSiteLocalAddress }?.hostAddress ?: continue
            val ipv6 = addresses.filterIsInstance<Inet6Address>().firstOrNull { it.isLinkLocalAddress }?.hostAddress?.substringBefore('%')
            return Link(ipv4, ipv6, iface.index)
        }
        return null
    }
    fun isLinkLocal(host: String): Boolean = try {
        host.length <= 39 && host.contains(':') && host.all { it in "0123456789abcdefABCDEF:" } &&
            InetAddress.getByName(host).let { it is Inet6Address && it.isLinkLocalAddress }
    } catch (_: Exception) { false }

    fun origin(context: Context, host: String, port: Int): String? {
        if (!isLinkLocal(host) || port !in 1..65535) return null
        val link = current(context) ?: return null
        return "http://[$host%${link.index}]:$port"
    }
}
