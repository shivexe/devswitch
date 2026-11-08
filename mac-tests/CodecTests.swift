import CryptoKit
import Foundation

// Swift side of test-vectors/: same ciphertext from the same (key, nonce, aad, plaintext bytes), and every vector opens.
@MainActor func codecTests() {
    test("vectors: sealBytes with injected nonce equals Kotlin ciphertext+tag") {
        for name in ["poll-v2.json", "reply-v2.json", "file-chunk.json"] {
            let v = try vector(name)
            let key = hex(v["keyHex"] as! String)
            for c in [v] + (v["schemaCases"] as! [[String: Any]]) {
                let nonceData = hex(c["nonceHex"] as! String)
                let sealed = try SyncCrypto.sealBytes(Data((c["plaintextUtf8"] as! String).utf8), key: key, aad: c["aad"] as! String,
                                                      nonce: try AES.GCM.Nonce(data: nonceData))
                expect(sealed == nonceData + b64(c["ciphertextB64"] as! String) + b64(c["tagB64"] as! String), "\(name) \(c["name"] ?? "main")")
            }
        }
    }
    test("vectors: poll opens and decodes as Poll2") {
        let v = try vector("poll-v2.json"), key = hex(v["keyHex"] as! String), e = v["expect"] as! [String: Any]
        let envelope = Envelope(nonce: hex(v["nonceHex"] as! String).base64EncodedString(), ciphertext: v["ciphertextB64"] as! String, tag: v["tagB64"] as! String)
        let poll = try SyncCrypto.open(Poll2.self, envelope: envelope, key: key, aad: v["aad"] as! String)
        expect(poll.requestId == e["requestId"] as! String)
        expect(poll.sentAt == (e["sentAt"] as! NSNumber).int64Value)
        expect(poll.events?.map(\.id) == e["eventIds"] as? [String])
        expect(poll.events?.map(\.kind) == [.otp, .link, .notification])
        expect(poll.events?[2].string("text") == e["notificationText"] as? String)
        expect(poll.events?[1].string("url") == "https://example.com/a/b?c=1&d=%2F")
        expect(poll.status?.battery == 82 && poll.status?.sims == [SimCard(subId: 1, name: "Jio")] && poll.status?.listenerConnected == true)
        expect(poll.receipts?.map(\.id) == e["receiptIds"] as? [String])
    }
    test("vectors: poll schema cases") {
        let v = try vector("poll-v2.json"), key = hex(v["keyHex"] as! String)
        for c in v["schemaCases"] as! [[String: Any]] {
            let envelope = Envelope(nonce: hex(c["nonceHex"] as! String).base64EncodedString(), ciphertext: c["ciphertextB64"] as! String, tag: c["tagB64"] as! String)
            let poll = try SyncCrypto.open(Poll2.self, envelope: envelope, key: key, aad: c["aad"] as! String)
            switch c["name"] as! String {
            case "oversizeEvents": expect(poll.events?.count == 33)
            case "unknownEventType": expect(poll.events?.first?.kind == .unknown("teleport") && poll.events?.first?.string("dest") == "mars")
            case "duplicateEventIds": expect(poll.events?.map(\.id) == ["d1", "d1"])
            case "controlCharsInTitle": expect(poll.events?.first?.string("title") == "ABC\nD", "got \(poll.events?.first?.string("title") ?? "nil")")
            default: expect(false, "unknown case")
            }
        }
    }
    test("vectors: reply opens with the fields the phone reads") {
        let v = try vector("reply-v2.json"), key = hex(v["keyHex"] as! String), e = v["expect"] as! [String: Any]
        let envelope = Envelope(nonce: hex(v["nonceHex"] as! String).base64EncodedString(), ciphertext: v["ciphertextB64"] as! String, tag: v["tagB64"] as! String)
        let reply = try SyncCrypto.open(JSONValue.self, envelope: envelope, key: key, aad: v["aad"] as! String)
        guard case .object(let o) = reply, case .array(let commands)? = o["commands"] else { expect(false, "shape"); return }
        expect(o["ack"] == .array((e["ack"] as! [String]).map(JSONValue.string)))
        expect(o["nextPollMs"] == .number(500))
        expect(commands.compactMap { if case .object(let c) = $0, case .string(let a)? = c["a"] { return a }; return nil } == e["actions"] as! [String])
        if case .object(let sms) = commands[1] { expect(sms["body"] == .string(e["smsBody"] as! String) && sms["subId"] == .number(1)) }
    }
    test("vectors: Swift encodes Reply2 that the same decoder reads back") {
        // JSON text differs from org.json (key order, \/ escaping); compare decoded values, never bytes.
        let key = Data(repeating: 9, count: 32)
        let command = OutgoingCommand("sendSms", ["to": .string("+919876543210"), "body": .string("a/b रास्ते"), "subId": .number(2)])
        let reply = Reply2(requestId: "r", desktopIPv6: nil, ack: ["e1"], nextPollMs: 0, needIcons: [], commands: [command], needStatus: nil)
        let opened = try SyncCrypto.open(JSONValue.self, envelope: try SyncCrypto.seal(reply, key: key, aad: "a"), key: key, aad: "a")
        guard case .object(let o) = opened, case .array(let cs)? = o["commands"], case .object(let c) = cs[0] else { expect(false); return }
        expect(c["a"] == .string("sendSms") && c["body"] == .string("a/b रास्ते") && c["subId"] == .number(2) && c["id"] == .string(command.id))
        expect(c["expiresAt"] == .number(Double(command.expiresAt)))
    }
    test("vectors: file chunk opens from raw framing") {
        let v = try vector("file-chunk.json"), key = hex(v["keyHex"] as! String)
        let plain = try SyncCrypto.openBytes(b64(v["framedB64"] as! String), key: key, aad: v["aad"] as! String)
        expect(String(data: plain, encoding: .utf8) == v["plaintextUtf8"] as? String)
    }
    test("vectors: negatives fail authentication") {
        for name in ["poll-v2.json", "reply-v2.json"] {
            let v = try vector(name), key = hex(v["keyHex"] as! String)
            for n in v["negative"] as! [[String: Any]] {
                let envelope = Envelope(nonce: hex(v["nonceHex"] as! String).base64EncodedString(),
                                        ciphertext: n["ciphertextB64"] as? String ?? v["ciphertextB64"] as! String, tag: n["tagB64"] as? String ?? v["tagB64"] as! String)
                expectThrows("\(name) \(n["name"]!)") { try SyncCrypto.open(JSONValue.self, envelope: envelope, key: key, aad: n["aad"] as? String ?? v["aad"] as! String) }
            }
        }
        let v = try vector("file-chunk.json"), key = hex(v["keyHex"] as! String), framed = b64(v["framedB64"] as! String)
        for n in v["negative"] as! [[String: Any]] {
            var body = framed
            if let f = n["framedB64"] as? String { body = b64(f) }
            if let c = n["ciphertextB64"] as? String { body = framed.prefix(12) + b64(c) + b64(v["tagB64"] as! String) }
            if let t = n["tagB64"] as? String { body = framed.prefix(12) + b64(v["ciphertextB64"] as! String) + b64(t) }
            expectThrows("file \(n["name"]!)") { try SyncCrypto.openBytes(body, key: key, aad: n["aad"] as? String ?? v["aad"] as! String) }
        }
    }
    test("codec: random nonces differ, injected nonce is verbatim, bad sizes rejected") {
        let key = Data(repeating: 1, count: 32)
        let a = try SyncCrypto.seal(["x": 1], key: key, aad: "a"), b = try SyncCrypto.seal(["x": 1], key: key, aad: "a")
        expect(a.nonce != b.nonce)
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 7, count: 12))
        expect(try SyncCrypto.seal(["x": 1], key: key, aad: "a", nonce: nonce).nonce == Data(repeating: 7, count: 12).base64EncodedString())
        expectThrows("short key") { try SyncCrypto.seal(["x": 1], key: Data(count: 16), aad: "a") }
        expectThrows("27-byte frame") { try SyncCrypto.openBytes(Data(count: 27), key: key, aad: "a") }
        var bad = a; bad.tag = Data(count: 12).base64EncodedString()
        expectThrows("12-byte tag") { try SyncCrypto.open([String: Int].self, envelope: bad, key: key, aad: "a") }
        bad = a; bad.nonce = Data(count: 16).base64EncodedString()
        expectThrows("16-byte nonce") { try SyncCrypto.open([String: Int].self, envelope: bad, key: key, aad: "a") }
        // Envelope ciphertext cap is 64 KB.
        let big = try SyncCrypto.seal(String(repeating: "x", count: 64 * 1024), key: key, aad: "a")
        expectThrows("ciphertext over 64 KB") { try SyncCrypto.open(String.self, envelope: big, key: key, aad: "a") }
    }
    test("protocol: display strings and command TTLs") {
        expect(displayString("a\u{0}b\u{1b}c\u{7f}\nd\te", max: 100) == "abc\nd\te")
        expect(displayString(String(repeating: "x", count: 300), max: 120).count == 120)
        let now = Int64(Date().timeIntervalSince1970)
        expect(abs(OutgoingCommand("ring").expiresAt - now - 60) <= 1)
        expect(abs(OutgoingCommand("declineCall").expiresAt - now - 15) <= 1)
        expect(abs(OutgoingCommand("sendSms").expiresAt - now - 120) <= 1)
        // Fields cannot override id/a/expiresAt on the wire.
        let c = OutgoingCommand("ring", ["id": .string("spoof"), "a": .string("x")])
        let o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        expect(o["id"] as? String == c.id && o["a"] as? String == "ring")
    }
}
