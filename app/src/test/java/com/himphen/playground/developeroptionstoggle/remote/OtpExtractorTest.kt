package com.himphen.playground.developeroptionstoggle.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Fixtures: research Part A §1 item 6 plus realistic Indian bank/UPI/e-commerce/app messages.
// Each table is checked in full and every mismatch is reported together.
class OtpExtractorTest {
    private fun check(cases: List<Pair<String, String?>>) {
        val wrong = cases.mapNotNull { (text, expected) ->
            val got = OtpExtractor.extract(text, null)?.code
            if (got == expected) null else "expected=$expected got=$got  <<$text>>"
        }
        assertTrue("${wrong.size} of ${cases.size} wrong:\n" + wrong.joinToString("\n"), wrong.isEmpty())
    }

    @Test fun researchFixtures() = check(listOf(
        "123456 is your OTP for txn of Rs 2,499.00 at AMAZON on HDFC Bank card ending 4321. Valid for 10 mins. Do not share." to "123456",
        "Dear Customer, OTP for login is 482913. Do not share it with anyone - SBI" to "482913",
        "Use 7712 as OTP to verify your mobile on Swiggy. -Swiggy" to "7712",
        "आपका OTP 551204 है। किसी के साथ साझा न करें।" to "551204",
        // Decision (b): the letter prefix is dropped, so G-839201 yields the digits only.
        "G-839201 is your Google verification code." to "839201",
        "Rs 4500 debited from a/c XX1234" to null,
    ))

    @Test fun indianBanksAndUpi() = check(listOf(
        "Your Axis Bank OTP for transaction of INR 1,250.00 at FLIPKART is 604213. Valid for 5 mins. Do not share OTP with anyone." to "604213",
        "Dear Customer, 918273 is the OTP for your ICICI Bank Credit Card XX5678 transaction of INR 3,999.00 at MYNTRA. Valid for 10 minutes." to "918273",
        "OTP is 334455 for txn of INR 750.00 on Kotak Bank Card xx9012 at ZOMATO. Do not share with anyone." to "334455",
        "Your Paytm OTP is 1928. Valid for 3 minutes. Do not share it with anyone. -Paytm" to "1928",
        "OTP for IRCTC login is 776655. Valid for 10 mins. PNR 4512345678." to "776655",
        "OTP for Aadhaar (XX1234) is 902112 (valid for 10 mins). To update Aadhaar, upload documents on myAadhaar portal. -UIDAI" to "902112",
        "Your UPI PIN setup OTP is 448812 for a/c XX7788. Do not share. -PhonePe" to "448812",
        "OTP is 382910 for NetBanking login. Valid till 10:45 PM. Do not share. -HDFC Bank" to "382910",
        "Your one time password is 902341 for card ending 4321" to "902341",
        "Dear Customer, use OTP 271828 to authorise UPI payment of Rs.499.00 to merchant@ybl from A/c XX4410. -Canara Bank" to "271828",
    ))

    @Test fun ecommerceAndApps() = check(listOf(
        "123987 is your Google Pay verification code." to "123987",
        "123456 is your Amazon OTP. Do not share it with anyone." to "123456",
        "Your order #4031234 is out for delivery. Share the delivery code 5821 with the agent." to "5821",
        "Your OTP for Zomato login is 5521. It is valid for 5 minutes." to "5521",
        "Use 7291 as Microsoft account security code" to "7291",
        "Your Apple ID Code is: 384756. Don't share it with anyone." to "384756",
        "Your Uber code: 2468. Never share this code. Reply STOP ALL to +1 415-237-0403 to unsubscribe." to "2468",
        "#482913 is your CRED verification code" to "482913",
        "Dear user, 4-digit OTP 9182 for your Ola ride." to "9182",
        "FB-482913 is your Facebook code" to "482913",
    ))

