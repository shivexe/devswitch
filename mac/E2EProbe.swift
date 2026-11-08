#if E2E
import AppKit
import UserNotifications

/// Test-only (`DEVSWITCH_E2E=1 ./mac/build.sh`). Writes e2e/state.json with types, counts and flags, never
/// codes or message text, and runs one action per write to e2e/command through the same code paths as the UI.
@MainActor enum E2EProbe {
    private static var counts: [String: Int] = [:]
    private static var timer: Timer?
    private static var directory: URL { ExtensionSocket.directory.appendingPathComponent("e2e", isDirectory: true) }

    static func record(_ event: PhoneEvent) {
        let name: String
        if case .unknown(let t) = event.kind { name = t } else { name = "\(event.kind)" }
        counts[name, default: 0] += 1
    }

    static func start(controller: Controller) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { poll(controller) }
        }
    }

    private static func poll(_ controller: Controller) {
        let file = directory.appendingPathComponent("command")
        if let command = try? String(contentsOf: file, encoding: .utf8) {
            try? FileManager.default.removeItem(at: file)
            run(command.trimmingCharacters(in: .whitespacesAndNewlines), controller)
        }
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let notifications = delivered.map { n -> [String: Any] in
                ["category": n.request.content.categoryIdentifier, "thread": n.request.content.threadIdentifier,
                 "attachments": n.request.content.attachments.count, "hasDigits": n.request.content.title.contains(where: \.isNumber)]
            }
            UNUserNotificationCenter.current().getNotificationCategories { categories in
                let actions = categories.reduce(into: [String: [String]]()) { $0[$1.identifier] = $1.actions.map(\.identifier).sorted() }
                Task { @MainActor in write(controller, notifications: notifications, categories: actions) }
            }
        }
    }

    private static func write(_ controller: Controller, notifications: [[String: Any]], categories: [String: [String]]) {
        let pasteboard = NSPasteboard.general
        var state: [String: Any] = [
            "events": counts,
            "otpPresent": OtpVault.shared.current() != nil,
            "otpHudVisible": OtpHUD.shared.visible,
            "callPanelVisible": CallPanel.shared.visible,
            "callActionsSent": CallPanel.shared.sent.sorted(),
            "mirrored": NotificationMirror.shared.mirrored,
            "muted": NotificationMirror.shared.muted.sorted(),
            "delivered": notifications,
            "categories": categories,
            "queued": controller.queue.map(\.a),
            "needIcons": controller.needIcons.count,
            "clipboardTypes": (pasteboard.types ?? []).map(\.rawValue),
            "clipboardChangeCount": pasteboard.changeCount,
            "accessibilityTrusted": AutoType.shared.trusted,
        ]
        if let receipt = controller.lastReceipt { state["lastReceipt"] = ["action": receipt.action, "ok": receipt.ok] }
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }

    private static func run(_ command: String, _ controller: Controller) {
        let (verb, argument) = command.firstIndex(of: ":").map { (String(command[..<$0]), String(command[command.index(after: $0)...])) } ?? (command, "")
        switch verb {
        case "declineCall": CallPanel.shared.decline()
        case "silenceCall": CallPanel.shared.silence()
        case "ring": controller.ring(true)
        case "stopRing": controller.ring(false)
        case "sendFile": controller.sendFiles([URL(fileURLWithPath: argument)])
        case "sendClipboard": ClipboardSync.shared.send(manual: true)
        case "copyCode": OtpVault.shared.copy()
        case "dismiss", "mute": NotificationMirror.shared.respond(verb == "mute" ? "mute" : UNNotificationDismissActionIdentifier, key: argument,
                                                                  pkg: argument.split(separator: "|").dropFirst().first.map(String.init), reply: nil, text: nil)
        case "accept", "decline": EventRouter.answerOffer(argument, accept: verb == "accept", controller: controller)
        // Feeds a phone event from a JSON file through the real router, for tests without a phone.
        case "event":
            if let data = try? Data(contentsOf: URL(fileURLWithPath: argument)), let event = try? JSONDecoder().decode(PhoneEvent.self, from: data) {
                EventRouter(controller: controller).handle(event)
            }
        default: NSLog("DevSwitch e2e: unknown command")
        }
    }
}
#endif
