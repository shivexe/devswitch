import Foundation
import Security

// Tiny test runner: no XCTest, so the suite builds with plain swiftc next to mac/*.swift.
nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var checks = 0
nonisolated(unsafe) var currentTest = ""

func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: String = #fileID, line: Int = #line) {
    checks += 1
    do { if try !condition() { failures.append("\(currentTest): \(file):\(line) \(message())") } }
    catch { failures.append("\(currentTest): \(file):\(line) threw \(error) \(message())") }
}
func expectThrows(_ message: String, file: String = #fileID, line: Int = #line, _ body: () throws -> Any?) {
    checks += 1
    if (try? body()) != nil { failures.append("\(currentTest): \(file):\(line) expected a throw: \(message)") }
}
@MainActor func test(_ name: String, _ body: () throws -> Void) {
    currentTest = name
    let before = failures.count
    do { try body() } catch { failures.append("\(name): threw \(error)") }
    print(failures.count == before ? "PASS \(name)" : "FAIL \(name)")
    for failure in failures[before...] { print("     \(failure)") }
}
/// Spins the main run loop (server callbacks, main-actor tasks) until `done` or the timeout.
@MainActor func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

// Keychain stand-ins: module functions shadow Security's, so Controller never touches the real pairing item.
func SecItemCopyMatching(_ q: CFDictionary, _ r: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { errSecItemNotFound }
func SecItemUpdate(_ q: CFDictionary, _ a: CFDictionary) -> OSStatus { errSecItemNotFound }
func SecItemAdd(_ q: CFDictionary, _ r: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { errSecSuccess }
func SecItemDelete(_ q: CFDictionary) -> OSStatus { errSecSuccess }

// Test replacement for mac/EventRouter.swift (owned by workstream c): records what the Controller routes.
@MainActor final class EventRouter {
    static var routed: [PhoneEvent] = []
    init(controller: Controller) {}
    func handle(_ event: PhoneEvent) { Self.routed.append(event) }
    static func fileSaved(_ url: URL, from phone: String?) {}
}

// ---- shared vectors

let repoRoot: URL = {
    var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: url.appendingPathComponent("test-vectors").path) { url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath) }
    return url
}()
func vector(_ name: String) throws -> [String: Any] {
    let data = try Data(contentsOf: repoRoot.appendingPathComponent("test-vectors/\(name)"))
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}
func hex(_ s: String) -> Data {
    var data = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); data.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return data
}
func b64(_ s: String) -> Data { Data(base64Encoded: s)! }
