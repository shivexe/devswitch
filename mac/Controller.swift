import AppKit
import CryptoKit
import Foundation
import Security

// This app uses its own Keychain item. Harbor's vault and pairing are never read.
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
struct Phone: Codable { let id: String; let name: String; let key: Data }
struct Invitation: Codable {
    let version: Int; let app: String; let url: String; let pairId: String
    let secret: String; let expiresAt: Int64; let desktopName: String
}
struct Hello: Codable { let deviceId: String; let deviceName: String; let clientNonce: String }
struct Accepted: Codable { let deviceId: String; let key: String; let desktopName: String }
struct Poll: Codable { let requestId: String; let sentAt: Int64; let status: PhoneStatus; let receipt: Receipt? }
struct Command: Codable { let id: String; let action: String; let expiresAt: Int64 }
struct Reply: Codable { let requestId: String; let command: Command?; let desktopIPv6: String? }
/// Outcome of one command as reported by the phone; enable/disable also require the reported settings to match.
struct CommandReceipt: Equatable { let id: String; let action: String; let ok: Bool; let message: String }
extension CommandReceipt {
    /// The user-facing name of a command, for status messages.
    static func label(_ action: String) -> String {
        ["ring": "Find My Phone", "stopRing": "Stop ringing", "setClipboard": "Send Clipboard", "fileOffer": "Send File",
         "fileAccept": "Receive file", "fileDecline": "Decline file", "sendSms": "Message", "dismiss": "Dismiss notification",
         "reply": "Reply", "declineCall": "Decline call", "silenceCall": "Silence call", "setMuted": "Mute app"][action] ?? action
    }
    var failure: String { "\(Self.label(action)) failed: \(message.isEmpty ? "your phone could not do it." : message)" }
}

@MainActor
final class Controller: ObservableObject {
    static let port: UInt16 = 45874
    static let sendingClipboard = "Sending your clipboard to the phone…"
    let screen = ScreenControl()
    @Published var phone: Phone?
    @Published var status: PhoneStatus?
    @Published var online = false
    @Published var message = ""
    @Published var invitation: Invitation?
    @Published var comparison = ""
    @Published var candidateName = ""
    @Published private(set) var queue: [OutgoingCommand] = []
    @Published private(set) var lastReceipt: CommandReceipt?
    @Published var serverReady = false
    /// The enable/disable change in flight, kept for views and the v1 poll.
    var pending: Command? {
        queue.first { ["enable", "disable"].contains($0.a) }.map { Command(id: $0.id, action: $0.a, expiresAt: $0.expiresAt) }
    }
    var onReceipt: ((String, Receipt) -> Void)?
    /// Icon hashes the Mac wants the phone to attach; sent once in the next v2 reply.
    var needIcons: Set<String> = []
    private var hello: Hello?
    private var approved: Envelope?
    private var seen: [String: (at: Date, sentAt: Int64)] = [:]
    /// Newest sentAt among ids evicted from a full `seen`; a replay of an evicted id can be no newer.
    private var evictedSentAt = Int64.min
    private var recentEvents: [String] = []
    private var delivered: Set<String> = []
    private var hotUntil = Date.distantPast
    private var lastPoll = Date.distantPast
    private var askedMs = 0
    private var attempts: [Date] = []
    private var lastSeen = Date.distantPast
    private var timer: Timer?
    private lazy var server = HTTPServer { [weak self] in self?.handle($0) ?? HTTPResponse(503) }
    private lazy var router = EventRouter(controller: self)
    lazy var files = FileChannel(controller: self)
    private let keychainService = "dev.notsg.devswitch.pairing"

