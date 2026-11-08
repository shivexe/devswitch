package com.himphen.playground.developeroptionstoggle.remote

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.util.Base64
import javax.crypto.AEADBadTagException

// Shared vectors live in <repo>/test-vectors and are verified by mac-tests/run.sh too.
class ProtocolV2Test {
    private fun vector(name: String): JSONObject {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null && !File(dir, "test-vectors").isDirectory) dir = dir.parentFile
        return JSONObject(File(dir ?: error("test-vectors not found"), "test-vectors/$name").readText(Charsets.UTF_8))
    }
    private fun hex(value: String) = ByteArray(value.length / 2) { value.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private fun b64(value: String): ByteArray = Base64.getDecoder().decode(value)
    private fun envelope(v: JSONObject, case: JSONObject = v) = JSONObject()
        .put("nonce", Protocol.encode(hex(case.getString("nonceHex"))))
        .put("ciphertext", case.getString("ciphertextB64")).put("tag", case.getString("tagB64"))
    private val key = ByteArray(32) { it.toByte() }

    // Outbox is process-wide; drain it so each test starts empty.
    @Before fun clearOutbox() {
        while (true) { val b = Outbox.batch(); if (b.isEmpty()) break; Outbox.ack(b.map { it.getString("id") }) }
        Outbox.takeDropped()
    }

    // ---- vectors: Kotlin must produce the exact ciphertext+tag and open every positive case.

    @Test fun sealWithInjectedNonceMatchesEveryVector() {
        for (name in listOf("poll-v2.json", "reply-v2.json", "file-chunk.json")) {
            val v = vector(name)
            val cases = listOf(v) + (0 until v.getJSONArray("schemaCases").length()).map { v.getJSONArray("schemaCases").getJSONObject(it) }
            for (c in cases) {
                val nonce = hex(c.getString("nonceHex"))
                val sealed = Protocol.sealBytes(c.getString("plaintextUtf8").toByteArray(Charsets.UTF_8), hex(v.getString("keyHex")), c.getString("aad"), nonce)
                assertArrayEquals("$name ${c.optString("name")}", nonce + b64(c.getString("ciphertextB64")) + b64(c.getString("tagB64")), sealed)
            }
        }
    }

    @Test fun pollVectorOpensAndDecodes() {
        val v = vector("poll-v2.json")
        val poll = Protocol.open(envelope(v), key, v.getString("aad"))
        val expect = v.getJSONObject("expect")
        assertEquals(expect.getString("requestId"), poll.getString("requestId"))
        assertEquals(expect.getLong("sentAt"), poll.getLong("sentAt"))
        val events = poll.getJSONArray("events")
        assertEquals(expect.getJSONArray("eventIds").toList(), (0 until events.length()).map { events.getJSONObject(it).getString("id") })
        assertEquals(expect.getJSONArray("eventTypes").toList(), (0 until events.length()).map { events.getJSONObject(it).getString("t") })
        assertEquals(expect.getString("notificationText"), events.getJSONObject(2).getString("text"))
        assertEquals(expect.getInt("battery"), poll.getJSONObject("status").getInt("battery"))
        assertEquals(expect.getJSONArray("receiptIds").getString(0), poll.getJSONArray("receipts").getJSONObject(0).getString("id"))
    }

    @Test fun replyVectorOpensAndDecodesCommands() {
        val v = vector("reply-v2.json")
        val reply = Protocol.open(envelope(v), key, v.getString("aad"))
        val expect = v.getJSONObject("expect")
        assertEquals(expect.getString("requestId"), reply.getString("requestId"))
        assertEquals(expect.getJSONArray("ack").toList(), reply.getJSONArray("ack").toList())
        assertEquals(500L, reply.optLong("nextPollMs", 2000))
        val commands = reply.getJSONArray("commands")
        assertEquals(expect.getJSONArray("commandIds").toList(), (0 until commands.length()).map { commands.getJSONObject(it).getString("id") })
        assertEquals(expect.getJSONArray("actions").toList(), (0 until commands.length()).map { commands.getJSONObject(it).getString("a") })
        val sms = commands.getJSONObject(1)
        assertEquals("+919876543210", sms.getString("to")); assertEquals(expect.getString("smsBody"), sms.getString("body")); assertEquals(1, sms.getInt("subId"))
        assertTrue(commands.getJSONObject(2).getBoolean("sensitive"))
        assertTrue(reply.isNull("desktopIPv6"))
    }

    @Test fun replySchemaCasesDecode() {
        val cases = vector("reply-v2.json").getJSONArray("schemaCases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val reply = Protocol.open(envelope(c, c), key, c.getString("aad"))
            val commands = reply.getJSONArray("commands")
            when (c.getString("name")) {
                // RemoteService runs at most 16 commands per reply; this vector carries 17.
                "oversizeCommands" -> assertEquals(17, commands.length())
                "unknownAction" -> assertEquals("selfDestruct", commands.getJSONObject(0).getString("a"))
                "duplicateCommandIds" -> assertEquals(commands.getJSONObject(0).getString("id"), commands.getJSONObject(1).getString("id"))
            }
        }
    }

    @Test fun fileChunkVectorOpens() {
        val v = vector("file-chunk.json")
        val plain = Protocol.openBytes(b64(v.getString("framedB64")), key, v.getString("aad"))
        assertEquals(v.getString("plaintextUtf8"), String(plain, Charsets.UTF_8))
        assertEquals(v.getJSONObject("expect").getInt("plaintextLength"), plain.size)
    }

    @Test fun negativeVectorsFailAuthentication() {
        for (name in listOf("poll-v2.json", "reply-v2.json")) {
            val v = vector(name)
            val negatives = v.getJSONArray("negative")
            for (i in 0 until negatives.length()) {
                val n = negatives.getJSONObject(i)
                val e = envelope(v)
                n.optString("ciphertextB64").takeIf { it.isNotEmpty() }?.let { e.put("ciphertext", it) }
                n.optString("tagB64").takeIf { it.isNotEmpty() }?.let { e.put("tag", it) }
                expectFailure("$name ${n.getString("name")}") { Protocol.open(e, key, n.optString("aad").ifEmpty { v.getString("aad") }) }
            }
        }
        val v = vector("file-chunk.json")
        val framed = b64(v.getString("framedB64"))
        val negatives = v.getJSONArray("negative")
        for (i in 0 until negatives.length()) {
            val n = negatives.getJSONObject(i)
            val nonce = framed.copyOfRange(0, 12)
            val body = when {
                n.has("framedB64") -> b64(n.getString("framedB64"))
                n.has("ciphertextB64") -> nonce + b64(n.getString("ciphertextB64")) + b64(v.getString("tagB64"))
                n.has("tagB64") -> nonce + b64(v.getString("ciphertextB64")) + b64(n.getString("tagB64"))
                else -> framed
            }
            expectFailure("file ${n.getString("name")}") { Protocol.openBytes(body, key, n.optString("aad").ifEmpty { v.getString("aad") }) }
        }
    }

    // ---- codec behaviour

    @Test fun sealOpenRoundTripWithRandomNonce() {
        val value = JSONObject().put("requestId", "r").put("text", "नमस्ते / \"x\"").put("n", 3)
        val a = Protocol.seal(value, key, "devswitch/poll/v2/dev")
        val b = Protocol.seal(value, key, "devswitch/poll/v2/dev")
        assertFalse("production nonces must differ", a.getString("nonce") == b.getString("nonce"))
        val opened = Protocol.open(a, key, "devswitch/poll/v2/dev")
        assertEquals("नमस्ते / \"x\"", opened.getString("text")); assertEquals(3, opened.getInt("n"))
    }

    @Test fun injectedNonceIsUsedVerbatimAndDeterministic() {
        val nonce = ByteArray(12) { (0xa0 + it).toByte() }
        val value = JSONObject().put("requestId", "only-one-key")
        val a = Protocol.seal(value, key, "aad", nonce)
        val b = Protocol.seal(value, key, "aad", nonce)
        assertEquals(Protocol.encode(nonce), a.getString("nonce"))
        assertEquals(a.toString(), b.toString())
        assertArrayEquals(nonce, Protocol.sealBytes(byteArrayOf(1, 2, 3), key, "aad", nonce).copyOfRange(0, 12))
    }

    @Test fun badKeyOrNonceSizesAreRejected() {
        expectFailure("short key") { Protocol.seal(JSONObject(), ByteArray(16), "aad") }
        expectFailure("short nonce") { Protocol.seal(JSONObject(), key, "aad", ByteArray(8)) }
        expectFailure("short nonce bytes") { Protocol.sealBytes(ByteArray(1), key, "aad", ByteArray(11)) }
        val e = Protocol.seal(JSONObject().put("a", 1), key, "aad")
        expectFailure("nonce not 12 bytes") { Protocol.open(JSONObject(e.toString()).put("nonce", Protocol.encode(ByteArray(16))), key, "aad") }
        expectFailure("tag not 16 bytes") { Protocol.open(JSONObject(e.toString()).put("tag", Protocol.encode(ByteArray(12))), key, "aad") }
    }

    @Test fun tamperAndWrongAadFail() {
        val e = Protocol.seal(JSONObject().put("a", 1), key, "devswitch/reply/v2/dev")
        expectFailure("wrong aad") { Protocol.open(e, key, "devswitch/reply/v2/other") }
        expectFailure("wrong key") { Protocol.open(e, ByteArray(32) { 7 }, "devswitch/reply/v2/dev") }
        val ct = Base64.getDecoder().decode(e.getString("ciphertext")).also { it[0] = (it[0].toInt() xor 0x80).toByte() }
        expectFailure("tampered") { Protocol.open(JSONObject(e.toString()).put("ciphertext", Protocol.encode(ct)), key, "devswitch/reply/v2/dev") }
        val framed = Protocol.sealBytes(ByteArray(64), key, "f").also { it[20] = (it[20].toInt() xor 1).toByte() }
        expectFailure("tampered frame") { Protocol.openBytes(framed, key, "f") }
    }

    @Test fun pollCiphertextCapIs32768Bytes() {
        // A JSON body whose ciphertext is exactly 32 768 bytes opens; one byte more is refused before decrypting.
        val overhead = JSONObject().put("p", "").toString().length
        val fits = Protocol.seal(JSONObject().put("p", "x".repeat(32768 - overhead)), key, "aad")
        assertEquals(32768, Base64.getDecoder().decode(fits.getString("ciphertext")).size)
        Protocol.open(fits, key, "aad")
        val over = Protocol.seal(JSONObject().put("p", "x".repeat(32769 - overhead)), key, "aad")
        expectFailure("32 769 bytes") { Protocol.open(over, key, "aad") }
    }

    @Test fun fileFrameBounds() {
        // 256 KiB chunk + 28 bytes framing is the largest real frame; the cap is 300 KiB, the floor is 28 (empty chunk).
        val chunk = ByteArray(256 * 1024) { it.toByte() }
        assertArrayEquals(chunk, Protocol.openBytes(Protocol.sealBytes(chunk, key, "f"), key, "f"))
        assertEquals(0, Protocol.openBytes(Protocol.sealBytes(ByteArray(0), key, "f"), key, "f").size)
        expectFailure("27 bytes") { Protocol.openBytes(ByteArray(27), key, "f") }
        expectFailure("over 300 KiB") { Protocol.openBytes(Protocol.sealBytes(ByteArray(300 * 1024), key, "f"), key, "f") }
    }

    // ---- Outbox: what a poll may carry

    @Test fun outboxBatchCapsAt32EventsAndAbout20KB() {
        repeat(40) { Outbox.add("link", JSONObject().put("url", "https://example.com/$it")) }
        val first = Outbox.batch()
        assertEquals(32, first.size)
        Outbox.ack(first.map { it.getString("id") })
        assertEquals(8, Outbox.batch().size)
        Outbox.ack(Outbox.batch().map { it.getString("id") })
        repeat(5) { Outbox.add("clipboard", JSONObject().put("text", "y".repeat(6000))) }
        val big = Outbox.batch()
        assertTrue(big.sumOf { it.toString().toByteArray().size } <= 20_000)
        assertEquals(3, big.size)
    }

    @Test fun outboxPutsPriorityFirstAndDropsOversizeAndEvictsNonPriority() {
        val plain = Outbox.add("link", JSONObject().put("url", "https://a"))
        val otp = Outbox.add("otp", JSONObject().put("code", "123456"), priority = true)
        assertEquals(listOf(otp, plain), Outbox.batch().map { it.getString("id") })
        Outbox.add("clipboard", JSONObject().put("text", "z".repeat(21_000)))
        assertEquals(2, Outbox.batch().size)
        assertEquals(1, Outbox.takeDropped())
        repeat(199) { Outbox.add("link", JSONObject().put("url", "https://$it")) }
        // 201 added with one slot used by the OTP: the oldest non-priority event goes, the OTP stays.
        val ids = mutableListOf<String>()
        while (true) { val b = Outbox.batch(); if (b.isEmpty()) break; ids += b.map { it.getString("id") }; Outbox.ack(b.map { it.getString("id") }) }
        assertEquals(200, ids.size)
        assertTrue(otp in ids); assertFalse(plain in ids)
        assertEquals(otp, ids.first())
    }

    @Test fun outboxEventCarriesIdTypeAndTime() {
        val id = Outbox.add("link", JSONObject().put("url", "https://a").put("t", "spoof").put("id", "spoof"))
        val event = Outbox.batch().single()
        assertEquals(id, event.getString("id")); assertEquals("link", event.getString("t")); assertTrue(event.getLong("at") > 1_700_000_000)
    }

    private fun expectFailure(label: String, block: () -> Unit) {
        try { block(); fail("$label: expected failure") }
        catch (e: AssertionError) { if (e.message?.endsWith("expected failure") == true) throw e }
        catch (_: AEADBadTagException) {} catch (_: Exception) {}
    }
    private fun JSONArray.toList(): List<Any> = (0 until length()).map { get(it) }
}
