import AppKit
import SwiftUI
import ServiceManagement
import Darwin

func localAddresses() -> [String] {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0 else { return [] }
    defer { freeifaddrs(pointer) }
    var result: [(String, String)] = []
    var item = pointer
    while let current = item {
        let info = current.pointee; item = info.ifa_next
        guard let address = info.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
              info.ifa_flags & UInt32(IFF_UP) != 0, info.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(cString: host)
            if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || (ip.hasPrefix("172.") && (16...31).contains(Int(ip.split(separator: ".")[1]) ?? 0)) {
                result.append((String(cString: info.ifa_name), ip))
            }
        }
    }
    return result.sorted { ($0.0.hasPrefix("en") ? 0 : 1, $0.0) < ($1.0.hasPrefix("en") ? 0 : 1, $1.0) }.map(\.1)
}

// Sidebar panes, like System Settings.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, phone, notifications, clipboard, advanced
    var id: Self { self }
    var title: String {
        switch self {
        case .general: return "General"
        case .phone: return "Phone"
        case .notifications: return "Notifications"
        case .clipboard: return "Clipboard & Files"
        case .advanced: return "Advanced"
        }
    }
    var icon: (symbol: String, color: Color) {
        switch self {
        case .general: return ("gearshape.fill", .gray)
        case .phone: return ("iphone", .blue)
        case .notifications: return ("bell.badge.fill", .red)
        case .clipboard: return ("doc.on.clipboard.fill", .orange)
        case .advanced: return ("wrench.and.screwdriver.fill", .gray)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: Controller
    @ObservedObject var screen: ScreenControl
    @State var pane: SettingsPane = .phone
    @State private var address = localAddresses().first ?? ""
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""
    @State private var showForget = false
    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    Image(systemName: pane.icon.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(pane.icon.color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }.tag(pane)
            }.frame(minWidth: 200).navigationSplitViewColumnWidth(200).toolbar(removing: .sidebarToggle)
        } detail: {
            Form {
                switch pane {
                case .general: generalPane
                case .phone: phonePane
                case .notifications: NotificationSettings(controller: controller)
                case .clipboard: ClipboardSettings(controller: controller)
                case .advanced: DependencyView()
                }
            }.formStyle(.grouped).navigationTitle(pane.title)
        }
        .onAppear { if controller.phone == nil && controller.invitation == nil && !address.isEmpty { controller.makeInvitation(address: address) } }
    }

    @ViewBuilder private var generalPane: some View {
        Section {
            Toggle("Launch at login", isOn: $login).onChange(of: login) { _, enabled in
                do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = "" }
                catch { loginError = error.localizedDescription; login = SMAppService.mainApp.status == .enabled }
            }
            if !loginError.isEmpty { Text(loginError).font(.caption).foregroundStyle(.red) }
        }
        AutofillSettings()
    }

    @ViewBuilder private var phonePane: some View {
        if let phone = controller.phone {
            Section {
                HStack(spacing: 12) {
                    ModuleGlyph(systemImage: "iphone", state: controller.online ? .on : .off, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phone.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(controller.online ? "Use the menu bar to control your phone." : "Open DevSwitch on your phone and keep both devices on the same Wi-Fi.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    HStack(spacing: 5) { StatusDot(online: controller.online); Text(controller.online ? "Connected" : "Offline") }
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            } footer: { messageFooter }
            Section {
                WirelessSetupView(screen: screen, controller: controller)
            } header: { Text("Phone control") } footer: {
                if !screen.message.isEmpty { Text(screen.message).fixedSize(horizontal: false, vertical: true) }
            }
            Section {
                LabeledContent {
                    Button("Forget Phone…") { showForget = true }
                } label: {
                    Text("Forget this phone")
                    Text("Removes the pairing from this Mac's Keychain.")
                }
                    .confirmationDialog("Forget this phone?", isPresented: $showForget) {
                        Button("Forget Phone", role: .destructive) { controller.unpair() }
                    } message: { Text("This stops sharing and removes DevSwitch pairing. To also revoke Android wireless debugging access, forget this Mac under Wireless debugging → Paired devices on your phone.") }
            }
        } else if !controller.comparison.isEmpty {
            Section {
                VStack(spacing: 14) {
                    Text("\(controller.candidateName) wants to connect").font(.system(size: 15, weight: .semibold))
                    Text("Check that DevSwitch on the phone shows the same code.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text(spacedCode(controller.comparison))
                        .font(.system(size: 34, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        .padding(.vertical, 6)
                    HStack {
                        Button("Cancel") { controller.cancelPairing() }.controlSize(.large)
                        Spacer()
                        Button("Codes Match — Pair") { controller.approve() }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 8)
            } header: { Text("Confirm pairing") } footer: { messageFooter }
        } else {
            Section {
                VStack(spacing: 16) {
                    if let invitation = controller.invitation, let image = qr(invitation) {
                        QRCard(image: image, size: 200)
                            .accessibilityLabel("Pairing QR code; a copyable invitation is also available below")
                    } else {
                        Button("Show Pairing Code") { controller.makeInvitation(address: address) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(address.isEmpty || !controller.serverReady)
                    }
                    StepList(steps: ["Open DevSwitch on your Android phone.",
                                     "Tap Mac connection, then Scan Mac QR code.",
                                     "Check both screens show the same six digits, then approve here."])
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let invitation = controller.invitation {
                        HStack {
                            Button("Copy Invitation") {
                                if let data = try? JSONEncoder().encode(invitation), let value = String(data: data, encoding: .utf8) {
                                    copyConcealed(value)
                                }
                            }
                            Spacer()
                            Button("New Code") { controller.makeInvitation(address: address) }
                        }
                    }
                }.padding(.vertical, 8)
            } header: { Text("Pair a phone") } footer: {
                Text(controller.message.isEmpty ? "Keep both devices on the same Wi-Fi. The code expires after five minutes." : controller.message)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Network") {
                Picker("Mac address", selection: $address) {
                    ForEach(localAddresses(), id: \.self) { Text($0).tag($0) }
                }.onChange(of: address) { _, _ in controller.makeInvitation(address: address) }
            }
        }
    }
    @ViewBuilder private var messageFooter: some View {
        if !controller.message.isEmpty { Text(controller.message).fixedSize(horizontal: false, vertical: true) }
    }
    private func spacedCode(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
    private func qr(_ invitation: Invitation) -> NSImage? {
        guard let data = try? JSONEncoder().encode(invitation) else { return nil }
        return qrImage(data)
    }
}

struct WirelessSetupView: View {
    @ObservedObject var screen: ScreenControl
    @ObservedObject var controller: Controller
    @State private var code = ""
    @State private var address = ""
    @State private var expanded = false
    @State private var useCode = false
    var body: some View {
        let paired = screen.isPaired(controller.phone?.id) && !screen.trustLost
        LabeledContent {
            if screen.trustLost {
                Label("Needs re-pairing", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if paired {
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("Not set up").foregroundStyle(.secondary)
            }
        } label: {
            Text("Wireless control")
            Text("Mirror and control the phone with your mouse and keyboard.")
        }
        if let payload = screen.qrPayload {
            VStack(spacing: 16) {
                if let image = qrImage(Data(payload.utf8)) {
                    QRCard(image: image, size: 180).accessibilityLabel("Wireless debugging pairing QR code")
                }
                StepList(steps: ["On your phone, open Settings → Developer options → Wireless debugging.",
                                 "Tap Pair device with QR code and scan this code."])
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") { screen.stop() }
            }.frame(maxWidth: .infinity).padding(.vertical, 8)
        } else if paired && !expanded {
            HStack {
                Text("Pair again if your phone was reset or stops accepting this Mac.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Pair Again…") { expanded = true }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                StepList(steps: ["On your phone, turn on Wireless debugging and allow this network.",
                                 "Show the code here, then scan it from Pair device with QR code."])
                Button("Show QR Code") { expanded = false; screen.pairWithQR(controller: controller) }
                    .buttonStyle(.borderedProminent).disabled(screen.busy || screen.running || !controller.online)
            }.padding(.vertical, 4)
            DisclosureGroup("Use a pairing code instead", isExpanded: $useCode) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On your phone: Wireless debugging → Pair device with pairing code. Keep that dialog open.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    SecureField("Six-digit code", text: $code).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Pairing code")
                    if screen.needsPairingAddress {
                        TextField("IP address & Port, e.g. 192.168.1.10:12345", text: $address).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Pairing address")
                    }
                    Button(screen.busy ? "Pairing…" : "Pair with Code") {
                        expanded = false
                        screen.pairWithCode(code, address: screen.needsPairingAddress ? address : nil, controller: controller); code = ""
                    }.disabled(screen.busy || screen.running || code.count != 6 || (screen.needsPairingAddress && ScreenControl.endpoint(address) == nil))
                }.padding(.top, 8)
            }
        }
    }
}

// Phone codes: Helium autofill through the extension, and ⌃⌥V auto-type through Accessibility.
struct AutofillSettings: View {
    @ObservedObject private var autoType = AutoType.shared
    @State private var installMessage = ""
    var body: some View {
        Section {
            LabeledContent {
                Button("Install…", action: install)
            } label: {
                Text("Helium extension")
                Text("Shows “From your phone” with the code under one-time-code fields.")
            }
        } header: { Text("Browser autofill") } footer: {
            Text(installMessage.isEmpty ? "Installs the native host and copies the extension to Application Support. In Helium, open chrome://extensions, turn on Developer mode, then Load unpacked and choose the copied folder." : installMessage)
                .fixedSize(horizontal: false, vertical: true)
        }
        Section {
            LabeledContent {
                if autoType.trusted {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Allow…") { autoType.requestAccess() }
                }
            } label: {
                Text("Type code with ⌃⌥V")
                Text("Types the latest phone code into the focused field in any app.")
            }
        } footer: {
            if !autoType.trusted {
                Text("Needs Accessibility. If DevSwitch is already listed in System Settings → Privacy & Security → Accessibility but this still says off, remove it with − and allow it again.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.onAppear { autoType.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in autoType.refresh() }
    }
    private func install() {
        do {
            let folder = try NativeHost.installExtensionFolder()
            try NativeHost.installHostManifest(extensionID: NativeHost.extensionID)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            installMessage = "Installed. In Helium, open chrome://extensions, turn on Developer mode, choose Load unpacked, and select the highlighted extension folder."
        } catch { installMessage = "Could not install: \(error.localizedDescription)" }
    }
}

struct NotificationSettings: View {
    @ObservedObject var controller: Controller
    @ObservedObject private var mirror = NotificationMirror.shared
    @State private var search = ""
    var body: some View {
        Section {
            Toggle(isOn: $mirror.enabled) {
                Text("Mirror phone notifications")
                Text("Every app except the ones muted below.")
            }
            Toggle(isOn: $mirror.showContent) {
                Text("Show message content")
                Text("macOS keeps notification text in its own database. Turn off to show only the app name.")
            }.disabled(!mirror.enabled)
            if controller.status?.listenerConnected == false {
                Label("Notification access is off on your phone. Allow it in the DevSwitch phone app.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } footer: { Text("Verification codes never appear in notifications. They show only in the code panel, Helium, and the clipboard.") }
        Section {
            let apps = mirror.apps.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
                .filter { search.isEmpty || $0.value.localizedCaseInsensitiveContains(search) || $0.key.localizedCaseInsensitiveContains(search) }
            if mirror.apps.count > 8 { TextField("Search apps", text: $search) }
            if mirror.apps.isEmpty {
                Text("Apps appear here after their first notification.").foregroundStyle(.secondary)
            }
            ForEach(apps, id: \.key) { app in
                Toggle(isOn: Binding(get: { !mirror.muted.contains(app.key) }, set: { mirror.setMuted(app.key, !$0) })) {
                    Text(app.value)
                    Text(app.key)
                }
            }
        } header: { Text("Apps") } footer: { Text("Muted apps are filtered on the phone too, so their content never leaves it.") }
            .disabled(!mirror.enabled)
    }
}

struct ClipboardSettings: View {
    @ObservedObject var controller: Controller
    @ObservedObject private var clipboard = ClipboardSync.shared
    @State private var sentClipboard = false
    @State private var sentFile = false
    var body: some View {
        Section {
            Toggle(isOn: $clipboard.enabled) {
                Text("Send Mac clipboard to phone")
                Text("Copied text goes to your phone automatically. Passwords and private items are skipped.")
            }.disabled(clipboard.blocked)
            LabeledContent {
                Button("Send Now") { controller.message = clipboard.send(manual: true); sentClipboard = true }.disabled(controller.phone == nil)
            } label: {
                Text("Send clipboard to phone")
                Text("Also Send Clipboard in the menu bar panel. From the phone: the “Send clipboard to Mac” Quick Settings tile, or Share › Send to Mac.")
            }
        } header: { Text("Clipboard") } footer: {
            if clipboard.blocked {
                Text("macOS asks before apps read the clipboard, so automatic sending is off. Send Now still works.")
            } else if sentClipboard { Text(controller.message) }
        }
        Section {
            LabeledContent {
                Button("Show in Finder") {
                    if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                        NSWorkspace.shared.open(downloads)
                    }
                }
            } label: {
                Text("Received files")
                Text("Saved to Downloads after you accept them. macOS checks them like any download.")
            }
            LabeledContent {
                Button("Choose File…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false; panel.prompt = "Send"
                    if panel.runModal() == .OK { controller.sendFiles(panel.urls); sentFile = true }
                }.disabled(controller.phone == nil)
            } label: {
                Text("Send a file to your phone")
                Text("Or drop a file on the menu bar panel. It lands in Downloads/DevSwitch on the phone.")
            }
        } header: { Text("Files") } footer: { if sentFile { Text(controller.message) } }
    }
}

struct DependencyView: View {
    @State private var checks: [DependencyCheck] = []
    @State private var checking = false
    private func refresh() async {
        checking = true
        checks = await Task.detached { Dependencies.inspect() }.value
        checking = false
    }
    var body: some View {
        Section {
            ForEach(checks) { check in
                LabeledContent {
                    Image(systemName: check.ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(check.ready ? Color.green : Color.orange)
                } label: {
                    Text(check.detail)
                    if let path = check.path { Text(path).textSelection(.enabled) }
                }
            }
            HStack {
                if checks.contains(where: { !$0.ready }) {
                    Text(Dependencies.installHint).font(.caption.monospaced()).textSelection(.enabled)
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(checking ? "Checking…" : "Check Again") { Task { await refresh() } }.disabled(checking)
            }
        } header: { Text("Dependencies") }
            .task { await refresh() }
    }
}
