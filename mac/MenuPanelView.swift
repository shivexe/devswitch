import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MenuPanel: View {
    @ObservedObject var controller: Controller
    @ObservedObject var screen: ScreenControl
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var vault = OtpVault.shared
    @ObservedObject private var mirror = NotificationMirror.shared
    /// The message set with the last successful receipt; the tiles already show that change.
    @State private var confirmed = ""
    @State private var ringStarted: Date?
    @State private var dropping = false
    private var active: Bool {
        guard let status = controller.status else { return false }
        return status.developer || status.usb || status.wifi
    }
    private var canChange: Bool { controller.online && controller.pending == nil && controller.status?.permission == true }
    private func settings() {
        NSApp.activate(ignoringOtherApps: true); openWindow(id: "pairing")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
            VStack(spacing: 8) {
                if controller.phone == nil {
                    pairModule
                } else {
                    controlModule
                    developmentModule
                    if let latest = vault.latest { codeModule(latest.source, latest.at) }
                    quickActions
                }
            }.padding(.horizontal, 10)
            if let status = statusLine {
                Label { Text(status.text).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: status.icon).foregroundStyle(status.warning ? Color.orange : .secondary)
                }.font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(2)
                    .padding(.horizontal, 14).padding(.top, 10)
            }
            Divider().padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 5)
            MenuRow(title: "Settings…", action: settings)
            MenuRow(title: "Quit DevSwitch", shortcut: "⌘Q") { controller.screen.stop(); NSApp.terminate(nil) }
                .keyboardShortcut("q")
            Spacer().frame(height: 6)
        }.frame(width: 320).font(.system(size: 13))
            .overlay {
                if dropping {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(Label("Send to \(controller.phone?.name ?? "phone")", systemImage: "arrow.up.doc").font(.system(size: 13, weight: .semibold)))
                        .padding(6).allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard controller.phone != nil, urls.contains(where: \.isFileURL) else { return false }
                controller.sendFiles(urls); return true
            } isTargeted: { dropping = $0 && controller.phone != nil }
            .onChange(of: controller.lastReceipt) { _, receipt in
                guard let receipt else { return }
                if ["enable", "disable"].contains(receipt.action) { confirmed = receipt.ok ? controller.message : "" }
                if receipt.action == "ring", !receipt.ok { ringStarted = nil }
            }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ModuleGlyph(systemImage: "iphone", state: controller.online ? .on : .off, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.phone?.name ?? "DevSwitch").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if controller.phone == nil {
                    Text("No phone paired").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 5) {
                        StatusDot(online: controller.online)
                        Text(controller.online ? "Connected" : "Offline")
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if controller.online, let status = controller.status { PhoneBadges(status: status) }
        }.accessibilityElement(children: .combine)
    }

    private var pairModule: some View {
        let confirming = !controller.comparison.isEmpty
        return VStack(spacing: 6) {
            ModuleGlyph(systemImage: confirming ? "checkmark.shield" : "qrcode", state: .on, size: 44).padding(.bottom, 4)
            Text(confirming ? "Confirm pairing" : "Pair your Android phone").font(.system(size: 13, weight: .semibold))
            Text(confirming ? "\(controller.candidateName) is waiting. Compare the codes in Settings."
                            : "Scan a code with DevSwitch on your phone to control it from this Mac.")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(confirming ? "Open Settings…" : "Pair Phone…", action: settings)
                .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 8)
        }.padding(.horizontal, 18).padding(.vertical, 18).frame(maxWidth: .infinity)
            .background(Color.moduleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.moduleStroke))
    }

    @ViewBuilder private var controlModule: some View {
        if screen.trustLost {
            ModuleTile(title: "Re-pair Phone Control", glyph: "exclamationmark", state: .warning,
                       action: { screen.pairWithQR(controller: controller); settings() }) {
                Text("Your phone forgot this Mac. Scan a new code.")
            } accessory: { EmptyView() }
                .disabled(screen.busy || !controller.online)
        } else if screen.isPaired(controller.phone?.id) {
            ModuleTile(title: screen.running ? "Controlling Phone" : screen.busy ? "Connecting…" : "Control Phone",
                       glyph: "iphone.gen3", state: screen.running ? .on : screen.busy ? .busy : .off,
                       action: { if screen.running || screen.busy { screen.stop() } else { screen.start(controller: controller) } }) {
                Text(screen.running ? "Close the phone window to stop."
                     : screen.busy ? screen.message
                     : controller.online ? "Use it with your mouse and keyboard." : "Available when your phone is online.")
                    .lineLimit(3)
            } accessory: {
                if screen.running { Text("Stop") } else if screen.busy { Text("Cancel") }
                else { Image(systemName: "arrow.up.forward.app").font(.system(size: 13)) }
            }
            .disabled(!screen.running && !screen.busy && (!controller.online || controller.pending != nil))
        } else {
            ModuleTile(title: "Set Up Phone Control…", glyph: "iphone.gen3", action: settings) {
                Text("Pair once with a QR code to mirror and control your phone.")
            } accessory: { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)) }
        }
    }

    private var developmentModule: some View {
        let status = controller.status
        let all = status.map { $0.developer && $0.usb && $0.wifi } ?? false
        // While a change is pending the status line below says what is happening.
        let trailing = controller.pending != nil || status == nil ? "" : all ? "On" : active ? "Partly on" : "Off"
        return ModuleTile(title: "Development", glyph: "chevron.left.forwardslash.chevron.right",
                          state: controller.pending != nil ? .busy : active ? .on : .off,
                          action: { controller.send(active ? "disable" : "enable") }) {
            if let status {
                HStack(spacing: 8) {
                    indicator("Developer", status.developer)
                    indicator("USB", status.usb)
                    indicator("Wireless", status.wifi)
                }.padding(.top, 1)
                if !controller.online { Text("Last known state") }
            } else {
                Text(controller.online ? "Waiting for your phone…" : "Unknown until your phone connects.")
            }
        } accessory: { Text(trailing) }
            .disabled(!canChange)
            .accessibilityValue(controller.pending != nil ? "Updating" : trailing)
    }

    // The digits stay in the HUD, the clipboard and Helium; the panel names only the sender.
    private func codeModule(_ source: String, _ at: Date) -> some View {
        ModuleTile(title: "Code from \(source)", glyph: "number", state: .on, action: { vault.copy() }) {
            // .relative reads "0 secs ago" at first; one redraw at the 5 s mark swaps "just now" for it.
            TimelineView(.explicit([at.addingTimeInterval(5)])) { _ in
                if Date().timeIntervalSince(at) < 5 { Text("Received just now · ⌃⌥V types it") }
                else { Text("Received \(at, style: .relative) ago · ⌃⌥V types it") }
            }
        } accessory: { Text("Copy") }
    }

    private var quickActions: some View {
        let ringing = ringStarted.map { Date().timeIntervalSince($0) < 60 } ?? false
        return HStack(spacing: 8) {
            QuickAction(title: ringing ? "Stop" : "Find", glyph: "bell.and.waves.left.and.right", state: ringing ? .on : .off) {
                controller.ring(!ringing); ringStarted = ringing ? nil : Date()
            }
            QuickAction(title: "Message", glyph: "message") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "sms") }
            QuickAction(title: "Send File", glyph: "doc") { chooseFile() }
            QuickAction(title: "Send Clipboard", glyph: "doc.on.clipboard") { controller.message = ClipboardSync.shared.send(manual: true) }
                .help("Send the text you copied on this Mac to your phone, ready to paste.")
        }.disabled(!controller.online)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "Send"; panel.message = "Choose a file to send to \(controller.phone?.name ?? "your phone")."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { controller.sendFiles(panel.urls) }
    }

    private func indicator(_ name: String, _ on: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(on ? Color.accentColor : Color.clear).frame(width: 6, height: 6)
                .overlay(Circle().strokeBorder(on ? Color.clear : Color.secondary.opacity(0.6), lineWidth: 1))
            Text(name).lineLimit(1)
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(name): \(on ? "on" : "off")")
    }

    // One message at a time, most important first.
    private var statusLine: (text: String, icon: String, warning: Bool)? {
        guard controller.phone != nil else {
            return controller.message.isEmpty || !controller.comparison.isEmpty ? nil : (controller.message, "info.circle", false)
        }
        if !controller.online { return ("Open DevSwitch on your phone and keep both devices on the same Wi-Fi.", "wifi.exclamationmark", true) }
        if controller.status?.permission == false { return ("DevSwitch on your phone lost its settings permission. Open the phone app to restore it.", "exclamationmark.triangle", true) }
        if mirror.enabled && controller.status?.listenerConnected == false { return ("Notification access is off on your phone. Allow it in the DevSwitch phone app to mirror notifications and codes.", "bell.slash", true) }
        if !screen.busy && !screen.running && !screen.trustLost && !screen.message.isEmpty { return (screen.message, "info.circle", false) }
        // A confirmed change is already visible in the Development tile; only show progress and failures.
        if let receipt = controller.lastReceipt, !receipt.ok, controller.message == receipt.failure {
            return (controller.message, "exclamationmark.triangle", true)
        }
        if !controller.message.isEmpty && controller.message != confirmed {
            return (controller.message, controller.pending == nil ? "info.circle" : "arrow.triangle.2.circlepath", false)
        }
        if screen.isPaired(controller.phone?.id) && !active { return ("Control Phone turns on development automatically.", "bolt", false) }
        return nil
    }
}

