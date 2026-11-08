import Foundation
import Network

private struct CommandResult { let code: Int32; let output: String }

// Arguments are passed directly to the executable, never through a shell.
private func adbRun(_ arguments: [String], input: String? = nil, timeout: TimeInterval = 12) async throws -> CommandResult {
    try await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try Dependencies.locate("adb"))
        process.arguments = arguments
        let output = Pipe(); let stdin = Pipe()
        process.standardOutput = output; process.standardError = output; process.standardInput = stdin
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); watchdog.cancel()
        return CommandResult(code: process.terminationStatus, output: String(decoding: data.prefix(65536), as: UTF8.self))
    }.value
}

@MainActor
final class ScreenControl: ObservableObject {
    @Published var needsPairingAddress = false
    @Published var trustLost = false
    @Published var qrPayload: String?
    @Published var busy = false
    @Published var running = false
    @Published var message = ""
    @Published private(set) var pairedPhoneID: String?
    private var serial = ""
    private var lastEndpoint = ""
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var process: Process?
    // Set when Control phone turned development on; ending the session turns it back off.
    private weak var enabledBy: Controller?
    private let defaults = UserDefaults.standard
    private let discovery = BonjourDiscovery(type: "_adb-tls-connect._tcp.")
    private let pairing = BonjourDiscovery(type: "_adb-tls-pairing._tcp.")

