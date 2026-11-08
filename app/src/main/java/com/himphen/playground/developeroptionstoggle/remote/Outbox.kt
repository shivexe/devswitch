package com.himphen.playground.developeroptionstoggle.remote

import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Semaphore

// Phone→Mac events waiting for the Mac's ack. Memory only; payloads are never logged or persisted.
object Outbox {
    private const val CAPACITY = 200
    private const val EXPIRY_MS = 300_000L
    private class Item(val event: JSONObject, val priority: Boolean, val added: Long)
    private val items = LinkedHashMap<String, Item>()
    private var dropped = 0
    // RemoteService waits on this between polls; a release wakes it for an immediate poll.
    internal val wake = Semaphore(0)

    /** Queues an event and wakes the poll loop. Priority events (OTP, calls) are dropped last on overflow. */
    fun add(type: String, fields: JSONObject, priority: Boolean = false): String {
        val id = UUID.randomUUID().toString()
        val event = JSONObject(fields.toString()).put("id", id).put("t", type).put("at", System.currentTimeMillis() / 1000)
        synchronized(items) {
            expire()
            if (items.size >= CAPACITY) {
                val victim = items.entries.firstOrNull { !it.value.priority } ?: items.entries.first()
                items.remove(victim.key); dropped++
            }
            items[id] = Item(event, priority, System.currentTimeMillis())
        }
        kick()
        return id
    }
    fun kick() = wake.release()

    fun isEmpty(): Boolean = synchronized(items) { expire(); items.isEmpty() }

    /** Up to 32 events and about 20 KB of plaintext, priority events first, otherwise oldest first. */
    internal fun batch(): List<JSONObject> = synchronized(items) {
        expire()
        val result = ArrayList<JSONObject>()
        var size = 0
        for ((id, item) in items.entries.sortedByDescending { it.value.priority }) {
            val bytes = item.event.toString().toByteArray(Charsets.UTF_8).size
            // One event can never fit a poll; drop it instead of failing every poll.
            if (bytes > 20_000) { items.remove(id); dropped++; continue }
            if (result.size == 32 || (result.isNotEmpty() && size + bytes > 20_000)) break
            result += item.event; size += bytes
        }
        result
    }
    internal fun ack(ids: Collection<String>) = synchronized(items) { ids.forEach(items::remove) }
    internal fun takeDropped(): Int = synchronized(items) { dropped.also { dropped = 0 } }

    // Events the Mac could not take within five minutes are stale (codes, calls).
    private fun expire() {
        val cutoff = System.currentTimeMillis() - EXPIRY_MS
        items.entries.removeAll { it.value.added < cutoff }
    }
}