    @Test fun whatsAppAndSplitCodes() = check(listOf(
        "Your WhatsApp code: 123-456\n\nYou can also tap on this link to verify your phone: v.whatsapp.com/123456\n\nDon't share this code with others" to "123456",
        "Your login code is 123-456" to "123456",
        // Instagram and several Indian apps group six digits with a space.
        "123 456 is your Instagram code. Don't share it." to "123456",
        "Your verification code is 482 913" to "482913",
    ))

    @Test fun hindiAndMixed() = check(listOf(
        "प्रिय ग्राहक, आपका लॉगिन OTP 739201 है। इसे किसी से साझा न करें - SBI" to "739201",
        "आपका ओटीपी ४८२९१३ है" to "482913",
        "Aapka OTP hai 650912. Kisi ke saath share na karein. - Airtel" to "650912",
        "आपका सत्यापन कोड 2580 है।" to "2580",
        "আপনার OTP ৪৫৬৭৮৯" to "456789",
    ))

    @Test fun alphanumericCodes() = check(listOf(
        "Your verification code is AB12CD. Valid for 10 minutes." to "AB12CD",
        "Use code 7K9P2Q to sign in to Steam" to "7K9P2Q",
    ))

    @Test fun negatives() = check(listOf(
        "Rs 4,999 debited from your account XX1234. If not you, call 18001234567." to null,
        "Rs 4500 debited from a/c XX1234 on 12/11. Avl bal Rs 10,250.50" to null,
        "Your order 40312345 has been shipped" to null,
        "Your OTP has been sent to 9876543210" to null,
        "Call 1800-123-4567 for help with your OTP" to null,
        "Your OTP will be valid for 1440 mins" to null,
        "Your OTP request on 12/11/2026 was blocked" to null,
        "OTP generated at 10:45" to null,
        "Your PIN was changed on 07 Nov 2026" to null,
        "OTP for payment of INR 2500 to Merchant" to null,
        "OTP request for account ending 1234 failed" to null,
        "Login OTP link: https://bank.example.com/verify/839201" to null,
        "Dear Customer, INR 1,250.00 debited from A/c XX1234 on 07-11-26 to VPA abc@okicici. UPI Ref 431234567890. Not you? Call 18002586161 - SBI" to null,
        "Amount Rs.4999 for OTP txn" to null,
        "Your Jio number 9876543210 recharge of Rs 299 successful. Validity 28 days." to null,
        // Promo codes sit right next to "code" but are not one-time codes.
        "Use code SAVE50 to get 50% off on your next order" to null,
    ))

    @Test fun validForNMinutesIsNeverTheCode() {
        assertEquals("482913", OtpExtractor.extract("OTP valid for 10 mins: 482913", null)?.code)
        assertEquals("5521", OtpExtractor.extract("Valid for 1440 mins. Your OTP is 5521", null)?.code)
    }

    @Test fun senderNormalisation() {
        assertEquals("HDFCBK", OtpExtractor.normaliseSender("AX-HDFCBK"))
        assertEquals("SBIOTP", OtpExtractor.normaliseSender("VM-SBIOTP-S"))
        assertEquals("AMAZON", OtpExtractor.normaliseSender("JD-AMAZON-T"))
        assertEquals("+919876543210", OtpExtractor.normaliseSender("+919876543210"))
        assertEquals("HDFCBK", OtpExtractor.extract("123456 is your OTP", "AX-HDFCBK")?.source)
        assertEquals("", OtpExtractor.extract("123456 is your OTP", null)?.source)
    }

    @Test fun dedupeSameCodeWithin90sIsOneEvent() {
        val t = 1_000_000L
        assertTrue(OtpDedupe.isNew("918273", t))           // SMS receiver
        assertFalse(OtpDedupe.isNew("918273", t + 60_000))  // notification listener, same SMS
        assertTrue(OtpDedupe.isNew("918273", t + 91_000))   // a genuinely new OTP later
        assertTrue(OtpDedupe.isNew("111222", t + 91_000))   // a different code is never suppressed
    }
}
