import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// ⌃⌥V types the latest phone code into the focused field. Registering the hotkey needs no permission;
/// posting the key events needs Accessibility, which macOS ties to the app's code signature.
@MainActor final class AutoType: ObservableObject {
    static let shared = AutoType()
    @Published private(set) var trusted = AXIsProcessTrusted()
    private var hotKey: EventHotKeyRef?

    func register() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { AutoType.shared.typeCode() }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey | optionKey), EventHotKeyID(signature: OSType(0x4453_5754), id: 1),
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    func refresh() { trusted = AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt, which links to System Settings.
    func requestAccess() {
        trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func typeCode() {
        refresh()
        guard trusted else { requestAccess(); return }
        guard let code = OtpVault.shared.current()?.code else { NSSound.beep(); return }
        let source = CGEventSource(stateID: .privateState)
        for unit in code.utf16 {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                var character = unit
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
                event.flags = [] // ⌃⌥ are still held from the hotkey
                event.post(tap: .cghidEventTap)
            }
        }
        OtpVault.shared.consume()
    }
}
