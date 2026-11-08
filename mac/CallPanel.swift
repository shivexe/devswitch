import AppKit
import SwiftUI

/// Incoming-call panel, top-right like a FaceTime banner. It does not activate DevSwitch or take focus.
@MainActor final class CallPanel: ObservableObject {
    static let shared = CallPanel()
    weak var controller: Controller?
    struct Call { let id: String; let name: String; let number: String }
    @Published private(set) var call: Call?
    @Published private(set) var sent: Set<String> = []
    private let panel = FloatingPanel()
    private var timeout: DispatchWorkItem?
    var visible: Bool { panel.isVisible }

    func update(_ event: PhoneEvent) {
        guard let id = event.string("callId"), !id.isEmpty else { return }
        guard event.string("state") == "ringing" else {
            if call == nil || call?.id == id { close() }
            return
        }
        let number = event.string("number") ?? ""
        call = Call(id: id, name: event.string("name").flatMap { $0.isEmpty ? nil : $0 } ?? (number.isEmpty ? "Unknown caller" : number), number: number)
        sent = []
        panel.present(CallPanelView(panel: self))
        // A lost idle event must not leave the panel up forever.
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
    }

    func decline() { send("declineCall") }
    func silence() { send("silenceCall") }

    // OutgoingCommand gives call actions a 15 s TTL; hot polling gets them to the phone within 500 ms.
    private func send(_ action: String) {
        guard let call, let controller, !sent.contains(action) else { return }
        controller.enqueue(OutgoingCommand(action, ["callId": .string(call.id)]))
        controller.requestHotPolling(for: 30)
        sent.insert(action)
    }

    func close() {
        timeout?.cancel(); timeout = nil
        call = nil; sent = []
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

struct CallPanelView: View {
    @ObservedObject var panel: CallPanel
    var body: some View {
        HStack(spacing: 12) {
            ModuleGlyph(systemImage: "phone.fill", state: .on, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Incoming call").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(panel.call?.name ?? "").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if let number = panel.call?.number, !number.isEmpty, number != panel.call?.name {
                    Text(number).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(panel.sent.contains("silenceCall") ? "Silenced" : "Silence") { panel.silence() }
                .disabled(!panel.sent.isEmpty).controlSize(.large)
            Button(panel.sent.contains("declineCall") ? "Declining…" : "Decline") { panel.decline() }
                .buttonStyle(.borderedProminent).tint(.red).disabled(panel.sent.contains("declineCall")).controlSize(.large)
        }.padding(14).frame(width: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.moduleStroke))
    }
}
