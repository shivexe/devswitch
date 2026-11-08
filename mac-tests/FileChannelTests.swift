import Foundation

// FileChannel chunk bounds on both directions. Nothing is completed, so ~/Downloads gets no file.
@MainActor func fileChannelTests() {
    let chunk = FileChannel.chunkSize
    test("file: Mac→phone /get serves sealed chunks with total/final in the AAD and refuses out-of-range indexes") {
        let p = FakePhone()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("devswitch-test-\(UUID().uuidString).bin")
        try Data((0..<(2 * chunk + 10)).map { UInt8($0 & 0xff) }).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let id = try p.controller.files.offerToPhone(file: source)
        spin(3) { p.controller.queue.contains { $0.a == "fileOffer" } }
        expect(p.controller.queue.contains { $0.a == "fileOffer" && $0.fields["transferId"] == .string(id) }, "fileOffer queued after hashing")
        expectThrows("one active transfer") { try p.controller.files.offerToPhone(file: source) }
        @MainActor func get(_ path: String) -> HTTPResponse { p.controller.files.handle(HTTPRequest(path: path, body: Data())) }
        let base = "devswitch/file/v1/\(p.phone.id)/\(id)"
        let first = get("/v2/file/\(id)/0/get")
        expect(first.status == 200 && first.contentType == "application/octet-stream")
        expect(try SyncCrypto.openBytes(first.body, key: p.phone.key, aad: "\(base)/0/3/0").count == chunk)
        let last = get("/v2/file/\(id)/2/get")
        expect(try SyncCrypto.openBytes(last.body, key: p.phone.key, aad: "\(base)/2/3/1").count == 10)
        expectThrows("final flag is bound") { try SyncCrypto.openBytes(last.body, key: p.phone.key, aad: "\(base)/2/3/0") }
        expect(first.body.count <= chunk + 28)
        expect(get("/v2/file/\(id)/3/get").status == 400, "index == total")
        expect(get("/v2/file/\(id)/-1/get").status == 400, "negative index")
        expect(get("/v2/file/\(id)/000001/get").status == 400, "index over 5 chars")
        expect(get("/v2/file/\(id)/x/get").status == 400)
        expect(get("/v2/file/\(id)/0/put").status == 400)
        expect(get("/v2/file/\(id)/0").status == 403, "upload into a Mac→phone transfer")
        expect(get("/v2/file/\(UUID().uuidString.lowercased())/0/get").status == 403, "unknown transfer")
        expect(get("/v2/file/\(id)/status").status == 200)
        p.controller.files.fail(p.controller.files.active!)
    }
    test("file: phone→Mac chunks must have the exact length and AAD; partial file is removed") {
        let p = FakePhone()
        let id = UUID().uuidString.lowercased()
        let size = chunk + 100
        let raw = try JSONSerialization.data(withJSONObject: ["id": "f", "t": "fileOffer", "transferId": id, "name": "../../evil\n.txt",
                                                               "size": size, "sha256": String(repeating: "a", count: 64), "chunkSize": chunk])
        let offer = FileOfferEvent(try JSONDecoder().decode(PhoneEvent.self, from: raw))!
        p.controller.files.accept(offer: offer)
        expect(p.controller.queue.last?.a == "fileAccept")
        let part = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(".\(id).part")
        expect(FileManager.default.fileExists(atPath: part.path))
        let base = "devswitch/file/v1/\(p.phone.id)/\(id)"
        @MainActor func put(_ index: Int, _ plain: Data, _ aad: String) throws -> Int {
            p.controller.files.handle(HTTPRequest(path: "/v2/file/\(id)/\(index)", body: try SyncCrypto.sealBytes(plain, key: p.phone.key, aad: aad))).status
        }
        expect(try put(1, Data(count: 99), "\(base)/1/2/1") == 400, "short last chunk")
        expect(try put(1, Data(count: 101), "\(base)/1/2/1") == 400, "long last chunk")
        expect(try put(1, Data(count: 100), "\(base)/1/2/0") == 400, "final flag wrong")
        expect(try put(1, Data(count: 100), "\(base)/1/3/1") == 400, "total wrong")
        expect(try put(0, Data(count: chunk - 1), "\(base)/0/2/0") == 400, "short middle chunk")
        expect(try put(2, Data(count: 1), "\(base)/2/2/1") == 400, "index past total")
        expect(try put(0, Data(count: chunk), "\(base)/0/2/0") == 200)
        expect(try put(0, Data(count: chunk), "\(base)/0/2/0") == 200, "a resent chunk is accepted once")
        expect(p.controller.files.handle(HTTPRequest(path: "/v2/file/\(id)/0/get", body: Data())).status == 403, "download from an upload")
        p.controller.files.fail(p.controller.files.active!)
        spin(1) { !FileManager.default.fileExists(atPath: part.path) }
        expect(!FileManager.default.fileExists(atPath: part.path), ".part removed on failure")
        expect(FileChannel.safeName("../../evil\n.txt") == "____evil .txt" && FileChannel.safeName("..") == "_" && FileChannel.safeName(".") == "File from phone")
        let bad = FileOfferEvent(try JSONDecoder().decode(PhoneEvent.self, from: try JSONSerialization.data(withJSONObject: [
            "id": "g", "t": "fileOffer", "transferId": UUID().uuidString, "name": "a", "size": 1, "sha256": String(repeating: "a", count: 64), "chunkSize": 1024])))!
        p.controller.files.accept(offer: bad)
        expect(p.controller.queue.last?.a == "fileDecline", "a non-256 KiB chunk size is declined")
    }
}
