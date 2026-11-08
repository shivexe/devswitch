import AppKit
import SwiftUI

@main
struct DevSwitchApp: App {
    init() {
        if CommandLine.arguments.contains("--doctor") { exit(Dependencies.doctor()) }
        if NativeHost.isHostInvocation { exit(NativeHost.run()) }
    }
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app
    var body: some Scene {
        MenuBarExtra {
            MenuPanel(controller: app.controller, screen: app.controller.screen)
        } label: {
            MenuBarLabel(controller: app.controller, screen: app.controller.screen)
        }.menuBarExtraStyle(.window)
        Window("DevSwitch Settings", id: "pairing") {
            SettingsView(controller: app.controller, screen: app.controller.screen)
                .frame(minWidth: 680, idealWidth: 720, minHeight: 480, idealHeight: app.controller.phone == nil ? 760 : 640)
        }.windowResizability(.contentSize)
        Window("New Message", id: "sms") {
            SmsComposerView(controller: app.controller)
        }.windowResizability(.contentSize)
    }
}
