import AppKit
import SwiftUI

/// Borderless floating panel that takes clicks without activating DevSwitch or stealing focus.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    convenience init() {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar; isFloatingPanel = true; hidesOnDeactivate = false; isRestorable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false; backgroundColor = .clear; hasShadow = true; isMovableByWindowBackground = true
    }
    /// Shows `view` in the top-right corner of the active screen, like a system banner.
    func present<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        contentView = host
        let size = host.fittingSize
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        setFrame(NSRect(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }
}

/// Shows the code with a Copy button for 10 seconds. The digits live only in this view.
@MainActor final class OtpHUD {
    static let shared = OtpHUD()
    private let panel = FloatingPanel()
    private var hide: DispatchWorkItem?
    var visible: Bool { panel.isVisible }

    func show(code: String, source: String) {
        panel.present(OtpHUDView(code: code, source: source, copy: { OtpVault.shared.copy(); self.close() }, close: { self.close() }))
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    func close() {
        hide?.cancel(); hide = nil
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

struct OtpHUDView: View {
    let code: String
    let source: String
    let copy: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            ModuleGlyph(systemImage: "number", state: .on, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Code from \(source)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Text(code).font(.system(size: 26, weight: .semibold, design: .monospaced)).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button("Copy", action: copy).buttonStyle(.borderedProminent)
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Close")
        }.padding(14).frame(width: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.moduleStroke))
    }
}
