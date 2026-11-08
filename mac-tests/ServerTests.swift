import Foundation

// HTTPServer framing limits (parse) and the live listener's connection cap and 10 s deadline.
private func request(_ path: String, type: String? = "application/json", length: Int? = nil, body: Int, extra: [String] = [], method: String = "POST") -> Data {
    var lines = ["\(method) \(path) HTTP/1.1", "Host: x"]
    if let type { lines.append("Content-Type: \(type)") }
    lines.append("Content-Length: \(length ?? body)")
    lines += extra
    return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + Data(repeating: 0x61, count: body)
}
@MainActor private func parses(_ data: Data) -> Bool { (try? HTTPServer.parse(data)).flatMap { $0 } != nil }
@MainActor private func rejects(_ data: Data) -> Bool { do { _ = try HTTPServer.parse(data); return false } catch { return true } }
@MainActor private func waits(_ data: Data) -> Bool { do { return try HTTPServer.parse(data) == nil } catch { return false } }

@MainActor func serverTests() {
    test("http: JSON body limit is 32 KB on /v1 and /v2/poll") {
        expect(parses(request("/v2/poll", body: 32 * 1024)))
        expect(rejects(request("/v2/poll", body: 32 * 1024 + 1)))
        expect(parses(request("/v1/poll", body: 32 * 1024)))
        expect(rejects(request("/v1/poll", body: 32 * 1024 + 1)))
        expect(try HTTPServer.parse(request("/v2/poll", body: 10))?.body.count == 10)
    }
    test("http: file chunks are octet-stream up to 256 KiB + 28 B; status stays JSON") {
        let max = 256 * 1024 + 28
        expect(parses(request("/v2/file/t/0", type: "application/octet-stream", body: max)))
        expect(rejects(request("/v2/file/t/0", type: "application/octet-stream", body: max + 1)))
        expect(rejects(request("/v2/file/t/0", type: "application/json", body: 10)), "JSON on a chunk path")
        expect(rejects(request("/v2/poll", type: "application/octet-stream", body: 10)), "octet-stream on poll")
        expect(parses(request("/v2/file/t/status", body: 10)))
        expect(rejects(request("/v2/file/t/status", type: "application/octet-stream", body: 10)))
        expect(parses(request("/v2/poll", type: "application/json; charset=utf-8", body: 2)))
    }
    test("http: bad headers are rejected") {
        expect(rejects(request("/v2/poll", body: 2, extra: ["X-A: 1", "x-a: 2"])), "duplicate header")
        expect(rejects(request("/v2/poll", body: 2, extra: ["Content-Length: 2"])), "duplicate content-length")
        expect(rejects(request("/v2/poll", body: 2, extra: [" folded: 1"])), "obs-fold")
        expect(rejects(request("/v2/poll", body: 2, extra: ["no-colon"])))
        expect(rejects(request("/v2/poll", body: 2, extra: ["Transfer-Encoding: chunked"])))
        expect(rejects(request("/v2/poll", type: nil, body: 2)), "missing content-type")
        expect(rejects(request("/v2/poll", type: "text/plain", body: 2)))
        for bad in ["+2", "-1", "0x2", "1_0", "12345678", ""] {
            let data = Data("POST /v2/poll HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(bad)\r\n\r\n{}".utf8)
            expect(rejects(data), "content-length \(bad)")
        }
        expect(rejects(request("/v2/poll", body: 2, method: "GET")))
        expect(rejects(Data("POST v2/poll HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n".utf8)), "relative path")
        expect(rejects(request("/" + String(repeating: "a", count: 160), body: 0)), "path over 160")
        expect(rejects(request("/v2/poll", length: 2, body: 3)), "body longer than content-length")
    }
    test("http: incomplete requests wait, oversize ones fail early") {
        expect(waits(request("/v2/poll", length: 10, body: 5)), "partial body → nil")
        expect(waits(Data("POST /v2/poll HTTP/1.1\r\nContent-".utf8)), "partial headers → nil")
        expect(rejects(Data(repeating: 0x61, count: 16 * 1024 + 1)), "16 KB of headers without a terminator")
        expect(rejects(request("/v2/poll", body: 0, extra: ["X: " + String(repeating: "a", count: 16 * 1024)])), "header block over 16 KB")
        expect(rejects(Data(repeating: 0x61, count: 256 * 1024 + 28 + 16 * 1024 + 1)), "total buffer cap")
    }
    test("http: live listener answers 400 on oversize, caps 16 connections, drops slow clients at 10 s") {
        let port: UInt16 = 45993
        var hits = 0
        let server = HTTPServer { _ in hits += 1; return HTTPResponse(200) }
        var ready = false, failed = false
        server.ready = { ready = true }
        server.failed = { _ in failed = true }
        try server.start(port: port)
        spin(3) { ready || failed }
        guard ready else { expect(false, "listener on \(port) did not start"); return }
        defer { server.stop() }

        let oversize = Client(port)
        oversize.send(request("/v2/poll", length: 40_000, body: 0))
        spin(2) { oversize.closed }
        expect(oversize.received.starts(with: Data("HTTP/1.1 400".utf8)), "oversize → 400, got \(String(decoding: oversize.received.prefix(20), as: UTF8.self))")

        let ok = Client(port)
        ok.send(request("/v2/poll", body: 2))
        spin(2) { ok.closed }
        expect(ok.received.starts(with: Data("HTTP/1.1 200".utf8)) && hits == 1)

        // 16 slow clients hold every slot; the 17th is closed at once without a response.
        let start = Date()
        let slow = (0..<16).map { _ in Client(port) }
        slow.forEach { $0.send(Data("POST /v2/poll HTTP/1.1\r\nContent-".utf8)) }
        spin(1)
        let extra = Client(port)
        spin(2) { extra.closed }
        expect(extra.closed && extra.received.isEmpty, "17th connection refused")
        expect(slow.allSatisfy { !$0.closed }, "slow clients still open before the deadline")
        spin(13) { slow.allSatisfy(\.closed) }
        let elapsed = Date().timeIntervalSince(start)
        expect(slow.allSatisfy(\.closed) && elapsed > 9 && elapsed < 12.5, "slow clients closed after \(elapsed) s")
        expect(slow.allSatisfy { $0.received.isEmpty }, "no response to an incomplete request")
        expect(hits == 1)
    }
}

/// A blocking BSD-socket client on its own thread, so the server's main run loop keeps spinning.
final class Client: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var _received = Data(), _closed = false
    var received: Data { lock.withLock { _received } }
    var closed: Bool { lock.withLock { _closed } }
    init(_ port: UInt16) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { _closed = true; return }
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { break }
                lock.withLock { _received.append(contentsOf: buffer[0..<n]) }
            }
            lock.withLock { _closed = true }
            close(fd)
        }
    }
    func send(_ data: Data) { _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) } }
}
