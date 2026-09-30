import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins
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

@main
struct DevSwitchApp: App {
    init() {
        if CommandLine.arguments.contains("--doctor") { exit(Dependencies.doctor()) }
    }
    @StateObject private var controller = Controller()
    var body: some Scene {
        MenuBarExtra("DevSwitch", systemImage: controller.online ? "iphone.radiowaves.left.and.right" : "iphone.slash") {
            MenuPanel(controller: controller, screen: controller.screen)
        }.menuBarExtraStyle(.window)
        Window("DevSwitch · Connection settings", id: "pairing") {
            ScrollView {
                PairingView(controller: controller, screen: controller.screen).padding(28)
            }.frame(width: 500, height: controller.phone == nil ? 740 : 620)
                .background(Color(nsColor: .windowBackgroundColor))
        }.windowResizability(.contentSize)
    }
}

private struct PanelButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 42)
            .foregroundStyle(primary ? Color.white : Color.primary)
            .background(primary ? Color.accentColor : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct MenuPanel: View {
    @ObservedObject var controller: Controller
    @ObservedObject var screen: ScreenControl
    @Environment(\.openWindow) private var openWindow
    private var active: Bool {
        guard let status = controller.status else { return false }
        return status.developer || status.usb || status.wifi
    }
    private var canChange: Bool { controller.online && controller.pending == nil && controller.status?.permission == true }
    private func settings() {
        NSApp.activate(ignoringOtherApps: true); openWindow(id: "pairing")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "switch.2").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("DevSwitch").font(.system(size: 15, weight: .semibold))
                    Text(controller.phone?.name ?? "Your phone, on your Mac").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(controller.online ? Color.green : Color.secondary).frame(width: 6, height: 6)
                    Text(controller.online ? "Online" : "Offline").font(.system(size: 11, weight: .medium))
                }.padding(.horizontal, 9).padding(.vertical, 6).background(.quaternary, in: Capsule())
            }
            if controller.phone == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Bring your phone closer.").font(.system(size: 22, weight: .semibold))
                    Text("Control your Android and switch development settings from your Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
                Button(action: settings) { Label("Pair phone", systemImage: "qrcode") }.buttonStyle(PanelButtonStyle(primary: true))
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(controller.online ? "DEVELOPMENT" : "LAST KNOWN STATE")
                                .font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary)
                            Text(controller.status == nil ? "Waiting for phone" : active ? "Development is on" : "Development is off")
                                .font(.system(size: 20, weight: .semibold))
                        }
                        Spacer(minLength: 4)
                        Image(systemName: active ? "terminal" : "moon")
                            .font(.system(size: 22, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    if let status = controller.status {
                        HStack(spacing: 6) {
                            stateChip("Developer", status.developer)
                            stateChip("USB", status.usb)
                            stateChip("Wireless", status.wifi)
                        }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                VStack(spacing: 8) {
                    if screen.isPaired(controller.phone?.id) {
                        Button {
                            if screen.running || screen.busy { screen.stop() } else { screen.start(controller: controller) }
                        } label: {
                            HStack(spacing: 8) {
                                if screen.busy { ProgressView().controlSize(.small).tint(.white) }
                                else { Image(systemName: screen.running ? "stop.fill" : "display") }
                                Text(screen.running ? "Stop sharing" : screen.busy ? "Cancel connection" : "Control phone")
                                Spacer()
                                if !screen.running && !screen.busy { Image(systemName: "arrow.up.right").font(.caption) }
                            }.padding(.horizontal, 14)
                        }.buttonStyle(PanelButtonStyle(primary: true))
                            .disabled(!screen.running && !screen.busy && (!controller.online || controller.pending != nil))
                            .opacity(!screen.running && !screen.busy && !controller.online ? 0.5 : 1)
                    } else {
                        Button(action: settings) { Label("Set up wireless control", systemImage: "display") }.buttonStyle(PanelButtonStyle(primary: true))
                    }
                    Button { controller.send(active ? "disable" : "enable") } label: {
                        HStack(spacing: 8) {
                            if controller.pending != nil { ProgressView().controlSize(.small) }
                            else { Image(systemName: "power") }
                            Text(controller.pending != nil ? "Updating development…" : active ? "Disable development" : "Enable development")
                        }
                    }.buttonStyle(PanelButtonStyle()).disabled(!canChange).opacity(canChange ? 1 : 0.5)
                }
                if !controller.online {
                    notice("Open DevSwitch on your phone and connect both devices to the same Wi-Fi.", icon: "wifi.exclamationmark")
                } else if controller.status?.permission == false {
                    notice("Open the phone app to restore its settings permission.", icon: "exclamationmark.circle")
                } else if screen.busy || screen.running || !screen.message.isEmpty {
                    notice(screen.message, icon: screen.running ? "display" : "info.circle")
                } else if !controller.message.isEmpty {
                    notice(controller.message, icon: "checkmark.circle")
                } else {
                    notice("Control phone enables development automatically.", icon: "bolt")
                }
            }
            Divider()
            HStack {
                Button(action: settings) { Label("Connection settings", systemImage: "gearshape") }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { controller.screen.stop(); NSApp.terminate(nil) } label: { Image(systemName: "power").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Quit DevSwitch").accessibilityLabel("Quit DevSwitch").keyboardShortcut("q")
            }
        }.padding(20).frame(width: 350).font(.system(size: 13)).foregroundStyle(.primary)
            .background(Color(nsColor: .windowBackgroundColor)).tint(.blue)
    }
    private func stateChip(_ name: String, _ on: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: on ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(on ? Color.accentColor : .secondary)
            Text(name).lineLimit(1)
        }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.primary.opacity(0.045), in: Capsule()).accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name): \(on ? "on" : "off")")
    }
    private func notice(_ text: String, icon: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon) }
            .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
    }
}