    init() {
        do {
            var query = keychainQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let code = SecItemCopyMatching(query as CFDictionary, &item)
            if code == errSecSuccess, let data = item as? Data { phone = try JSONDecoder().decode(Phone.self, from: data) }
            else if code != errSecItemNotFound { throw AppError.message("Cannot read pairing from Keychain (\(code)).") }
            server.failed = { [weak self] error in self?.serverReady = false; self?.message = error }
            server.ready = { [weak self] in self?.serverReady = true }
            try server.start(port: Self.port)
        } catch { message = error.localizedDescription }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "phone"]
    }
    private func save(_ phone: Phone) throws {
        let data = try JSONEncoder().encode(phone)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            let query = keychainQuery.merging(attributes) { $1 }
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw AppError.message("Could not save pairing in Keychain.") }
        } else if result != errSecSuccess { throw AppError.message("Could not update pairing in Keychain.") }
    }
    func unpair() {
        let code = SecItemDelete(keychainQuery as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { message = "Could not remove pairing from Keychain."; return }
        screen.forget()
        phone = nil; status = nil; online = false; queue = []; delivered = []; lastSeen = .distantPast
        cancelPairing(); message = "Phone unpaired."
    }
    func makeInvitation(address: String) {
        guard serverReady, phone == nil else { return }
        cancelPairing()
        invitation = Invitation(version: 1, app: "devswitch", url: "http://\(address):\(Self.port)",
                                pairId: UUID().uuidString.lowercased(), secret: SyncCrypto.random(32).base64EncodedString(),
                                expiresAt: Int64(Date().timeIntervalSince1970) + 300,
                                desktopName: Host.current().localizedName ?? "Mac")
        message = "Scan the QR code using DevSwitch on your phone."
    }
    func cancelPairing() { invitation = nil; hello = nil; approved = nil; comparison = ""; candidateName = "" }
    func approve() {
        guard let invitation, invitation.expiresAt > Int64(Date().timeIntervalSince1970), let hello, approved == nil,
              let secret = Data(base64Encoded: invitation.secret) else { return }
        do {
            let phone = Phone(id: hello.deviceId, name: hello.deviceName, key: SyncCrypto.random(32))
            let response = try SyncCrypto.seal(Accepted(deviceId: phone.id, key: phone.key.base64EncodedString(), desktopName: invitation.desktopName),
                                               key: secret, aad: "devswitch/pair-response/v1/\(invitation.pairId)")
            try save(phone)
            self.phone = phone; approved = response
            message = "Approved. Waiting for the phone to connect…"
        } catch { message = error.localizedDescription }
    }
    func send(_ action: String) {
        guard ["enable", "disable"].contains(action), online, pending == nil, status?.permission == true else { return }
        // Stopping a session that turned development on already queues the disable.
        if action == "disable" { screen.stop() }
        if pending == nil { enqueue(OutgoingCommand(action, ttl: 20)) }
        message = action == "enable" ? "Enabling on your phone…" : "Disabling on your phone…"
    }
    /// Queues a command for the phone, even while it is offline; its TTL handles staleness.
    func enqueue(_ command: OutgoingCommand) {
        if queue.count >= 16, let index = queue.firstIndex(where: { !$0.isCall }) ?? queue.indices.first {
            delivered.remove(queue.remove(at: index).id)
        }
        queue.append(command)
    }
    /// Asks the phone to poll every 500 ms for a while (menu panel open, transfer, call).
    func requestHotPolling(for seconds: TimeInterval) {
        hotUntil = max(hotUntil, Date().addingTimeInterval(seconds))
    }
    private func expireCommands() {
        let now = Int64(Date().timeIntervalSince1970)
        if let pending, pending.expiresAt < now { message = "No confirmation received. Check the phone connection and retry." }
        for command in queue where command.expiresAt < now {
            delivered.remove(command.id)
            // Background syncs (mute list, dismissals, automatic clipboard) expire quietly.
            if !["enable", "disable", "setMuted", "dismiss"].contains(command.a), command.a != "setClipboard" || message == Self.sendingClipboard {
                message = "\(CommandReceipt.label(command.a)): no answer from your phone. Check the connection and retry."
            }
        }
        if queue.contains(where: { $0.expiresAt < now }) { queue.removeAll { $0.expiresAt < now } }
    }
    private func tick() {
        let connected = phone != nil && Date().timeIntervalSince(lastSeen) < 10
        if online != connected { online = connected }
        expireCommands()
        files.sweep()
        if let invitation, invitation.expiresAt < Int64(Date().timeIntervalSince1970) {
            cancelPairing()
            if phone == nil { message = "Pairing code expired. Generate a new code." }
        }
    }
    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        do {
            if request.path.hasPrefix("/v1/pair/") { return try pair(request) }
            if request.path == "/v2/poll" { return try handleV2(request) }
            if request.path.hasPrefix("/v2/file/") { return files.handle(request) }
            guard request.path == "/v1/poll", let phone else { return HTTPResponse(403) }
            let envelope = try JSONDecoder().decode(Envelope.self, from: request.body)
            guard envelope.deviceId == phone.id else { return HTTPResponse(403) }
            let poll = try SyncCrypto.open(Poll.self, envelope: envelope, key: phone.key, aad: "devswitch/poll/v1/\(phone.id)")
            guard abs(Double(poll.sentAt) - Date().timeIntervalSince1970) <= 30,
                  let nonce = Data(base64Encoded: poll.requestId), nonce.count == 32 else { return HTTPResponse(400) }
            guard remember(poll.requestId, sentAt: poll.sentAt) else { return HTTPResponse(409) }
            record(poll.status, request)
            if let receipt = poll.receipt, receipt.id == pending?.id { complete(receipt) }
            expireCommands()
            return try .json(200, SyncCrypto.seal(Reply(requestId: poll.requestId, command: pending,
                desktopIPv6: LocalNetwork.link(for: poll.status.lanIPv4)?.host), key: phone.key, aad: "devswitch/reply/v1/\(phone.id)"))
        } catch { return HTTPResponse(400) }
    }
    private func handleV2(_ request: HTTPRequest) throws -> HTTPResponse {
        guard let phone else { return HTTPResponse(403) }
        let envelope = try JSONDecoder().decode(Envelope.self, from: request.body)
        guard envelope.deviceId == phone.id else { return HTTPResponse(403) }
        let poll = try SyncCrypto.open(Poll2.self, envelope: envelope, key: phone.key, aad: "devswitch/poll/v2/\(phone.id)")
        guard abs(Double(poll.sentAt) - Date().timeIntervalSince1970) <= 30,
              let nonce = Data(base64Encoded: poll.requestId), nonce.count == 32,
              (poll.events?.count ?? 0) <= 32, (poll.receipts?.count ?? 0) <= 16 else { return HTTPResponse(400) }
        // Only empty polls that come back sooner than asked are throttled; events and receipts always get through.
        let elapsed = Date().timeIntervalSince(lastPoll)
        if poll.events?.isEmpty != false, poll.receipts?.isEmpty != false, elapsed * 1000 < Double(askedMs), elapsed < 0.15 {
            return HTTPResponse(429, Data("{\"nextPollMs\":150}".utf8))
        }
        guard remember(poll.requestId, sentAt: poll.sentAt) else { return HTTPResponse(409) }
        record(poll.status, request)
        let events = poll.events ?? []
        for event in events where !recentEvents.contains(event.id) {
            recentEvents.append(event.id)
            if recentEvents.count > 512 { recentEvents.removeFirst() }
            if event.kind == .call, event.string("state") == "ringing" { requestHotPolling(for: 30) }
            router.handle(event)
        }
        for receipt in poll.receipts ?? [] where queue.contains(where: { $0.id == receipt.id }) { complete(receipt) }
        expireCommands()
        let commands = Array(queue.prefix(16))
        // A command delivered for the first time asks for an immediate poll so its receipt comes straight back.
        let fresh = commands.contains { !delivered.contains($0.id) }
        delivered.formUnion(commands.map(\.id))
        askedMs = fresh ? 0 : !queue.isEmpty || hotUntil > Date() || status?.ringing == true ? 500 : 2000
        lastPoll = Date()
        let icons = Array(needIcons.prefix(32)); needIcons.subtract(icons)
        return try .json(200, SyncCrypto.seal(Reply2(requestId: poll.requestId, desktopIPv6: LocalNetwork.link(for: status?.lanIPv4)?.host,
            ack: events.map(\.id), nextPollMs: askedMs, needIcons: icons, commands: commands, needStatus: status == nil ? true : nil),
            key: phone.key, aad: "devswitch/reply/v2/\(phone.id)"))
    }
    private func remember(_ requestId: String, sentAt: Int64) -> Bool {
        seen = seen.filter { Date().timeIntervalSince($0.value.at) < 120 }
        guard seen[requestId] == nil, sentAt > evictedSentAt else { return false }
        // 2048 covers 120 s of 500 ms hot polling plus immediate event polls. A flood evicts the oldest id instead of
        // refusing every poll; evictedSentAt then refuses anything sent no later than it, so evicted ids stay unreplayable.
        if seen.count >= 2048, let oldest = seen.min(by: { $0.value.at < $1.value.at }) {
            seen[oldest.key] = nil
            evictedSentAt = max(evictedSentAt, oldest.value.sentAt)
        }
        seen[requestId] = (Date(), sentAt)
        return true
    }
    private func record(_ newStatus: PhoneStatus?, _ request: HTTPRequest) {
        if let newStatus, status != newStatus { status = newStatus }
        lastSeen = Date()
        // Non-secret diagnostics for local connection troubleshooting.
        UserDefaults.standard.set(status?.wifiEndpoint ?? "", forKey: "connection.phoneEndpoint")
        UserDefaults.standard.set(lastSeen.timeIntervalSince1970, forKey: "connection.lastSeen")
        UserDefaults.standard.set(request.remoteHost?.contains(":") == true ? "IPv6" : "IPv4", forKey: "connection.transport")
        UserDefaults.standard.set(LocalNetwork.link(for: status?.lanIPv4)?.host ?? "", forKey: "connection.desktopIPv6")
        UserDefaults.standard.set(LocalNetwork.phoneEndpoint(status) ?? "", forKey: "connection.phoneIPv6Endpoint")
        if !online { online = true }
    }
    private func complete(_ receipt: Receipt) {
        guard let index = queue.firstIndex(where: { $0.id == receipt.id }) else { return }
        let command = queue.remove(at: index)
        delivered.remove(command.id)
        var ok = receipt.ok
        if ["enable", "disable"].contains(command.a), let status {
            let matches = command.a == "enable"
                ? status.developer && status.usb && status.wifi
                : !status.developer && !status.usb && !status.wifi
            ok = ok && matches
            message = ok ? "Confirmed by your phone." : "Phone could not apply the change. \(receipt.message.prefix(160))"
        }
        let result = CommandReceipt(id: command.id, action: command.a, ok: ok, message: String(receipt.message.prefix(160)))
        if !ok, !["enable", "disable"].contains(command.a) { message = result.failure }
        // A refused offer must free the channel, or the next send waits out the 10-minute expiry.
        if !ok, command.a == "fileOffer", case .string(let id)? = command.fields["transferId"] { files.cancelOutgoing(id) }
        // Only the manual send says so; automatic sync stays quiet.
        if ok, command.a == "setClipboard", message == Self.sendingClipboard { message = "Sent your clipboard to the phone. Paste it there." }
        lastReceipt = result
        onReceipt?(command.id, receipt)
    }
    private func pair(_ request: HTTPRequest) throws -> HTTPResponse {
        attempts.removeAll { Date().timeIntervalSince($0) > 60 }
        guard attempts.count < 90 else { return HTTPResponse(429) }
        attempts.append(Date())
        guard let invitation, request.path == "/v1/pair/\(invitation.pairId)", invitation.expiresAt > Int64(Date().timeIntervalSince1970),
              let secret = Data(base64Encoded: invitation.secret) else { return HTTPResponse(410) }
        let envelope = try JSONDecoder().decode(Envelope.self, from: request.body)
        let candidate = try SyncCrypto.open(Hello.self, envelope: envelope, key: secret, aad: "devswitch/pair-request/v1/\(invitation.pairId)")
        guard UUID(uuidString: candidate.deviceId) != nil, !candidate.deviceName.isEmpty, candidate.deviceName.count <= 80,
              candidate.deviceName.rangeOfCharacter(from: .controlCharacters) == nil,
              let nonce = Data(base64Encoded: candidate.clientNonce), nonce.count == 32 else { return HTTPResponse(400) }
        if let hello {
            guard hello.deviceId == candidate.deviceId, hello.clientNonce == candidate.clientNonce else { return HTTPResponse(403) }
        } else {
            hello = candidate; candidateName = candidate.deviceName
            comparison = SyncCrypto.comparison(secret: secret, nonce: nonce)
        }
        if let approved { return try .json(200, approved) }
        return HTTPResponse(202, Data("{\"status\":\"pending\"}".utf8))
    }
}
