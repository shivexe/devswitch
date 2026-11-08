import AppKit
import Combine
import UniformTypeIdentifiers
import UserNotifications

/// Mirrors phone notifications into macOS (research Part B §2). UserDefaults holds only package and app names;
/// titles and text go straight into the notification and are never logged.
@MainActor final class NotificationMirror: ObservableObject {
    static let shared = NotificationMirror()
    weak var controller: Controller?
    @Published var enabled = UserDefaults.standard.object(forKey: "notifications.mirror") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "notifications.mirror") }
    }
    /// Off shows only "<App>: New notification", because macOS keeps delivered notification text on disk.
    @Published var showContent = UserDefaults.standard.object(forKey: "notifications.content") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showContent, forKey: "notifications.content") }
    }
    /// Apps seen so far (package → name), for the mute list.
    @Published private(set) var apps = UserDefaults.standard.dictionary(forKey: "notifications.apps") as? [String: String] ?? [:]
    @Published private(set) var muted = Set(UserDefaults.standard.stringArray(forKey: "notifications.muted") ?? [])
    private(set) var mirrored = 0
    private var perApp: [String: [Date]] = [:]
    private var recent: [Date] = []
    private var online: AnyCancellable?

    func start(controller: Controller) {
        self.controller = controller
        // The phone forgets the list on reinstall, so resend it on every reconnect once the user has set one.
        online = controller.$online.removeDuplicates().filter { $0 }.sink { [weak self] _ in
            if UserDefaults.standard.object(forKey: "notifications.muted") != nil { self?.syncMuted() }
        }
    }

    func post(_ event: PhoneEvent) {
        guard let key = event.string("key"), !key.isEmpty, let pkg = event.string("pkg"), !pkg.isEmpty else { return }
        let app = event.string("app").flatMap { $0.isEmpty ? nil : $0 } ?? pkg
        if apps[pkg] != app { apps[pkg] = app; UserDefaults.standard.set(apps, forKey: "notifications.apps") }
        guard enabled, !muted.contains(pkg), allow(pkg) else { return }
        let content = UNMutableNotificationContent()
        let title = event.string("title") ?? ""
        if showContent {
            content.title = title.isEmpty ? app : title
            if !title.isEmpty && title != app { content.subtitle = app }
            content.body = event.string("text") ?? ""
        } else {
            content.title = app
            content.body = "New notification"
        }
        content.threadIdentifier = pkg
        content.summaryArgument = app
        if event.bool("silent") != true { content.sound = .default }
        var info: [String: Any] = ["key": key, "pkg": pkg]
        if case .array(let actions)? = event.fields["actions"],
           let reply = actions.lazy.compactMap({ action -> Int? in
               guard case .object(let a) = action, a["input"] == .bool(true), case .number(let i)? = a["i"] else { return nil }
               return Int(i)
           }).first {
            info["reply"] = reply
            content.categoryIdentifier = "notification.reply"
        } else {
            content.categoryIdentifier = "notification"
        }
        content.userInfo = info
        if let icon = icon(event, pkg: pkg) { content.attachments = [icon] }
        // The Android key is the identifier, so updates replace the banner and removals find it.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        mirrored += 1
    }

    func remove(_ event: PhoneEvent) {
        guard let key = event.string("key") else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [key])
    }

    /// Handles a banner action: dismiss and reply go back to the phone, mute stays on both sides.
    func respond(_ action: String, key: String, pkg: String?, reply: Int?, text: String?) {
        guard let controller else { return }
        switch action {
        case UNNotificationDismissActionIdentifier:
            controller.enqueue(OutgoingCommand("dismiss", ["key": .string(key)]))
        case "reply":
            guard let reply, let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            controller.enqueue(OutgoingCommand("reply", ["key": .string(key), "action": .number(Double(reply)), "text": .string(String(text.prefix(1000)))]))
        case "mute":
            if let pkg { setMuted(pkg, true) }
        default: break
        }
    }

    func setMuted(_ pkg: String, _ mute: Bool) {
        if mute { muted.insert(pkg) } else { muted.remove(pkg) }
        UserDefaults.standard.set(muted.sorted(), forKey: "notifications.muted")
        syncMuted()
    }

    private func syncMuted() {
        controller?.enqueue(OutgoingCommand("setMuted", ["pkgs": .array(muted.sorted().map { .string($0) })]))
    }

    // Per app 5 per 10 s, and 20 per minute overall.
    private func allow(_ pkg: String) -> Bool {
        let now = Date()
        recent.removeAll { now.timeIntervalSince($0) > 60 }
        var app = perApp[pkg, default: []].filter { now.timeIntervalSince($0) < 10 }
        guard app.count < 5, recent.count < 20 else { perApp[pkg] = app; return false }
        app.append(now); recent.append(now); perApp[pkg] = app
        return true
    }

    // The phone sends an icon once per app; the Mac caches it and asks again through needIcons when missing.
    private func icon(_ event: PhoneEvent, pkg: String) -> UNNotificationAttachment? {
        guard let hash = event.string("iconHash"), !hash.isEmpty, hash.count <= 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              pkg.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("dev.notsg.devswitch/icons", isDirectory: true)
        let file = directory.appendingPathComponent("\(pkg)-\(hash).png")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let base64 = event.string("icon"), let png = Data(base64Encoded: base64), png.count <= 64 * 1024,
                  NSImage(data: png) != nil else { controller?.needIcons.insert(hash); return nil }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? png.write(to: file, options: .atomic)
        }
        // UserNotifications moves the attachment into its own store, so hand it a copy.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "icon", url: copy, options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier])
    }
}