// Compact status item: phone glyph, plus battery % once the phone reports it.
struct MenuBarLabel: View {
    @ObservedObject var controller: Controller
    @ObservedObject var screen: ScreenControl
    var body: some View {
        let symbol = screen.running ? "iphone.and.arrow.forward" : controller.online ? "iphone" : "iphone.slash"
        HStack(spacing: 3) {
            Image(nsImage: menuBarSymbol(symbol, dimmed: controller.phone != nil && !controller.online))
            if let battery = controller.status?.battery, controller.online { Text("\(battery)%").monospacedDigit() }
        }.accessibilityLabel(controller.phone == nil ? "DevSwitch" : controller.online ? "Phone connected" : "Phone offline")
    }
}

// Menu bar extras ignore SwiftUI opacity, so the dimmed state is baked into a template image.
func menuBarSymbol(_ name: String, dimmed: Bool) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
    let image = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.45 : 1)
        return true
    }
    image.isTemplate = true
    return image
}

extension Controller {
    /// Find My Phone: the phone rings at alarm volume until stopped or for 60 s.
    func ring(_ on: Bool) {
        enqueue(OutgoingCommand(on ? "ring" : "stopRing"))
        requestHotPolling(for: 30)
    }

    /// Offers the first file to the phone; the file channel carries one transfer at a time.
    func sendFiles(_ urls: [URL]) {
        guard let url = urls.first(where: \.isFileURL) else { return }
        do {
            _ = try files.offerToPhone(file: url)
            message = "Sending \(url.lastPathComponent) to your phone…"
        } catch { message = error.localizedDescription }
    }
}
