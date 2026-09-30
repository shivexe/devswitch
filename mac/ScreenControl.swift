import Foundation

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
    @Published var needsConnectionAddress = false
    private var pendingPairHost = ""
    private var pendingPhoneID = ""
    @Published var busy = false
    @Published var running = false
    @Published var message = ""
    @Published private(set) var pairedPhoneID: String?
    private var serial = ""
    private var lastEndpoint = ""
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var process: Process?
    private let defaults = UserDefaults.standard
    private let discovery = BonjourDiscovery()

    init() {
        pairedPhoneID = defaults.string(forKey: "screen.phoneID")
        serial = defaults.string(forKey: "screen.serial") ?? ""
        lastEndpoint = defaults.string(forKey: "screen.endpoint") ?? ""
    }
    func isPaired(_ phoneID: String?) -> Bool { phoneID != nil && pairedPhoneID == phoneID && !serial.isEmpty }
    static func endpoint(_ text: String) -> (host: String, port: Int)? {
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
    func pair(address: String, code: String, phoneID: String, connectionEndpoint: String? = nil) {
        guard !busy, !running else { return }
        guard let endpoint = Self.endpoint(address), code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            message = "Enter the IP:port and six-digit code from Pair device with pairing code on your phone."; return
        }
        let target = "\(endpoint.host):\(endpoint.port)"
        let token = UUID(); generation = token; busy = true
        message = "Pairing with Android…"
        operation = Task { [self] in
            defer { if generation == token { busy = false } }
            do {
                let result = try await adbRun(["pair", target], input: code + "\n", timeout: 25)
                try Task.checkCancellation()
                guard result.code == 0, result.output.contains("Successfully paired") else {
                    throw AppError.message("Pairing failed. Keep the pairing-code dialog open and use its current address and code.")
                }
                pendingPairHost = endpoint.host; pendingPhoneID = phoneID
                // Prefer the endpoint reported through the authenticated companion channel.
                if connectionEndpoint == nil { discovery.refresh() }
                for _ in 0..<10 {
                    try Task.checkCancellation()
                    let discovered: [(name: String, endpoint: String)]
                    if let reported = connectionEndpoint, Self.endpoint(reported)?.host == endpoint.host {
                        discovered = [("paired phone", reported)]
                    } else {
                        discovered = try await services().filter { Self.endpoint($0.endpoint)?.host == endpoint.host }
                    }
                    if discovered.count == 1, let service = discovered.first {
                        let connected = try await adbRun(["connect", service.endpoint])
                        if connected.code == 0 {
                            let value = try await property("ro.serialno", device: service.endpoint)
                            guard !value.isEmpty, value.count <= 128, value.rangeOfCharacter(from: .controlCharacters) == nil else { continue }
                            try Task.checkCancellation()
                            guard generation == token else { return }
                            needsConnectionAddress = false
                            serial = value; pairedPhoneID = phoneID; lastEndpoint = service.endpoint
                            defaults.set(value, forKey: "screen.serial")
                            defaults.set(phoneID, forKey: "screen.phoneID")
                            defaults.set(service.endpoint, forKey: "screen.endpoint")
                            message = "Wireless control paired. You can now use Control phone."
                            return
                        }
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                needsConnectionAddress = true
                message = "Pairing succeeded. Close the code dialog on your phone and enter IP address & Port from the main Wireless debugging screen."
            } catch is CancellationError { }
            catch { if generation == token { message = error.localizedDescription } }
        }
    }
    func finishPair(address: String) {
        guard !busy, let endpoint = Self.endpoint(address), endpoint.host == pendingPairHost else {
            message = "Use the connection IP:port from the same phone's Wireless debugging screen."; return
        }
        let target = "\(endpoint.host):\(endpoint.port)"
        let token = UUID(); generation = token; busy = true
        operation = Task { [self] in
            defer { if generation == token { busy = false } }
            do {
                _ = try await adbRun(["connect", target])
                let value = try await property("ro.serialno", device: target)
                try Task.checkCancellation()
                guard generation == token, !value.isEmpty, value.count <= 128, value.rangeOfCharacter(from: .controlCharacters) == nil else {
                    throw AppError.message("Could not connect. Use the port on the main Wireless debugging screen, not the pairing-code port.")
                }
                serial = value; pairedPhoneID = pendingPhoneID; lastEndpoint = target
                defaults.set(value, forKey: "screen.serial"); defaults.set(pendingPhoneID, forKey: "screen.phoneID")
                defaults.set(target, forKey: "screen.endpoint")
                needsConnectionAddress = false; message = "Wireless control paired. You can now use Control phone."
            } catch is CancellationError { }
            catch { if generation == token { message = error.localizedDescription } }
        }
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
                if controller.status?.developer != true || controller.status?.usb != true || controller.status?.wifi != true {
                    controller.send("enable")
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
                if controller.status?.wifiEndpoint == nil { discovery.refresh() }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                var selected: String?
                for _ in 0..<8 {
                    try Task.checkCancellation()
                    for device in try await connectedDevices() {
                        if try await property("ro.serialno", device: device) == serial { selected = device; break }
                    }
                    if selected != nil { break }
                    if let reported = controller.status?.wifiEndpoint {
                        if Self.endpoint(reported) != nil {
                            message = "Connecting to your phone over Wi-Fi…"
                            _ = try await adbRun(["connect", reported], timeout: 5)
                            if try await property("ro.serialno", device: reported) == serial {
                                selected = reported; lastEndpoint = reported; break
                            }
                        }
                        message = "Waiting for your phone's wireless connection…"
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        continue
                    }
                    let candidates = try await services().filter { $0.name.hasPrefix("adb-\(serial)-") }
                    for candidate in candidates {
                        _ = try await adbRun(["connect", candidate.endpoint], timeout: 5)
                        if try await property("ro.serialno", device: candidate.endpoint) == serial {
                            selected = candidate.endpoint; lastEndpoint = candidate.endpoint; break
                        }
                    }
                    if selected != nil { break }
                    if candidates.isEmpty && !lastEndpoint.isEmpty {
                        _ = try await adbRun(["connect", lastEndpoint], timeout: 4)
                        if try await property("ro.serialno", device: lastEndpoint) == serial { selected = lastEndpoint; break }
                    }
                    discovery.refresh()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard let selected else { throw AppError.message((controller.status?.wifiEndpoint == nil ? discovery.failure : nil) ?? "Could not find the phone's current wireless connection. Keep both devices on the same Wi-Fi and retry Control phone. Your saved pairing has not been removed.") }
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
                        self.message = p.terminationStatus == 0 ? "Screen sharing stopped." : "Screen sharing ended. Check the phone connection and try again."
                    }
                }
                try process.run(); self.process = process; running = true
                message = "Screen control is running. Closing its window stops sharing."
            } catch is CancellationError { }
            catch { if generation == token { message = error.localizedDescription } }
        }
    }
    func stop() {
        generation = UUID(); operation?.cancel(); operation = nil; busy = false
        if let process, process.isRunning { process.terminate() }
        process = nil; running = false; message = "Screen sharing stopped."
    }
    func forget() {
        stop(); needsConnectionAddress = false; pendingPairHost = ""; pendingPhoneID = ""; pairedPhoneID = nil; serial = ""; lastEndpoint = ""
        for key in ["screen.phoneID", "screen.serial", "screen.endpoint"] { defaults.removeObject(forKey: key) }
        message = ""
        // Android's separate authorization can be revoked under Wireless debugging → Paired devices.
    }
}
