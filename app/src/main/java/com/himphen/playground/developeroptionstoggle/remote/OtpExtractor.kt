package com.himphen.playground.developeroptionstoggle.remote

import java.text.Normalizer

/** A one-time code and where it came from (normalised SMS sender, app label, or "" when unknown). */
data class Otp(val code: String, val source: String)

// Pure Kotlin (no Android imports) so it runs in JVM unit tests. Rules: research Part A §1 "OTP extraction heuristic".
object OtpExtractor {
    private val keyword = Regex(
        "\\b(otp|one[- ]time (pass(word|code)|code)|verification code|security code|auth(entication)? code|passcode|login code|code|pin|tac)\\b|ओटीपी|कोड|सत्यापन",
        RegexOption.IGNORE_CASE)
    // Digits (4–8, or 3-3 split by "-" or a space), optionally after a letter prefix such as "G-". Lookarounds keep 10-digit
    // numbers, decimals (2,499.00), dates (12/11/2026), times (10:45) and phone groups (1800-123-4567, 98 765 43210) out.
    private val numeric = Regex("(?<![\\p{L}\\d.,/:*-]|\\d[.,/:-])(?:[A-Z]{1,3}-)?(\\d{3}-\\d{3}|(?<!\\d )\\d{3} \\d{3}(?! \\d)|\\d{4,8})(?![\\p{L}\\d]|[.,/:-]\\d)")
    // Uppercase alphanumerics with at least two digits and one letter; accepted only right next to a keyword.
    // A word followed by a short number (SAVE50, FLAT100) is a promo code, not a one-time code.
    private val alphanumeric = Regex("(?<![\\p{L}\\d])(?![A-Z]{3,}\\d{1,3}(?![\\p{L}\\d]))(?=[A-Z0-9]*\\d[A-Z0-9]*\\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{6,8}(?![\\p{L}\\d])")
    private val amountBefore = Regex("(rs\\.?|inr|₹|\\$|usd|amt|amount)\\s*$", RegexOption.IGNORE_CASE)
    private val maskedBefore = Regex("(x{2,}|\\*+|ending( with)?|a/c( no\\.?)?|ac( no\\.?)?|acct|account|card( no\\.?)?)\\s*[:.]?\\s*$", RegexOption.IGNORE_CASE)
    private val durationAfter = Regex("^\\s*(min(ute)?s?|hrs?|hours?|sec(ond)?s?|days?)\\b", RegexOption.IGNORE_CASE)
    private val monthBefore = Regex("\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.?\\s*$", RegexOption.IGNORE_CASE)
    private val url = Regex("(https?://|www\\.)\\S+|\\S+\\.(com|in|net|org|co|io|me|ly)/\\S*", RegexOption.IGNORE_CASE)
    private val leadIn = Regex("(\\bis|\\bas|:|-)\\s*$", RegexOption.IGNORE_CASE)
    private val trailer = Regex("^\\s*(is|as)\\b", RegexOption.IGNORE_CASE)
    private val dltSender = Regex("^[A-Z]{2}-([A-Z0-9]{3,9})(?:-[SPTG])?$")

    fun extract(text: String, sender: String?): Otp? {
        val clean = normalise(text)
        val keywords = keyword.findAll(clean).map { it.range }.toList()
        if (keywords.isEmpty()) return null
        val urls = url.findAll(clean).map { it.range }.toList()
        var best: Pair<String, Int>? = null
        fun consider(range: IntRange, code: String, maxDistance: Int) {
            if (urls.any { range.first in it }) return
            val before = clean.substring(maxOf(0, range.first - 16), range.first)
            val after = clean.substring(range.last + 1, minOf(clean.length, range.last + 17))
            if (amountBefore.containsMatchIn(before) || maskedBefore.containsMatchIn(before) || durationAfter.containsMatchIn(after)) return
            if (code.length == 4 && monthBefore.containsMatchIn(before)) return
            val distance = keywords.minOf { k -> if (k.last < range.first) range.first - k.last - 1 else if (k.first > range.last) k.first - range.last - 1 else 0 }
            if (distance > maxDistance) return
            var score = distance
            if (leadIn.containsMatchIn(before) || trailer.containsMatchIn(after)) score -= 10
            if (code.length == 6) score -= 5
            if (best == null || score < best!!.second) best = code to score
        }
        for (match in numeric.findAll(clean)) {
            val digits = match.groupValues[1]
            consider(match.range, digits.replace("-", "").replace(" ", ""), 40)
        }
        for (match in alphanumeric.findAll(clean)) consider(match.range, match.value, 12)
        return best?.let { Otp(it.first, sender?.let(::normaliseSender).orEmpty()) }
    }

    /** DLT headers such as AX-HDFCBK, VM-SBIOTP-S or JD-AMAZON-T become HDFCBK, SBIOTP, AMAZON. */
    fun normaliseSender(raw: String): String {
        val trimmed = raw.trim()
        return dltSender.matchEntire(trimmed.uppercase())?.groupValues?.get(1) ?: trimmed
    }

    // NFKC, every Unicode decimal digit (Devanagari, Bengali, …) to ASCII, whitespace collapsed.
    private fun normalise(text: String): String {
        val nfkc = Normalizer.normalize(text, Normalizer.Form.NFKC)
        val builder = StringBuilder(nfkc.length)
        for (c in nfkc) builder.append(if (Character.isDigit(c) && c !in '0'..'9') ('0' + Character.getNumericValue(c)) else c)
        return builder.toString().replace(Regex("\\s+"), " ")
    }
}

/** SMS and the notification listener both see one SMS: the same code within 90 s is one OTP. Memory only. */
object OtpDedupe {
    private const val WINDOW_MS = 90_000L
    private val recent = LinkedHashMap<String, Long>()

    @Synchronized fun isNew(code: String, now: Long = System.currentTimeMillis()): Boolean {
        val last = recent[code]
        if (last != null && now - last <= WINDOW_MS) return false
        recent.remove(code); recent[code] = now
        while (recent.size > 20) recent.remove(recent.keys.first())
        return true
    }
}
