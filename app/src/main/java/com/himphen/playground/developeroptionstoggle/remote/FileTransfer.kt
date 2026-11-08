package com.himphen.playground.developeroptionstoggle.remote

import android.content.Context
import android.net.Uri
import android.util.Log
import org.json.JSONObject
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit

// Encrypted chunked file channel (research §4.2), phone side. The phone always initiates:
// uploads POST /v2/file/<id>/<index>, downloads POST /v2/file/<id>/<index>/get, resume reads /status.
object FileTransfer {
    const val CHUNK = 256 * 1024
    private val answers = ConcurrentHashMap<String, CompletableFuture<Boolean>>()

    /** Offers a file to the Mac and uploads it once accepted. Returns the transferId at once. */
    fun upload(context: Context, uri: Uri, name: String, size: Long, mime: String): String {
        val transferId = UUID.randomUUID().toString()
        val answer = CompletableFuture<Boolean>().also { answers[transferId] = it }
        Thread({
            try {
                val digest = MessageDigest.getInstance("SHA-256")
                val hashed = read(context, uri) { _, chunk -> digest.update(chunk) }
                check(hashed == size) { "Size changed" }
                Outbox.add("fileOffer", JSONObject().put("transferId", transferId).put("name", name).put("size", size).put("mime", mime)
                    .put("sha256", digest.digest().joinToString("") { "%02x".format(it) }).put("chunkSize", CHUNK))
                if (!answer.get(10, TimeUnit.MINUTES)) return@Thread
                val total = total(size)
                val pool = Executors.newFixedThreadPool(4)
                try {
                    // Each pass sends what the Mac does not have yet; later passes resume after failures.
                    for (pass in 0 until 3) {
                        val have = have(transferId)
                        if (have.size == total) break
                        val pending = ArrayList<Future<*>>()
                        read(context, uri) { index, chunk ->
                            if (index in have) return@read
                            // At most four chunks in flight; this also bounds memory.
                            if (pending.size >= 4) pending.removeAt(0).runCatching { get() }
                            pending += pool.submit {
                                val session = checkNotNull(RemoteService.session)
                                val path = "/v2/file/$transferId/$index"
                                val body = Protocol.sealBytes(chunk, session.key, aad(session.deviceId, transferId, index, total))
                                check(Protocol.postBytes(session.origin, path, body).first == 200)
                            }
                        }
                        pending.forEach { it.runCatching { get() } }
                    }
                } finally { pool.shutdown() }
            } catch (error: Exception) {
                Log.w("DevSwitchConnection", "Upload: ${error.javaClass.simpleName}")
            } finally { answers.remove(transferId) }
        }, "DevSwitch upload").start()
        return transferId
    }

    /** Pulls a Mac→phone `fileOffer` command's chunks into [sink] and verifies the SHA-256. Throws on failure. */
    fun download(context: Context, offer: JSONObject, sink: OutputStream) {
        val transferId = offer.getString("transferId")
        val size = offer.getLong("size")
        require(offer.getInt("chunkSize") == CHUNK && size >= 0)
        val total = total(size)
        val digest = MessageDigest.getInstance("SHA-256")
        // Four chunk requests in flight; chunks are written in order, so at most four are held in memory.
        val pool = Executors.newFixedThreadPool(4)
        try {
            val inFlight = java.util.ArrayDeque<Future<ByteArray>>()
            var next = 0
            for (index in 0 until total) {
                while (next < total && inFlight.size < 4) {
                    val requested = next++
                    inFlight += pool.submit<ByteArray> {
                        retry {
                            val session = checkNotNull(RemoteService.session)
                            val (code, body) = Protocol.postBytes(session.origin, "/v2/file/$transferId/$requested/get", ByteArray(0))
                            check(code == 200) { "Mac returned HTTP $code" }
                            Protocol.openBytes(body, session.key, aad(session.deviceId, transferId, requested, total))
                        }
                    }
                }
                val chunk = try { inFlight.removeFirst().get() } catch (error: java.util.concurrent.ExecutionException) { throw error.cause ?: error }
                check(chunk.size.toLong() == minOf(CHUNK.toLong(), size - index.toLong() * CHUNK)) { "Wrong chunk size" }
                digest.update(chunk); sink.write(chunk)
            }
        } finally { pool.shutdownNow() }
        check(digest.digest().joinToString("") { "%02x".format(it) } == offer.getString("sha256").lowercase()) { "Checksum mismatch" }
    }

    /** Delivers the Mac's fileAccept/fileDecline; false when no upload is waiting for it. */
    fun answer(transferId: String, accepted: Boolean): Boolean = answers[transferId]?.complete(accepted) == true

    private fun total(size: Long) = maxOf(1L, (size + CHUNK - 1) / CHUNK).toInt()
    private fun aad(deviceId: String, transferId: String, index: Int, total: Int) =
        "devswitch/file/v1/$deviceId/$transferId/$index/$total/${if (index == total - 1) 1 else 0}"

    private fun have(transferId: String): Set<Int> {
        val session = checkNotNull(RemoteService.session)
        val (code, response) = Protocol.post(session.origin, "/v2/file/$transferId/status", JSONObject())
        check(code == 200) { "Mac returned HTTP $code" }
        val have = Protocol.open(response, session.key, "devswitch/file/v1/${session.deviceId}/$transferId/status").getJSONArray("have")
        return (0 until have.length()).map(have::getInt).toSet()
    }

    // Streams the Uri in CHUNK-sized pieces (the last may be shorter; an empty file is one empty chunk). Returns the byte count.
    private fun read(context: Context, uri: Uri, each: (Int, ByteArray) -> Unit): Long {
        val input: InputStream = checkNotNull(context.contentResolver.openInputStream(uri))
        var total = 0L
        input.use {
            var index = 0
            while (true) {
                // InputStream.readNBytes needs API 33; fill the chunk by hand.
                var buffer = ByteArray(CHUNK)
                var filled = 0
                while (filled < CHUNK) { val count = it.read(buffer, filled, CHUNK - filled); if (count < 0) break; filled += count }
                if (filled < CHUNK) buffer = buffer.copyOf(filled)
                if (buffer.isEmpty() && index > 0) break
                each(index++, buffer); total += buffer.size
                if (buffer.size < CHUNK) break
            }
        }
        return total
    }

    private fun <T> retry(block: () -> T): T {
        var last: Exception? = null
        repeat(3) { try { return block() } catch (error: Exception) { last = error; Thread.sleep(500) } }
        throw last!!
    }
}