struct PairingView: View {
    @ObservedObject var controller: Controller
    @ObservedObject var screen: ScreenControl
    @State private var address = localAddresses().first ?? ""
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""
    @State private var showForget = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "switch.2").font(.title).foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connection settings").font(.system(size: 23, weight: .semibold))
                    Text("DevSwitch · Your devices, connected").font(.callout).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 8)
            if let phone = controller.phone {
                HStack {
                    Label(phone.name, systemImage: "iphone").font(.headline)
                    Spacer()
                    Label(controller.online ? "Connected" : "Offline", systemImage: controller.online ? "checkmark.circle.fill" : "circle")
                        .font(.caption).foregroundStyle(controller.online ? Color.green : .secondary)
                }.padding(16).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                Text(controller.online ? "Your phone is connected. Use the menu bar icon to switch development on or off." : "Open DevSwitch on your phone and keep both devices on the same Wi-Fi network.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                WirelessSetupView(screen: screen, phoneID: phone.id, phoneEndpoint: controller.status?.wifiEndpoint)
                    .padding(18).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                Divider()
                Form {
                    Toggle("Launch at login", isOn: $login).onChange(of: login) { _, enabled in
                        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = "" }
                        catch { loginError = error.localizedDescription; login = SMAppService.mainApp.status == .enabled }
                    }
                }
                if !loginError.isEmpty { Text(loginError).font(.caption).foregroundStyle(.red) }
                Button("Forget this phone…", role: .destructive) { showForget = true }
                    .confirmationDialog("Forget this phone?", isPresented: $showForget) {
                        Button("Forget phone", role: .destructive) { controller.unpair() }
                    } message: { Text("This stops sharing and removes DevSwitch pairing. To also revoke Android wireless debugging access, forget this Mac under Wireless debugging → Paired devices on your phone.") }
            } else if !controller.comparison.isEmpty {
                Text("Confirm your phone").font(.headline)
                Text("Check that DevSwitch on \(controller.candidateName) shows the same code.").fixedSize(horizontal: false, vertical: true)
                Text(controller.comparison).font(.system(size: 38, weight: .semibold, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity)
                HStack {
                    Button("Cancel") { controller.cancelPairing() }
                    Spacer()
                    Button("Codes match — pair") { controller.approve() }.buttonStyle(.borderedProminent)
                }
            } else {
                Text("Pair your Android phone").font(.headline)
                Text("On your phone, open DevSwitch → Mac connection → Scan Mac QR code. Keep both devices on the same Wi-Fi.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let invitation = controller.invitation, let image = qr(invitation) {
                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 320, height: 320).padding(24).background(.white).frame(maxWidth: .infinity)
                        .accessibilityLabel("Pairing QR code; a copyable invitation is also available below")
                    HStack {
                        Button("Copy invitation") {
                            if let data = try? JSONEncoder().encode(invitation), let value = String(data: data, encoding: .utf8) {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
                            }
                        }
                        Spacer()
                        Button("New code") { controller.makeInvitation(address: address) }
                    }
                    Text("Code expires after five minutes. Approve pairing only when both codes match.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Show pairing code") { controller.makeInvitation(address: address) }
                        .buttonStyle(.borderedProminent).disabled(address.isEmpty || !controller.serverReady)
                }
                DisclosureGroup("Network") {
                    Picker("Mac address", selection: $address) {
                        ForEach(localAddresses(), id: \.self) { Text($0).tag($0) }
                    }.onChange(of: address) { _, _ in controller.makeInvitation(address: address) }
                }
            }
            DependencyView()
            if !controller.message.isEmpty { Text(controller.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.onAppear { if controller.phone == nil && controller.invitation == nil && !address.isEmpty { controller.makeInvitation(address: address) } }
    }
    private func qr(_ invitation: Invitation) -> NSImage? {
        guard let data = try? JSONEncoder().encode(invitation) else { return nil }
        let filter = CIFilter.qrCodeGenerator(); filter.message = data; filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct WirelessSetupView: View {
    @ObservedObject var screen: ScreenControl
    let phoneID: String
    let phoneEndpoint: String?
    @State private var address = ""
    @State private var code = ""
    @State private var connectionAddress = ""
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(screen.isPaired(phoneID) ? "Wireless control paired" : "Set up wireless screen control", systemImage: "display")
                .font(.headline)
            if screen.needsConnectionAddress {
                Text("Close the pairing-code dialog on your phone. Copy IP address & Port from the main Wireless debugging page.").font(.callout).foregroundStyle(.secondary)
                Text("Connection address").font(.caption.weight(.medium))
                TextField("192.168.1.10:12345", text: $connectionAddress).textFieldStyle(.roundedBorder).controlSize(.large)
                Button("Finish setup") { screen.finishPair(address: connectionAddress) }.disabled(screen.busy || ScreenControl.endpoint(connectionAddress) == nil)
            } else if !screen.isPaired(phoneID) || expanded {
                Text("On your phone: Settings → Developer options → Wireless debugging → Pair device with pairing code. Keep that dialog open.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Pairing address").font(.caption.weight(.medium))
                TextField("192.168.1.10:12345", text: $address).textFieldStyle(.roundedBorder).controlSize(.large)
                    .accessibilityLabel("Pairing address")
                Text("Six-digit code").font(.caption.weight(.medium))
                SecureField("000000", text: $code).textFieldStyle(.roundedBorder).controlSize(.large)
                    .accessibilityLabel("Pairing code")
                Button(screen.busy ? "Pairing…" : "Pair wireless control") {
                    screen.pair(address: address, code: code, phoneID: phoneID, connectionEndpoint: phoneEndpoint); code = ""
                }.buttonStyle(.borderedProminent).disabled(screen.busy || screen.running || code.count != 6 || ScreenControl.endpoint(address) == nil)
            } else {
                Text("Control phone opens a live screen with mouse, keyboard, and audio over Wi-Fi.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Pair again…") { expanded = true }
            }
            if !screen.message.isEmpty { Text(screen.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
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
        DisclosureGroup("Dependencies") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(checks) { check in
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(check.detail)
                            if let path = check.path { Text(path).font(.caption).textSelection(.enabled).foregroundStyle(.secondary) }
                        }
                    } icon: {
                        Image(systemName: check.ready ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(check.ready ? Color.green : Color.orange)
                    }
                }
                if checks.contains(where: { !$0.ready }) {
                    Text(Dependencies.installHint).font(.caption.monospaced()).textSelection(.enabled)
                }
                Button(checking ? "Checking…" : "Check again") { Task { await refresh() } }.disabled(checking)
            }.padding(.top, 8)
        }.task { await refresh() }
    }
}
