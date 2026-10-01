package com.himphen.playground.developeroptionstoggle.remote

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object Protocol {
    private val random = SecureRandom()
    fun bytes(count: Int) = ByteArray(count).also(random::nextBytes)
    fun encode(value: ByteArray): String = Base64.encodeToString(value, Base64.NO_WRAP)
    fun decode(value: String, size: Int = -1): ByteArray {
        val data = Base64.decode(value, Base64.NO_WRAP)
        require(size < 0 || data.size == size) { "Invalid key or nonce" }
        return data
    }
    fun seal(value: JSONObject, key: ByteArray, aad: String): JSONObject {
        require(key.size == 32)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val iv = bytes(12)
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
        val output = cipher.doFinal(value.toString().toByteArray(Charsets.UTF_8))
        return JSONObject().put("nonce", encode(iv)).put("ciphertext", encode(output.copyOfRange(0, output.size - 16)))
            .put("tag", encode(output.copyOfRange(output.size - 16, output.size)))
    }
    fun open(value: JSONObject, key: ByteArray, aad: String): JSONObject {
        require(key.size == 32)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, decode(value.getString("nonce"), 12)))
        cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
        val ciphertext = decode(value.getString("ciphertext"))
        require(ciphertext.size <= 32768)
        return JSONObject(String(cipher.doFinal(ciphertext + decode(value.getString("tag"), 16)), Charsets.UTF_8))
    }
    fun comparison(key: ByteArray, nonce: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(key + nonce)
        var number = 0L
        for (i in 0..3) number = (number shl 8) or (digest[i].toLong() and 255)
        return "%06d".format(java.util.Locale.ROOT, number % 1000000)
    }
    fun origin(value: String): URI {
        val uri = URI(value)
        require(uri.scheme == "http" && uri.userInfo == null && uri.query == null && uri.fragment == null &&
            (uri.path.isNullOrEmpty() || uri.path == "/") && uri.port in 1..65535)
        val host = uri.host ?: ""
        if (host.startsWith('[') && host.endsWith(']')) {
            val scoped = host.drop(1).dropLast(1).split('%')
            require(scoped.size == 2 && LocalLink.isLinkLocal(scoped[0]) &&
                scoped[1].isNotEmpty() && scoped[1].all { it in '0'..'9' })
            return uri
        }
        val parts = (uri.host ?: "").split('.')
        require(parts.size == 4 && parts.all { it.isNotEmpty() && it.all(Char::isDigit) && (it.toIntOrNull() ?: -1) in 0..255 })
        val p = parts.map(String::toInt)
        require(p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && p[1] in 16..31)) { "Use the same private Wi-Fi network" }
        return uri
    }
    fun post(origin: String, path: String, payload: JSONObject): Pair<Int, JSONObject> {
        val uri = origin(origin)
        if (uri.host.startsWith('[')) return postLinkLocal(uri, path, payload)
        val connection = uri.resolve(path).toURL().openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 4000; connection.readTimeout = 4000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            val bytes = payload.toString().toByteArray(Charsets.UTF_8)
            require(bytes.size <= 32768)
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.outputStream.use { it.write(bytes) }
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val buffer = ByteArrayOutputStream()
            stream?.use { input ->
                val chunk = ByteArray(2048)
                while (true) {
                    val count = input.read(chunk)
                    if (count < 0) break
                    require(buffer.size() + count <= 32768) { "Response too large" }
                    buffer.write(chunk, 0, count)
                }
            }
            return code to JSONObject(buffer.toString("UTF-8").ifEmpty { "{}" })
        } finally { connection.disconnect() }
    }

    // Android's HttpURLConnection rejects IPv6 zone IDs. Use a scoped socket for
    // this local-only HTTP transport; payload authentication/encryption is unchanged.
    private fun postLinkLocal(uri: URI, path: String, payload: JSONObject): Pair<Int, JSONObject> {
        require(path.startsWith('/') && path.length <= 160 && path.none { it <= ' ' || it == '\u007f' })
        val bytes = payload.toString().toByteArray(Charsets.UTF_8)
        require(bytes.size <= 32768)
        val address = InetAddress.getByName(uri.host.drop(1).dropLast(1))
        require(address.isLinkLocalAddress)
        return Socket().use { socket ->
            socket.soTimeout = 4000
            socket.connect(InetSocketAddress(address, uri.port), 4000)
            val header = "POST $path HTTP/1.1\r\nHost: ${uri.rawAuthority}\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n"
            socket.getOutputStream().apply {
                write(header.toByteArray(Charsets.US_ASCII)); write(bytes); flush()
            }
            val input = socket.getInputStream().buffered()
            var headerSize = 0
            fun line(): String {
                val output = ByteArrayOutputStream()
                while (true) {
                    val value = input.read()
                    check(value >= 0 && ++headerSize <= 16384) { "Incomplete or oversized HTTP header" }
                    if (value == 10) {
                        val data = output.toByteArray()
                        check(data.isNotEmpty() && data.last() == 13.toByte()) { "Invalid HTTP header" }
                        return String(data, 0, data.size - 1, Charsets.US_ASCII)
                    }
                    output.write(value)
                }
            }
            val status = line().split(' ', limit = 3)
            check(status.size >= 2 && status[0] == "HTTP/1.1") { "Invalid HTTP response" }
            val code = status[1].toInt()
            val headers = mutableMapOf<String, String>()
            while (true) {
                val value = line()
                if (value.isEmpty()) break
                val colon = value.indexOf(':')
                check(colon > 0 && !value.startsWith(' ') && !value.startsWith('\t'))
                val name = value.substring(0, colon).lowercase(java.util.Locale.ROOT)
                check(headers.put(name, value.substring(colon + 1).trim()) == null) { "Duplicate HTTP header" }
            }
            check("transfer-encoding" !in headers)
            val length = headers["content-length"]?.toIntOrNull() ?: error("Missing HTTP length")
            check(length in 0..32768) { "Response too large" }
            val body = ByteArray(length)
            var offset = 0
            while (offset < length) {
                val count = input.read(body, offset, length - offset)
                check(count > 0) { "Incomplete HTTP response" }
                offset += count
            }
            code to JSONObject(String(body, Charsets.UTF_8).ifEmpty { "{}" })
        }
    }
}

// Only encrypted pairing material is stored on disk. Its wrapping key stays in Android Keystore.
object PairStore {
    private const val ALIAS = "devswitch.pairing.v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!store.containsAlias(ALIAS)) {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256).build())
            }.generateKey()
        }
        return store.getKey(ALIAS, null) as SecretKey
    }
    @Synchronized fun save(context: Context, value: JSONObject) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val output = cipher.doFinal(value.toString().toByteArray(Charsets.UTF_8))
        val stored = JSONObject().put("iv", Protocol.encode(cipher.iv)).put("data", Protocol.encode(output)).toString()
        check(context.getSharedPreferences("devswitch", Context.MODE_PRIVATE).edit().putString("pairing", stored).commit())
    }
    @Synchronized fun load(context: Context): JSONObject? {
        val stored = context.getSharedPreferences("devswitch", Context.MODE_PRIVATE).getString("pairing", null) ?: return null
        val value = JSONObject(stored)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Protocol.decode(value.getString("iv"), 12)))
        return JSONObject(String(cipher.doFinal(Protocol.decode(value.getString("data"))), Charsets.UTF_8))
    }
    @Synchronized fun clear(context: Context) {
        check(context.getSharedPreferences("devswitch", Context.MODE_PRIVATE).edit().clear().commit())
        KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(ALIAS) }
    }
}
