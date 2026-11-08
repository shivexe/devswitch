import SwiftUI

/// Latest `smsStatus` per sendSms command id (sent, delivered or failed). Memory only.
@MainActor final class SmsResults: ObservableObject {
    static let shared = SmsResults()
    @Published private(set) var results: [String: String] = [:]
    func receive(_ event: PhoneEvent) {
        guard let id = event.string("commandId"), let result = event.string("result"), results[id] != "failed" else { return }
        if results.count > 50 { results = [:] }
        // A multipart message counts as failed if any part fails.
        if result == "failed" || results[id] != "delivered" { results[id] = result }
    }
}

/// "New message" window. The draft lives only in view state and is never written to disk.
struct SmsComposerView: View {
    @ObservedObject var controller: Controller
    @ObservedObject private var results = SmsResults.shared
    @State private var to = ""
    @State private var text = ""
    @State private var sim: Int?
    @State private var sentID: String?
    private var number: String { to.filter { !" -()".contains($0) } }
    private var valid: Bool {
        let digits = number.hasPrefix("+") ? number.dropFirst() : Substring(number)
        return (3...15).contains(digits.count) && digits.allSatisfy { $0.isASCII && $0.isNumber } && !text.isEmpty && text.count <= 1600
    }
    private var state: String? {
        guard let sentID else { return nil }
        if let result = results.results[sentID] {
            return result == "failed" ? "Your phone could not send the message." : result == "delivered" ? "Delivered." : "Sent."
        }
        if let receipt = controller.lastReceipt, receipt.id == sentID {
            return receipt.ok ? "Sending from your phone…" : "Not sent: \(receipt.message)"
        }
        return controller.queue.contains { $0.id == sentID } ? "Waiting for your phone…" : "No answer from your phone. Check it is online and retry."
    }
    var body: some View {
        Form {
            TextField("To", text: $to, prompt: Text("Phone number"))
            if let sims = controller.status?.sims, sims.count > 1 {
                Picker("SIM", selection: $sim) {
                    Text("Default").tag(Int?.none)
                    ForEach(sims, id: \.subId) { Text($0.name).tag(Int?.some($0.subId)) }
                }
            }
            Section {
                TextEditor(text: $text).font(.body).frame(minHeight: 120)
                    .accessibilityLabel("Message")
            } footer: {
                HStack {
                    if let state { Text(state).fixedSize(horizontal: false, vertical: true) }
                    Spacer()
                    Text("\(text.count)/1600").monospacedDigit().foregroundStyle(text.count > 1600 ? .red : .secondary)
                }
            }
            HStack {
                if !controller.online { Text("Your phone is offline.").foregroundStyle(.secondary) }
                Spacer()
                Button("Send", action: send).buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!valid || !controller.online)
            }
        }.formStyle(.grouped).frame(minWidth: 380, idealWidth: 420, minHeight: 360)
            .onChange(of: results.results[sentID ?? ""]) { _, result in if result == "sent" || result == "delivered" { text = "" } }
    }
    private func send() {
        var fields: [String: JSONValue] = ["to": .string(number), "body": .string(text)]
        if let sim { fields["subId"] = .number(Double(sim)) }
        let command = OutgoingCommand("sendSms", fields)
        controller.enqueue(command)
        sentID = command.id
    }
}
