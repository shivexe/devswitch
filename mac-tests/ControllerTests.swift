import CryptoKit
import Foundation

// Controller v2 poll handling, driven through its (access-control-disabled) handle(_:), never over the network.
@MainActor final class FakePhone {
    let controller: Controller
    let phone = Phone(id: UUID().uuidString.lowercased(), name: "Test phone", key: SyncCrypto.random(32))
    init() {
        controller = Controller()
        controller.phone = phone
    }
    /// One sealed /v2/poll. Returns the HTTP status and, for 200, the opened reply.
    func poll(events: [[String: Any]] = [], receipts: [[String: Any]] = [], status: Bool = true, requestId: String? = nil,
              sentAt: Int64? = nil, aad: String? = nil, unthrottled: Bool = true) throws -> (Int, [String: Any]) {
        if unthrottled { controller.lastPoll = .distantPast }
        var body: [String: Any] = ["requestId": requestId ?? SyncCrypto.random(32).base64EncodedString(),
                                   "sentAt": sentAt ?? Int64(Date().timeIntervalSince1970), "events": events, "receipts": receipts]
        if status { body["status"] = ["developer": false, "usb": false, "wifi": false, "permission": true, "battery": 50] }
        let plain = try JSONSerialization.data(withJSONObject: body)
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: phone.key), authenticating: Data((aad ?? "devswitch/poll/v2/\(phone.id)").utf8))
        let envelope = Envelope(nonce: box.nonce.withUnsafeBytes { Data($0).base64EncodedString() }, ciphertext: box.ciphertext.base64EncodedString(),
                                tag: box.tag.base64EncodedString(), deviceId: phone.id)
        let response = controller.handle(HTTPRequest(path: "/v2/poll", body: try JSONEncoder().encode(envelope)))
        guard response.status == 200 else { return (response.status, (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]) }
        let reply = try JSONDecoder().decode(Envelope.self, from: response.body)
        let opened = try AES.GCM.open(AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: b64(reply.nonce)), ciphertext: b64(reply.ciphertext), tag: b64(reply.tag)),
                                      using: SymmetricKey(data: phone.key), authenticating: Data("devswitch/reply/v2/\(phone.id)".utf8))
        return (200, try JSONSerialization.jsonObject(with: opened) as! [String: Any])
    }
}
private func ids(_ reply: [String: Any]) -> [String] { (reply["commands"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
private func event(_ id: String, _ t: String = "link", _ extra: [String: Any] = [:]) -> [String: Any] {
    ["id": id, "t": t, "at": Int64(Date().timeIntervalSince1970), "url": "https://example.com"].merging(extra) { $1 }
}

@MainActor func controllerTests() {
    test("replay: a reused requestId gets 409; fresh ids keep working") {
        let p = FakePhone()
        let id = SyncCrypto.random(32).base64EncodedString()
        expect(try p.poll(requestId: id).0 == 200)
        expect(try p.poll(requestId: id).0 == 409)
        expect(try p.poll().0 == 200)
    }
    test("replay: 600 polls in a burst are all accepted (old cap was 500)") {
        let p = FakePhone()
        var statuses: [Int: Int] = [:]
        for _ in 0..<600 { statuses[try p.poll().0, default: 0] += 1 }
        expect(statuses == [200: 600], "\(statuses)")
    }
    test("replay: a full cache evicts its oldest id instead of refusing; the evicted id stays refused") {
        let p = FakePhone()
        let now = Int64(Date().timeIntervalSince1970)
        let old = SyncCrypto.random(32).base64EncodedString()
        expect(try p.poll(requestId: old, sentAt: now - 5).0 == 200)
        for i in 0..<2047 { p.controller.seen["seed-\(i)"] = (Date(), now) }
        expect(try p.poll().0 == 200, "full cache")
        expect(p.controller.seen.count == 2048 && p.controller.seen[old] == nil, "oldest evicted")
        expect(try p.poll(requestId: old, sentAt: now - 5).0 == 409, "replay of the evicted id")
        for key in Array(p.controller.seen.keys) { p.controller.seen[key]?.at = Date().addingTimeInterval(-121) }
        expect(try p.poll().0 == 200 && p.controller.seen.count == 1, "entries older than 120 s are dropped")
    }
    test("poll: clock skew, wrong AAD, bad requestId and oversize lists are refused") {
        let p = FakePhone()
        expect(try p.poll(sentAt: Int64(Date().timeIntervalSince1970) - 31).0 == 400)
        expect(try p.poll(sentAt: Int64(Date().timeIntervalSince1970) + 31).0 == 400)
        expect(try p.poll(sentAt: Int64(Date().timeIntervalSince1970) - 29).0 == 200)
        expect(try p.poll(aad: "devswitch/poll/v1/\(p.phone.id)").0 == 400, "v1 AAD on /v2/poll")
        expect(try p.poll(aad: "devswitch/reply/v2/\(p.phone.id)").0 == 400, "reply AAD")
        expect(try p.poll(requestId: SyncCrypto.random(16).base64EncodedString()).0 == 400, "16-byte requestId")
        expect(try p.poll(events: (0..<33).map { event("e\($0)") }).0 == 400, "33 events")
        expect(try p.poll(events: (0..<32).map { event("f\($0)") }).0 == 200, "32 events")
        expect(try p.poll(receipts: (0..<17).map { ["id": "r\($0)", "ok": true, "message": ""] }).0 == 400, "17 receipts")
        let other = Envelope(nonce: "", ciphertext: "", tag: "", deviceId: UUID().uuidString)
        expect(p.controller.handle(HTTPRequest(path: "/v2/poll", body: try JSONEncoder().encode(other))).status == 403, "unknown device")
    }
    test("events: every id is acked, each id is routed once, unknown types are acked too") {
        EventRouter.routed = []
        let p = FakePhone()
        let (s1, r1) = try p.poll(events: [event("a"), event("b", "teleport")])
        expect(s1 == 200 && r1["ack"] as? [String] == ["a", "b"])
        let (_, r2) = try p.poll(events: [event("a")])
        expect(r2["ack"] as? [String] == ["a"], "a resent event is acked again")
        expect(EventRouter.routed.map(\.id) == ["a", "b"], "routed \(EventRouter.routed.map(\.id))")
        expect(EventRouter.routed.last?.kind == .unknown("teleport"))
    }
    test("queue: at most 16 queued, oldest non-call dropped, 16 per reply") {
        let p = FakePhone()
        let calls = [OutgoingCommand("declineCall"), OutgoingCommand("silenceCall")]
        calls.forEach(p.controller.enqueue)
        let rest = (0..<20).map { OutgoingCommand("ring", ["n": .number(Double($0))]) }
        rest.forEach(p.controller.enqueue)
        expect(p.controller.queue.count == 16)
        expect(calls.allSatisfy { c in p.controller.queue.contains { $0.id == c.id } }, "call commands survive")
        expect(p.controller.queue.last?.id == rest.last?.id)
        let (_, reply) = try p.poll()
        expect(ids(reply).count == 16 && ids(reply) == p.controller.queue.map(\.id))
        expect(reply["nextPollMs"] as? Int == 0, "fresh commands ask for an immediate poll")
        let (_, again) = try p.poll()
        expect(again["nextPollMs"] as? Int == 500, "already delivered, still queued → hot")
    }
    test("receipts: matching receipt completes the command once; unknown ids are ignored") {
        let p = FakePhone()
        var got: [(String, Bool)] = []
        p.controller.onReceipt = { id, r in got.append((id, r.ok)) }
        let ring = OutgoingCommand("ring"), sms = OutgoingCommand("sendSms")
        p.controller.enqueue(ring); p.controller.enqueue(sms)
        _ = try p.poll()
        let (_, reply) = try p.poll(receipts: [["id": ring.id, "ok": true, "message": ""], ["id": "nope", "ok": true, "message": ""]])
        expect(got.count == 1 && got.first?.0 == ring.id && got.first?.1 == true)
        expect(ids(reply) == [sms.id])
        _ = try p.poll(receipts: [["id": ring.id, "ok": true, "message": ""]])
        expect(got.count == 1, "duplicate receipt is not reported twice")
        _ = try p.poll(receipts: [["id": sms.id, "ok": false, "message": "No SIM"]])
        expect(got.last?.0 == sms.id && got.last?.1 == false && p.controller.lastReceipt?.message == "No SIM")
        let (_, idle) = try p.poll()
        expect(ids(idle).isEmpty && idle["nextPollMs"] as? Int == 2000, "empty queue → 2000 ms")
    }
    test("ttl: expired commands are never sent; call TTL is 15 s, ring 60 s") {
        let p = FakePhone()
        let stale = OutgoingCommand("ring", ttl: -1), live = OutgoingCommand("ring")
        p.controller.enqueue(stale); p.controller.enqueue(live)
        let (_, reply) = try p.poll()
        expect(ids(reply) == [live.id] && !p.controller.queue.contains { $0.id == stale.id })
        let now = Int64(Date().timeIntervalSince1970)
        expect(abs(OutgoingCommand("declineCall").expiresAt - now - 15) <= 1 && abs(live.expiresAt - now - 60) <= 1)
    }
    test("rate: early empty polls get 429; polls with events always pass; needStatus when unknown") {
        let p = FakePhone()
        let (_, first) = try p.poll(status: false)
        expect(first["needStatus"] as? Bool == true)
        expect(try p.poll(unthrottled: false).0 == 429, "empty poll 0 ms after a 2000 ms ask")
        expect(try p.poll(events: [event("x")], unthrottled: false).0 == 200, "event poll is never throttled")
        p.controller.requestHotPolling(for: 30)
        let (_, hot) = try p.poll()
        expect(hot["nextPollMs"] as? Int == 500 && hot["needStatus"] == nil)
    }
}
