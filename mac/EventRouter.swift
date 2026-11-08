import AppKit
import UserNotifications

// Dispatches each new (already deduped) phone event to its feature. Logs type and id only, never content.
@MainActor final class EventRouter {
    private unowned let controller: Controller
    /// Phone→Mac file offers waiting for Accept or Decline in their notification.
    private static var offers: [String: FileOfferEvent] = [:]
    init(controller: Controller) { self.controller = controller }

    func handle(_ event: PhoneEvent) {
        NSLog("DevSwitch event %@ %@", "\(event.kind)", event.id)
#if E2E
        E2EProbe.record(event)
#endif
        switch event.kind {
        case .otp: OtpVault.shared.receive(event)
        case .notification: NotificationMirror.shared.post(event)
        case .notificationRemoved: NotificationMirror.shared.remove(event)
        case .call: CallPanel.shared.update(event)
        case .clipboard: ClipboardSync.shared.receive(event)
        case .smsStatus: SmsResults.shared.receive(event)
        case .link: link(event)
        case .fileOffer: fileOffer(event)
        case .unknown: break
        }
    }

    // Links are never opened automatically: a compromised phone could push phishing pages.
    private func link(_ event: PhoneEvent) {
        guard let raw = event.string("url"), let url = Self.webURL(raw) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Link from \(controller.phone?.name ?? "your phone")"
        content.body = event.string("title").flatMap { $0.isEmpty ? nil : $0 } ?? url.host ?? raw
        content.categoryIdentifier = "link"
        content.userInfo = ["url": raw]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "link-\(event.id)", content: content, trigger: nil))
    }

    static func webURL(_ raw: String) -> URL? {
        guard raw.count <= 2048, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else { return nil }
        return url
    }

    /// Opens in the default browser (Helium on the owner's Mac).
    static func open(_ raw: String) {
        if let url = webURL(raw) { NSWorkspace.shared.open(url) }
    }

    private func fileOffer(_ event: PhoneEvent) {
        guard let offer = FileOfferEvent(event) else { return }
        if Self.offers.count >= 8, let oldest = Self.offers.keys.first { Self.offers[oldest] = nil }
        Self.offers[offer.transferId] = offer
        let content = UNMutableNotificationContent()
        content.title = "\(controller.phone?.name ?? "Your phone") wants to send a file"
        content.body = "\(offer.name) · \(ByteCountFormatter.string(fromByteCount: offer.size, countStyle: .file))"
        content.categoryIdentifier = "file"
        content.userInfo = ["transferId": offer.transferId]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "file-\(offer.transferId)", content: content, trigger: nil))
    }

    /// Tells the user where an accepted phone file landed; Show in Finder reveals it.
    static func fileSaved(_ url: URL, from phone: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Saved to Downloads"
        content.body = "\(url.lastPathComponent) from \(phone ?? "your phone")"
        content.categoryIdentifier = "saved"
        content.userInfo = ["path": url.path]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "saved-\(url.path)", content: content, trigger: nil))
    }

    /// Accept saves to ~/Downloads through the file channel; Decline tells the phone to stop.
    static func answerOffer(_ transferId: String, accept: Bool, controller: Controller) {
        guard let offer = offers.removeValue(forKey: transferId) else { return }
        if accept { controller.files.accept(offer: offer) }
        else { controller.enqueue(OutgoingCommand("fileDecline", ["transferId": .string(offer.transferId)])) }
    }
}
