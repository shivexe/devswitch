import Darwin
import Foundation
import Security

/// What the extension socket needs from the app's OTP store. `OtpVault` conforms to this.
@MainActor protocol OtpSource: AnyObject {
    func current() -> (code: String, source: String, domain: String?)?
    func consume()
}

/// Serves the latest phone OTP to the native-messaging host (`NativeHost`) over a Unix socket.
/// Only a peer running this same signed executable, as this user, is accepted.
@MainActor final class ExtensionSocket {
    nonisolated static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DevSwitch", isDirectory: true)
    }
    nonisolated static var path: String { directory.appendingPathComponent("ext.sock").path }

    private final class Client {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        var requests: [Date] = []
        var subscribedUntil = Date.distantPast
        init(fd: Int32, source: DispatchSourceRead) { self.fd = fd; self.source = source }
    }

    private weak var vault: OtpSource?
    private var listener: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]

    func start(vault: OtpSource) {
        self.vault = vault
        guard listener == nil else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        chmod(Self.directory.path, 0o700)
        unlink(Self.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = Self.address() else { return }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(Self.path, 0o600) == 0, listen(fd, 4) == 0 else { close(fd); return }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept(fd) } }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
    }

    /// Call when a new code arrives so frames waiting on a focused OTP field get it.
    func otpArrived() {
        guard let otp = vault?.current() else { return }
        for client in clients.values where client.subscribedUntil > Date() {
            client.subscribedUntil = .distantPast
            send(["push": true, "otp": Self.json(otp)], to: client)
        }
    }

    nonisolated static func address() -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    private static func json(_ otp: (code: String, source: String, domain: String?)) -> [String: Any] {
        ["code": otp.code, "source": otp.source, "domain": otp.domain ?? NSNull()]
    }

    private func accept(_ listenFD: Int32) {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        guard Self.peerIsSelf(fd) else { close(fd); return }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        let client = Client(fd: fd, source: source)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read(client) } }
        source.setCancelHandler { close(fd) }
        clients[fd] = client
        source.resume()
    }

    private func drop(_ client: Client) {
        clients[client.fd] = nil
        client.source.cancel()
    }

    private func read(_ client: Client) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(client.fd, &chunk, chunk.count)
        guard count > 0 else { return drop(client) }
        client.buffer.append(contentsOf: chunk[0..<count])
        guard client.buffer.count <= 4096 else { return drop(client) }
        while let newline = client.buffer.firstIndex(of: 0x0A) {
            let line = client.buffer[client.buffer.startIndex..<newline]
            client.buffer.removeSubrange(client.buffer.startIndex...newline)
            let now = Date()
            client.requests = client.requests.filter { now.timeIntervalSince($0) < 10 } + [now]
            guard client.requests.count <= 30,
                  let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { return drop(client) }
            handle(request, from: client)
        }
    }

    private func handle(_ request: [String: Any], from client: Client) {
        var reply: [String: Any] = ["id": request["id"] ?? NSNull()]
        switch request["type"] as? String {
        case "getOtp": reply["otp"] = vault?.current().map(Self.json) ?? NSNull()
        case "consumed": vault?.consume(); reply["ok"] = true
        case "subscribe": client.subscribedUntil = Date().addingTimeInterval(60); reply["ok"] = true
        default: reply["error"] = "unsupported"
        }
        send(reply, to: client)
    }

    private func send(_ message: [String: Any], to client: Client) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        let written = data.withUnsafeBytes { write(client.fd, $0.baseAddress, $0.count) }
        if written != data.count { drop(client) }
    }

    /// The peer must be this user and pass this app's own designated requirement.
    private static func peerIsSelf(_ fd: Int32) -> Bool {
        var uid = uid_t(), gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        var me: SecCode?, staticMe: SecStaticCode?, requirement: SecRequirement?, peer: SecCode?
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopyDesignatedRequirement(staticMe, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &peer) == errSecSuccess,
              let peer
        else { return false }
        return SecCodeCheckValidity(peer, [], requirement) == errSecSuccess
    }
}
