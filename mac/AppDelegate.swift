import AppKit
import UserNotifications

/// Owns the controller and the app-wide services, and answers notification actions.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    lazy var controller = Controller()
    let extensionSocket = ExtensionSocket()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.categories)
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        NotificationMirror.shared.start(controller: controller)
        CallPanel.shared.controller = controller
        ClipboardSync.shared.start(controller: controller)
        extensionSocket.start(vault: OtpVault.shared)
        OtpVault.shared.onArrive = { [weak self] in self?.extensionSocket.otpArrived() }
        AutoType.shared.register()
#if E2E
        E2EProbe.start(controller: controller)
#endif
    }

    static let categories: Set<UNNotificationCategory> = {
        let mute = UNNotificationAction(identifier: "mute", title: "Mute This App")
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        return [
            UNNotificationCategory(identifier: "otp", actions: [UNNotificationAction(identifier: "copy", title: "Copy Code")], intentIdentifiers: []),
            UNNotificationCategory(identifier: "notification", actions: [mute], intentIdentifiers: [], options: .customDismissAction),
            UNNotificationCategory(identifier: "notification.reply", actions: [reply, mute], intentIdentifiers: [], options: .customDismissAction),
            UNNotificationCategory(identifier: "link", actions: [UNNotificationAction(identifier: "open", title: "Open", options: .foreground)], intentIdentifiers: []),
            UNNotificationCategory(identifier: "file", actions: [UNNotificationAction(identifier: "accept", title: "Accept"),
                                                                  UNNotificationAction(identifier: "decline", title: "Decline", options: .destructive)], intentIdentifiers: []),
            UNNotificationCategory(identifier: "saved", actions: [UNNotificationAction(identifier: "show", title: "Show in Finder")], intentIdentifiers: []),
        ]
    }()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let info = content.userInfo.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
        let category = content.categoryIdentifier, action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            self.respond(category: category, action: action, info: info, text: text)
            completionHandler()
        }
    }

    func respond(category: String, action: String, info: [String: String], text: String?) {
        let tapped = action == UNNotificationDefaultActionIdentifier
        switch category {
        case "otp": if tapped || action == "copy" { OtpVault.shared.copy() }
        case "link": if tapped || action == "open", let url = info["url"] { EventRouter.open(url) }
        case "saved":
            if tapped || action == "show", let path = info["path"] { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        case "file":
            if let id = info["transferId"], action == "accept" || action == "decline" {
                EventRouter.answerOffer(id, accept: action == "accept", controller: controller)
            }
        case "notification", "notification.reply":
            if let key = info["key"] {
                NotificationMirror.shared.respond(action, key: key, pkg: info["pkg"], reply: info["reply"].flatMap { Int($0) }, text: text)
            }
        default: break
        }
    }
}
