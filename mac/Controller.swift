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
struct PhoneStatus: Codable, Equatable {
    let developer: Bool; let usb: Bool; let wifi: Bool; let permission: Bool; let wifiEndpoint: String?
}
struct Receipt: Codable { let id: String; let ok: Bool; let message: String }
struct Poll: Codable { let requestId: String; let sentAt: Int64; let status: PhoneStatus; let receipt: Receipt? }
struct Command: Codable { let id: String; let action: String; let expiresAt: Int64 }
struct Reply: Codable { let requestId: String; let command: Command? }

@MainActor
final class Controller: ObservableObject {
    static let port: UInt16 = 45874
    let screen = ScreenControl()
    @Published var phone: Phone?
    @Published var status: PhoneStatus?
    @Published var online = false
    @Published var message = ""
    @Published var invitation: Invitation?
    @Published var comparison = ""
    @Published var candidateName = ""
    @Published var pending: Command?
    @Published var serverReady = false
    private var hello: Hello?
    private var approved: Envelope?
    private var seen: [String: Date] = [:]
    private var attempts: [Date] = []
    private var lastSeen = Date.distantPast
    private var timer: Timer?
    private lazy var server = HTTPServer { [weak self] in self?.handle($0) ?? HTTPResponse(503) }
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
        let result = SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var query = keychainQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw AppError.message("Could not save pairing in Keychain.") }
        } else if result != errSecSuccess { throw AppError.message("Could not update pairing in Keychain.") }
    }
    func unpair() {
        let code = SecItemDelete(keychainQuery as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { message = "Could not remove pairing from Keychain."; return }
        screen.forget()
        phone = nil; status = nil; online = false; pending = nil; lastSeen = .distantPast
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
        if action == "disable" { screen.stop() }
        pending = Command(id: UUID().uuidString.lowercased(), action: action, expiresAt: Int64(Date().timeIntervalSince1970) + 20)
        message = action == "enable" ? "Enabling on your phone…" : "Disabling on your phone…"
    }
    private func tick() {
        let connected = phone != nil && Date().timeIntervalSince(lastSeen) < 10
        if online != connected { online = connected }
        if let pending, pending.expiresAt < Int64(Date().timeIntervalSince1970) {
            self.pending = nil; message = "No confirmation received. Check the phone connection and retry."
        }
        if let invitation, invitation.expiresAt < Int64(Date().timeIntervalSince1970) {
            cancelPairing()
            if phone == nil { message = "Pairing code expired. Generate a new code." }
        }
    }
    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        do {
            if request.path.hasPrefix("/v1/pair/") { return try pair(request) }
            guard request.path == "/v1/poll", let phone else { return HTTPResponse(403) }
            let envelope = try JSONDecoder().decode(Envelope.self, from: request.body)
            guard envelope.deviceId == phone.id else { return HTTPResponse(403) }
            let poll = try SyncCrypto.open(Poll.self, envelope: envelope, key: phone.key, aad: "devswitch/poll/v1/\(phone.id)")
            guard abs(Double(poll.sentAt) - Date().timeIntervalSince1970) <= 30,
                  let nonce = Data(base64Encoded: poll.requestId), nonce.count == 32 else { return HTTPResponse(400) }
            seen = seen.filter { Date().timeIntervalSince($0.value) < 120 }
            guard seen[poll.requestId] == nil, seen.count < 500 else { return HTTPResponse(409) }
            seen[poll.requestId] = Date()
            if status != poll.status { status = poll.status }
            lastSeen = Date()
            // Non-secret diagnostics for local connection troubleshooting.
            UserDefaults.standard.set(poll.status.wifiEndpoint ?? "", forKey: "connection.phoneEndpoint")
            UserDefaults.standard.set(lastSeen.timeIntervalSince1970, forKey: "connection.lastSeen")
            if !online { online = true }
            if let receipt = poll.receipt, let command = pending, receipt.id == command.id {
                let matches = command.action == "enable"
                    ? poll.status.developer && poll.status.usb && poll.status.wifi
                    : !poll.status.developer && !poll.status.usb && !poll.status.wifi
                message = receipt.ok && matches ? "Confirmed by your phone." : "Phone could not apply the change. \(receipt.message.prefix(160))"
                pending = nil
            }
            if let pending, pending.expiresAt < Int64(Date().timeIntervalSince1970) { self.pending = nil }
            return try .json(200, SyncCrypto.seal(Reply(requestId: poll.requestId, command: pending), key: phone.key, aad: "devswitch/reply/v1/\(phone.id)"))
        } catch { return HTTPResponse(400) }
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
