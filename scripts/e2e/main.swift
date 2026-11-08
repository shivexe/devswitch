import CryptoKit
import Foundation
import Security

// E2E fake Mac: the real mac/ Controller, HTTPServer and FileChannel on port 45990, without the UI.
// Built by scripts/e2e-emulator.sh (top-level code, so the file is main.swift). Control directory (argv[1]):
//   phone.json      pairing written on approval (test key, never commit)
//   *.cmd           one command per file: `offer <path>` or a JSON object {"a": action, ...fields, "ttl"?: seconds}
// Logs one line per event/receipt/command; never logs OTP codes or message text.
func SecItemCopyMatching(_ q: CFDictionary, _ r: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { errSecItemNotFound }
func SecItemUpdate(_ q: CFDictionary, _ a: CFDictionary) -> OSStatus { errSecItemNotFound }
func SecItemAdd(_ q: CFDictionary, _ r: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { errSecSuccess }
func SecItemDelete(_ q: CFDictionary) -> OSStatus { errSecSuccess }

func log(_ s: String) { print("[\(String(format: "%.3f", Date().timeIntervalSince1970))] \(s)"); fflush(stdout) }

// Replaces mac/EventRouter.swift: logs a content-free summary and auto-accepts phone file offers.
@MainActor final class EventRouter {
    private unowned let controller: Controller
    init(controller: Controller) { self.controller = controller }
    func handle(_ event: PhoneEvent) {
        var summary = ""
        switch event.kind {
        case .otp: summary = "codeLen=\(event.string("code")?.count ?? 0) source=\(event.string("source") ?? "")"
        case .call: summary = "state=\(event.string("state") ?? "")"
        case .notification, .notificationRemoved: summary = "pkg=\(event.string("pkg") ?? "")"
        case .link: summary = "url=\(event.string("url") ?? "")"
        case .clipboard: summary = "len=\(event.string("text")?.count ?? 0)"
        case .fileOffer: summary = "size=\(event.int("size") ?? -1)"
        case .smsStatus: summary = "result=\(event.string("result") ?? "")"
        case .unknown: break
        }
        log("EVENT \(event.kind) id=\(event.id) \(summary) fields=\(event.fields.keys.sorted())")
        if let offer = FileOfferEvent(event) { log("ACCEPT file \(offer.transferId)"); controller.files.accept(offer: offer) }
    }
    static func fileSaved(_ url: URL, from phone: String?) {}
}

let dir = CommandLine.arguments[1]
let port: UInt16 = 45990
nonisolated(unsafe) var keep: [AnyObject] = []
MainActor.assumeIsolated {
    let c = Controller()   // its own 45874 listener fails when the real app runs; the harness serves on 45990
    if let data = FileManager.default.contents(atPath: "\(dir)/phone.json") {
        c.phone = try! JSONDecoder().decode(Phone.self, from: data)
        log("PAIRED \(c.phone!.name)")
    } else {
        c.invitation = Invitation(version: 1, app: "devswitch", url: "http://10.0.2.2:\(port)", pairId: UUID().uuidString.lowercased(),
                                  secret: SyncCrypto.random(32).base64EncodedString(), expiresAt: Int64(Date().timeIntervalSince1970) + 300, desktopName: "E2E Mac")
        try! JSONEncoder().encode(c.invitation!).write(to: URL(fileURLWithPath: "\(dir)/invitation.json"))
        log("INVITATION written")
    }
    c.onReceipt = { id, r in log("RECEIPT \(id) ok=\(r.ok) message=\(r.message)") }
    let server = HTTPServer { request in
        let response = c.handle(request)
        if request.path.hasPrefix("/v1/") || response.status != 200 && response.status != 429 { log("HTTP \(request.path) -> \(response.status)") }
        return response
    }
    server.ready = { log("LISTENING \(port)") }
    server.failed = { log("LISTEN FAILED \($0)"); exit(2) }
    try! server.start(port: port)
    keep = [c, server]
    var lastStatus: PhoneStatus?
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
        MainActor.assumeIsolated {
            if c.hello != nil, c.phone == nil {
                c.approve()
                try! JSONEncoder().encode(c.phone!).write(to: URL(fileURLWithPath: "\(dir)/phone.json"))
                try? FileManager.default.removeItem(atPath: "\(dir)/invitation.json")
                log("APPROVED \(c.candidateName)")
            }
            if let s = c.status, s != lastStatus {
                lastStatus = s
                log("STATUS online=\(c.online) battery=\(s.battery.map(String.init) ?? "-") ringing=\(s.ringing.map { "\($0)" } ?? "-") listener=\(s.listenerConnected.map { "\($0)" } ?? "-") sims=\(s.sims?.count ?? -1)")
            }
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() where name.hasSuffix(".cmd") {
                let path = "\(dir)/\(name)"
                let text = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? FileManager.default.removeItem(atPath: path)
                if text.hasPrefix("offer ") {
                    do { log("OFFER \(try c.files.offerToPhone(file: URL(fileURLWithPath: String(text.dropFirst(6)))))") } catch { log("OFFER failed \(error)") }
                    continue
                }
                guard let data = text.data(using: .utf8), case .object(var fields)? = try? JSONDecoder().decode(JSONValue.self, from: data),
                      case .string(let action)? = fields.removeValue(forKey: "a") else { log("BAD COMMAND \(name)"); continue }
                var ttl: TimeInterval?
                if case .number(let t)? = fields.removeValue(forKey: "ttl") { ttl = t }
                let command = OutgoingCommand(action, fields, ttl: ttl)
                c.enqueue(command)
                log("ENQUEUE \(command.id) \(action)")
            }
        }
    }
}
RunLoop.main.run()
