import Foundation

// Poll v2 models (research §4.1). Plaintext travels inside the existing Envelope with
// AAD devswitch/poll/v2/<deviceId> and devswitch/reply/v2/<deviceId>.
struct PhoneStatus: Codable, Equatable {
    let developer: Bool; let usb: Bool; let wifi: Bool; let permission: Bool; let wifiEndpoint: String?
    let lanIPv4: String?; let wifiIPv6Endpoint: String?; let adbTrustPersistent: Bool?
    let pairingName: String?; let pairingEndpoint: String?
    // v2 additions; an older phone omits them.
    var battery: Int? = nil; var charging: Bool? = nil; var network: String? = nil
    var sims: [SimCard]? = nil; var ringing: Bool? = nil; var listenerConnected: Bool? = nil
}
struct SimCard: Codable, Equatable {
    let subId: Int; let name: String
    init(subId: Int, name: String) { self.subId = subId; self.name = name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subId = try c.decode(Int.self, forKey: .subId)
        name = displayString(try c.decode(String.self, forKey: .name), max: 80)
    }
}
struct Receipt: Codable { let id: String; let ok: Bool; let message: String }

/// Strips control characters (newlines and tabs survive) and caps the length of a string shown to the user.
func displayString(_ value: String, max: Int) -> String {
    String(String.UnicodeScalarView(value.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }).prefix(max))
}

enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): if v == v.rounded(), abs(v) < 9e15 { try c.encode(Int64(v)) } else { try c.encode(v) }
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

/// A phone→Mac event. `kind` comes from `t`; every field, known or not, stays in `fields`
/// with display strings already cleaned.
struct PhoneEvent: Decodable {
    enum Kind: Equatable {
        case otp, notification, notificationRemoved, call, clipboard, link, fileOffer, smsStatus, unknown(String)
    }
    let id: String
    let kind: Kind
    let at: Int64?
    let fields: [String: JSONValue]

    private static let caps = ["title": 120, "text": 1024, "app": 80, "name": 120, "source": 120, "url": 2048]
    init(from decoder: Decoder) throws {
        let raw = try [String: JSONValue](from: decoder)
        guard case .string(let id)? = raw["id"], !id.isEmpty, id.count <= 64,
              case .string(let t)? = raw["t"] else { throw AppError.message("Invalid event.") }
        let kinds: [String: Kind] = ["otp": .otp, "notification": .notification, "notificationRemoved": .notificationRemoved, "call": .call,
                                     "clipboard": .clipboard, "link": .link, "fileOffer": .fileOffer, "smsStatus": .smsStatus]
        self.id = id
        kind = kinds[t] ?? .unknown(displayString(t, max: 40))
        if case .number(let at)? = raw["at"] { self.at = Int64(at) } else { at = nil }
        fields = raw.reduce(into: [:]) { result, item in
            guard case .string(let value) = item.value else { result[item.key] = item.value; return }
            // Clipboard text may be up to 16 KB; other display strings use their §4.1 caps.
            let max = t == "clipboard" && item.key == "text" ? 16 * 1024 : Self.caps[item.key] ?? 16 * 1024
            result[item.key] = .string(displayString(value, max: max))
        }
    }
    func string(_ key: String) -> String? { if case .string(let v)? = fields[key] { return v }; return nil }
    func int(_ key: String) -> Int64? { if case .number(let v)? = fields[key] { return Int64(exactly: v.rounded()) }; return nil }
    func bool(_ key: String) -> Bool? { if case .bool(let v)? = fields[key] { return v }; return nil }
}

struct FileOfferEvent: Equatable {
    let transferId: String; let name: String; let size: Int64; let mime: String; let sha256: String; let chunkSize: Int
    init?(_ event: PhoneEvent) {
        guard event.kind == .fileOffer, let transferId = event.string("transferId"), UUID(uuidString: transferId) != nil,
              let name = event.string("name"), let size = event.int("size"), size >= 0,
              let sha256 = event.string("sha256"), sha256.count == 64, let chunkSize = event.int("chunkSize") else { return nil }
        self.transferId = transferId.lowercased(); self.name = name; self.size = size
        mime = event.string("mime") ?? "application/octet-stream"; self.sha256 = sha256.lowercased(); self.chunkSize = Int(chunkSize)
    }
}

/// A Mac→phone command. `fields` carries the action-specific keys of §4.1.
struct OutgoingCommand: Encodable, Equatable {
    let id: String
    let a: String
    let expiresAt: Int64
    var fields: [String: JSONValue] = [:]

    /// TTLs from §4.1: ring 60 s, call actions 15 s, others 120 s.
    init(_ action: String, _ fields: [String: JSONValue] = [:], ttl: TimeInterval? = nil) {
        id = UUID().uuidString.lowercased(); a = action; self.fields = fields
        let ttl = ttl ?? (action == "ring" ? 60 : ["declineCall", "silenceCall"].contains(action) ? 15 : 120)
        expiresAt = Int64(Date().timeIntervalSince1970 + ttl)
    }
    var isCall: Bool { ["declineCall", "silenceCall"].contains(a) }
    private struct Key: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for (key, value) in fields where !["id", "a", "expiresAt"].contains(key) { try c.encode(value, forKey: Key(stringValue: key)) }
        try c.encode(id, forKey: Key(stringValue: "id"))
        try c.encode(a, forKey: Key(stringValue: "a"))
        try c.encode(expiresAt, forKey: Key(stringValue: "expiresAt"))
    }
}

struct Poll2: Decodable {
    let requestId: String; let sentAt: Int64
    let status: PhoneStatus?
    let receipts: [Receipt]?
    let events: [PhoneEvent]?
    let eventsDropped: Int?
}
struct Reply2: Encodable {
    let requestId: String
    let desktopIPv6: String?
    let ack: [String]
    let nextPollMs: Int
    let needIcons: [String]
    let commands: [OutgoingCommand]
    let needStatus: Bool?
}
