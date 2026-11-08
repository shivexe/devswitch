import Darwin
import Foundation

/// Native-messaging host mode: Helium launches this binary with the extension origin as argv[1].
/// It relays length-prefixed JSON from the extension to the running app's `ExtensionSocket`
/// as newline-delimited JSON, and relays replies and pushes back. It holds no codes or keys.
enum NativeHost {
    static let extensionID = "bhkomgkoojgnpilpljibbhccogoiodkk"
    static let hostName = "dev.notsg.devswitch"
    private static let origin = "chrome-extension://\(extensionID)/"
    private static let outputLock = NSLock()

    static var isHostInvocation: Bool {
        CommandLine.arguments.dropFirst().first?.hasPrefix("chrome-extension://") == true
    }

    static func run() -> Int32 {
        guard CommandLine.arguments.dropFirst().first == origin else { return 1 }
        signal(SIGPIPE, SIG_IGN)
        var app: Int32 = -1
        while let message = readMessage() {
            guard let request = (try? JSONSerialization.jsonObject(with: Data(message))) as? [String: Any] else { return 1 }
            if app < 0 { app = connectToApp() }
            if app >= 0, writeAll(app, message + [0x0A]) { continue }
            if app >= 0 { close(app); app = -1 }
            // The app is not running: answer so the extension does not wait for its timeout.
            if let reply = try? JSONSerialization.data(withJSONObject: ["id": request["id"] ?? NSNull(), "otp": NSNull(), "error": "unavailable"]) {
                writeMessage(reply)
            }
        }
        return 0
    }

    /// Copies the bundled extension to a stable folder for Helium's "Load unpacked".
    static func installExtensionFolder() throws -> URL {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("extension") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let target = ExtensionSocket.directory.appendingPathComponent("extension", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: ExtensionSocket.directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: bundled, to: target)
        return target
    }

    /// Registers this executable as Helium's native-messaging host for the extension.
    static func installHostManifest(extensionID: String) throws {
        guard let executable = Bundle.main.executablePath else { throw CocoaError(.fileNoSuchFile) }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/net.imput.helium/NativeMessagingHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "DevSwitch",
            "path": executable,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: directory.appendingPathComponent("\(hostName).json"), options: .atomic)
    }

    private static func connectToApp() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = ExtensionSocket.address() else { return -1 }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { close(fd); return -1 }
        Thread.detachNewThread { relayReplies(from: fd) }
        return fd
    }

    /// App → extension: one JSON object per line becomes one native message.
    private static func relayReplies(from fd: Int32) {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return }
            buffer += chunk[0..<count]
            while let newline = buffer.firstIndex(of: 0x0A) {
                writeMessage(Data(buffer[..<newline]))
                buffer.removeSubrange(...newline)
            }
            if buffer.count > 1_000_000 { return }
        }
    }

    /// Extension → host: 4-byte native-endian length, then UTF-8 JSON. Requests are small.
    private static func readMessage() -> [UInt8]? {
        guard let header = readExactly(4) else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard length > 0, length <= 4096 else { return nil }
        return readExactly(Int(length))
    }

    private static func readExactly(_ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let read = bytes.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress! + offset, count - offset) }
            guard read > 0 else { return nil }
            offset += read
        }
        return bytes
    }

    private static func writeMessage(_ message: Data) {
        guard message.count <= 1_000_000 else { return }
        var length = UInt32(message.count)
        outputLock.lock()
        defer { outputLock.unlock() }
        _ = writeAll(STDOUT_FILENO, withUnsafeBytes(of: &length) { [UInt8]($0) } + [UInt8](message))
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }
}
