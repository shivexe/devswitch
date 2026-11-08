package com.himphen.playground.developeroptionstoggle.remote

import android.content.Context

// Packages whose notifications are never mirrored. The Mac's list arrives whole in `setMuted`;
// the phone keeps its own list from the mute screen. Either one mutes. Package names only.
object MutedApps {
    private const val PREFS = "muted_apps"

    fun isMuted(context: Context, pkg: String): Boolean = pkg in all(context)
    fun all(context: Context): Set<String> = local(context) + mac(context)
    fun local(context: Context): Set<String> = prefs(context).getStringSet("local", emptySet())!!
    private fun mac(context: Context): Set<String> = prefs(context).getStringSet("mac", emptySet())!!

    fun setFromMac(context: Context, pkgs: Collection<String>) = prefs(context).edit().putStringSet("mac", pkgs.take(500).toSet()).apply()

    /** The phone's own switch: unmuting also clears the Mac's mute for that app. */
    fun set(context: Context, pkg: String, muted: Boolean) {
        val edit = prefs(context).edit().putStringSet("local", if (muted) local(context) + pkg else local(context) - pkg)
        if (!muted) edit.putStringSet("mac", mac(context) - pkg)
        edit.apply()
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