    init() {
        pairedPhoneID = defaults.string(forKey: "screen.phoneID")
        serial = defaults.string(forKey: "screen.serial") ?? ""
        lastEndpoint = defaults.string(forKey: "screen.endpoint") ?? ""
    }
    func isPaired(_ phoneID: String?) -> Bool { phoneID != nil && pairedPhoneID == phoneID && !serial.isEmpty }
    nonisolated static func endpoint(_ text: String) -> (host: String, port: Int)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), let end = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            let parts = host.components(separatedBy: "%")
            let suffix = trimmed[trimmed.index(after: end)...]
            guard parts.count <= 2, LocalNetwork.isLinkLocal(parts[0]),
                  parts.count == 1 || (!parts[1].isEmpty && parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })),
                  suffix.hasPrefix(":"), let port = Int(suffix.dropFirst()), (1...65535).contains(port) else { return nil }
            return ("[\(host)]", port)
        }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port) else { return nil }
        let ip = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard ip.count == 4, ip.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && (0...255).contains(Int($0) ?? -1) }) else { return nil }
        let n = ip.map { Int($0)! }
        guard n[0] == 10 || (n[0] == 192 && n[1] == 168) || (n[0] == 172 && (16...31).contains(n[1])) else { return nil }
        return (String(parts[0]), port)
    }
    private func services() async throws -> [(name: String, endpoint: String)] {
        let native = discovery.endpoints.compactMap { name, endpoint -> (name: String, endpoint: String)? in
            guard Self.endpoint(endpoint) != nil else { return nil }
            return (name, endpoint)
        }
        if !native.isEmpty { return native }
        let result = try await adbRun(["mdns", "services"])
        guard result.code == 0 else { throw AppError.message("Could not discover your phone. Check that both devices use the same Wi-Fi.") }
        return result.output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3, fields[1] == "_adb-tls-connect._tcp", Self.endpoint(fields[2]) != nil else { return nil }
            return (fields[0], fields[2])
        }
    }
    private func connectedDevices() async throws -> [String] {
        let result = try await adbRun(["devices"])
        return result.output.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, parts[1] == "device",
                  parts[0].contains("_adb-tls-connect._tcp") || Self.endpoint(parts[0]) != nil else { return nil }
            return parts[0]
        }
    }
    private func property(_ name: String, device: String) async throws -> String {
        let result = try await adbRun(["-s", device, "shell", "getprop", name], timeout: 5)
        guard result.code == 0 else { return "" }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // Android's "Pair device with QR code" scans this payload, then advertises an
    // _adb-tls-pairing service named S; adb pair uses P as the pairing code.
    func pairWithQR(controller: Controller) {
        guard !busy, !running, let phoneID = controller.phone?.id else { return }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let random = { (count: Int) in String((0..<count).map { _ in alphabet.randomElement()! }) }
        let name = "devswitch-" + random(8), password = random(12)
        let token = UUID(); generation = token; busy = true; needsPairingAddress = false
        qrPayload = "WIFI:T:ADB;S:\(name);P:\(password);;"
        message = "On your phone: Wireless debugging → Pair device with QR code, then scan this code."
        pairing.refresh()
        operation = Task { [self] in
            defer { if generation == token { busy = false; qrPayload = nil } }
            do {
                var service: String?
                for _ in 0..<240 where service == nil {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    let status = controller.status
                    service = pairing.endpoints[name] ?? (status?.pairingName == name ? status?.pairingEndpoint : nil)
                }
                guard let service else { throw AppError.message("The QR code expired. Show a new code and scan again.") }
                qrPayload = nil
                try await pair(service, code: password, phoneID: phoneID, controller: controller, token: token)
            } catch is CancellationError { }
            catch { if generation == token { message = error.localizedDescription } }
        }
    }
    // The pairing-code dialog advertises the same service; find it so only the code is typed.
    func pairWithCode(_ code: String, address: String?, controller: Controller) {
        guard !busy, !running, let phoneID = controller.phone?.id else { return }
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            message = "Enter the six-digit code from Pair device with pairing code on your phone."; return
        }
        let manual = address.flatMap { Self.endpoint($0) }.map { "\($0.host):\($0.port)" }
        let token = UUID(); generation = token; busy = true
        message = "Looking for your phone's pairing service…"
        if manual == nil { pairing.refresh() }
        operation = Task { [self] in
            defer { if generation == token { busy = false } }
            do {
                var service = manual
                for _ in 0..<40 where service == nil {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    let lanIPv4 = controller.status?.lanIPv4
                    let found = pairing.endpoints.values.filter { lanIPv4 == nil || Self.endpoint($0)?.host == lanIPv4 }
                    if let reported = controller.status?.pairingEndpoint, Self.endpoint(reported) != nil { service = reported }
                    else if found.count == 1 { service = found[0] }
                }
                guard let service else {
                    needsPairingAddress = true
                    throw AppError.message("Could not find your phone's pairing service. Enter the IP address & Port shown in the pairing-code dialog.")
                }
                try await pair(service, code: code, phoneID: phoneID, controller: controller, token: token)
            } catch is CancellationError { }
            catch { if generation == token { message = error.localizedDescription } }
        }
    }
    private func pair(_ service: String, code: String, phoneID: String, controller: Controller, token: UUID) async throws {
        guard let host = Self.endpoint(service)?.host else { throw AppError.message("Invalid pairing address.") }
        message = "Pairing with Android…"
        let result = try await adbRun(["pair", service], input: code + "\n", timeout: 25)
        try Task.checkCancellation()
        guard result.code == 0, result.output.contains("Successfully paired") else {
            throw AppError.message("Pairing failed. Keep the pairing screen open on your phone and try again.")
        }
        needsPairingAddress = false
        message = "Paired. Connecting to your phone…"
        for attempt in 0..<10 {
            try Task.checkCancellation()
            // Prefer the endpoint reported through the authenticated companion channel.
            let discovered: [(name: String, endpoint: String)]
            if let reported = controller.status?.wifiEndpoint, Self.endpoint(reported)?.host == host {
                discovered = [("paired phone", reported)]
            } else {
                if attempt == 0 { discovery.refresh() }
                discovered = try await services().filter { Self.endpoint($0.endpoint)?.host == host }
            }
            if discovered.count == 1, let service = discovered.first,
               try await adbRun(["connect", service.endpoint]).code == 0 {
                let value = try await property("ro.serialno", device: service.endpoint)
                if !value.isEmpty, value.count <= 128, value.rangeOfCharacter(from: .controlCharacters) == nil {
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    serial = value; pairedPhoneID = phoneID; lastEndpoint = service.endpoint; trustLost = false
                    defaults.set(value, forKey: "screen.serial")
                    defaults.set(phoneID, forKey: "screen.phoneID")
                    defaults.set(service.endpoint, forKey: "screen.endpoint")
                    message = "Wireless control paired. You can now use Control phone."
                    return
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw AppError.message("Paired, but could not reach the phone's wireless debugging. Keep Wireless debugging on, then pair again.")
    }
    func start(controller: Controller) {
        guard !busy, !running, controller.online, controller.pending == nil else { return }
        guard isPaired(controller.phone?.id) else { message = "Set up Wireless control in Connection settings first."; return }
        let token = UUID(); generation = token; busy = true
        message = "Preparing wireless control…"
        operation = Task { [self] in
            defer { if generation == token { busy = false } }
            do {
                // Resolve prerequisites before changing anything on the phone.
                let adbPath = try Dependencies.locate("adb")
                let scrcpyPath = try Dependencies.locate("scrcpy")
                guard controller.status?.permission == true else {
                    throw AppError.message("DevSwitch on your phone lost its settings permission. Run the adb grant command from the README once over USB.")
                }
                if controller.status?.developer != true || controller.status?.usb != true || controller.status?.wifi != true {
                    controller.send("enable")
                    enabledBy = controller
                    for _ in 0..<30 {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        if controller.pending == nil { break }
                    }
                }
                guard controller.online, controller.status?.developer == true, controller.status?.wifi == true else {
                    throw AppError.message("Wireless debugging is not ready. Allow your Wi-Fi network in the phone's Wireless debugging settings, then retry.")
                }
                // Android reuses the Bonjour service name while assigning a new TLS port.
                // A fresh resolve is required even if no remove/add event was delivered.
                if Self.endpoint(controller.status?.wifiEndpoint ?? "") == nil { discovery.refresh() }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                var selected: String?
                var connectionFailure: String?
                var restartedServer = false
                @MainActor func connect(_ endpoint: String, fallbackAvailable: Bool = false) async throws -> Bool {
                    try Task.checkCancellation()
                    let result = try await adbRun(["connect", endpoint], timeout: 5)
                    try Task.checkCancellation()
                    let output = result.output.lowercased()
                    // adb connect can exit successfully even when the connection failed.
                    if output.contains("failed") || output.contains("cannot") || result.code != 0 {
                        // An ADB server started by another app keeps that app's Local Network
                        // access. Restart it once so it runs under DevSwitch's permission. Never during
                        // the IPv6 attempt: restarting drops every other ADB session on this Mac.
                        if output.contains("no route to host") && !restartedServer && !fallbackAvailable {
                            restartedServer = true
                            message = "Restarting ADB…"
                            _ = try await adbRun(["kill-server"], timeout: 5)
                            _ = try await adbRun(["start-server"], timeout: 10)
                            return try await connect(endpoint, fallbackAvailable: fallbackAvailable)
                        }
                        if output.contains("authenticate") || output.contains("unauthorized") {
                            throw AppError.message("Android rejected wireless authorization. Pair Wireless control again in Connection settings.")
                        }
                        if !fallbackAvailable && (output.contains("no route to host") || output.contains("permission denied") || output.contains("operation not permitted")) {
                            throw AppError.message("ADB cannot reach your phone. Check Mac Local Network access for DevSwitch and the app that started ADB, and confirm both devices use the same Wi-Fi. Your pairing is still saved.")
                        }
                        // The port answers but ADB is refused: Android dropped this Mac's authorization.
                        if await Self.reachable(endpoint) {
                            trustLost = true
                            throw AppError.message("Your phone forgot this Mac. Choose Re-pair wireless control and scan the QR code.")
                        }
                        connectionFailure = "Found your phone, but ADB could not connect:\(result.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)). Retry after checking Wireless debugging on the phone."
                        return false
                    }
                    guard try await property("ro.serialno", device: endpoint) == serial else {
                        connectionFailure = "ADB connected, but could not verify your paired phone. Check that the phone is online and retry."
                        return false
                    }
                    lastEndpoint = endpoint; trustLost = false
                    defaults.set(endpoint, forKey: "screen.endpoint")
                    return true
                }
                for _ in 0..<8 {
                    try Task.checkCancellation()
                    // Prefer the authenticated, directly attached IPv6 address. An IPv4
                    // conflict must not steal an otherwise healthy screen connection.
                    if let ipv6 = LocalNetwork.phoneEndpoint(controller.status), try await connect(ipv6, fallbackAvailable: true) {
                        selected = ipv6; break
                    }
                    let devices = try await connectedDevices().sorted { $0.hasPrefix("[") && !$1.hasPrefix("[") }
                    for device in devices {
                        if try await property("ro.serialno", device: device) == serial { selected = device; break }
                    }
                    if selected != nil { break }
                    if let reported = controller.status?.wifiEndpoint, Self.endpoint(reported) != nil {
                        message = "Connecting to your phone over Wi-Fi…"
                        if try await connect(reported) {
                            selected = reported; break
                        }
                        message = "Waiting for your phone's wireless connection…"
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        continue
                    }
                    let candidates = try await services().filter { $0.name.hasPrefix("adb-\(serial)-") }
                    for candidate in candidates {
                        if try await connect(candidate.endpoint) {
                            selected = candidate.endpoint; break
                        }
                    }
                    if selected != nil { break }
                    if candidates.isEmpty && !lastEndpoint.isEmpty {
                        if try await connect(lastEndpoint) { selected = lastEndpoint; break }
                    }
                    discovery.refresh()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard let selected else { throw AppError.message(connectionFailure ?? discovery.failure ?? ((controller.status?.wifiEndpoint ?? "").isEmpty
                    ? "Wireless debugging is on, but Android isn't advertising it. Open Wireless debugging on the phone and allow this Wi-Fi network, then retry."
                    : "Could not find the phone's current wireless connection. Keep both devices on the same Wi-Fi and retry Control phone. Your saved pairing has not been removed.")) }
                try Task.checkCancellation()
                guard generation == token else { return }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: scrcpyPath)
                process.arguments = ["--serial", selected, "--window-title", "DevSwitch — Phone", "--max-size", "1600", "--max-fps", "60"]
                var environment = ProcessInfo.processInfo.environment
                environment["ADB"] = adbPath
                process.environment = environment
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                process.terminationHandler = { [weak self] p in
                    Task { @MainActor in
                        guard let self, self.process === p else { return }
                        self.running = false; self.process = nil
                        self.disableIfEnabled()
                        self.message = p.terminationStatus == 0 ? "Screen sharing stopped." : "Screen sharing ended. Check the phone connection and try again."
                    }
                }
                try process.run(); self.process = process; running = true
                message = "Screen control is running. Closing its window stops sharing."
            } catch is CancellationError { }
            catch { if generation == token { message = error.localizedDescription; disableIfEnabled() } }
        }
    }
    func stop() {
        generation = UUID(); operation?.cancel(); operation = nil; busy = false
        if let process, process.isRunning { process.terminate() }
        process = nil; running = false; qrPayload = nil; message = "Screen sharing stopped."
        disableIfEnabled()
    }
    // Queued even while the phone is away; the long TTL applies it when the phone returns.
    private func disableIfEnabled() {
        guard let controller = enabledBy else { return }
        enabledBy = nil
        controller.enqueue(OutgoingCommand("disable", ttl: 600))
    }
    nonisolated static func reachable(_ text: String) async -> Bool {
        guard let parsed = endpoint(text), let port = NWEndpoint.Port(rawValue: UInt16(parsed.port)) else { return false }
        let host = parsed.host.hasPrefix("[") ? String(parsed.host.dropFirst().dropLast()) : parsed.host
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "dev.notsg.devswitch.probe")
        return await withCheckedContinuation { continuation in
            // The state handler and the timeout both run on `queue`, so `done` is never raced.
            var done = false
            func finish(_ value: Bool) {
                guard !done else { return }
                done = true; connection.cancel(); continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) { finish(false) }
        }
    }
    func forget() {
        stop(); needsPairingAddress = false; trustLost = false; pairedPhoneID = nil; serial = ""; lastEndpoint = ""
        for key in ["screen.phoneID", "screen.serial", "screen.endpoint"] { defaults.removeObject(forKey: key) }
        message = ""
        // Android's separate authorization can be revoked under Wireless debugging → Paired devices.
    }
}
