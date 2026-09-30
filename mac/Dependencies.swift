import Foundation
import Darwin

struct DependencyCheck: Identifiable {
    let name: String
    let path: String?
    let detail: String
    let ready: Bool
    var id: String { name }
}

enum Dependencies {
    static let installHint = "Install with: brew install --cask android-platform-tools && brew install scrcpy"
    struct Missing: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // Finder apps do not inherit the user's interactive shell PATH.
    static func locate(_ name: String) throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let key = "DEVSWITCH_\(name.uppercased())"
        let settings = Bundle.main.bundleIdentifier == "dev.notsg.devswitch"
            ? UserDefaults.standard : UserDefaults(suiteName: "dev.notsg.devswitch")
        if let override = environment[key] ?? settings?.string(forKey: "tools.\(name)Path"), !override.isEmpty {
            guard usable(override) else {
                throw Missing(message: "\(name): configured path is not an executable file: \(override). Update \(key) or tools.\(name)Path.")
            }
            return override
        }
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        if name == "adb" {
            for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
                if let sdk = environment[key], sdk.hasPrefix("/") { directories.append(sdk + "/platform-tools") }
            }
            directories.append(FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Android/sdk/platform-tools")
        }
        for directory in directories {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if usable(path) { return path }
        }
        throw Missing(message: "\(name) was not found. \(installHint). Open Connection settings → Dependencies to check again.")
    }

    private static func usable(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    static func inspect() -> [DependencyCheck] {
        ["adb", "scrcpy"].map { name in
            var path: String?
            do {
                let executable = try locate(name); path = executable
                let process = Process(); let output = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = [name == "adb" ? "version" : "--version"]
                process.standardOutput = output; process.standardError = output
                process.standardInput = FileHandle.nullDevice
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                let forceStop = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: timeout)
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: forceStop)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); timeout.cancel(); forceStop.cancel()
                let lines = String(decoding: data.prefix(8192), as: UTF8.self).split(separator: "\n").map(String.init)
                let prefix = name == "adb" ? "Version " : "scrcpy "
                let version = lines.first { $0.hasPrefix(prefix) }?.dropFirst(prefix.count).split(separator: " ").first.map(String.init)
                let major = version?.split(separator: ".").first.flatMap { Int($0) } ?? 0
                let minimum = name == "adb" ? 30 : 2
                let ready = process.terminationStatus == 0 && major >= minimum
                let detail = ready ? "\(name) \(version!)" : "Could not verify \(name) \(minimum)+. Update or check this executable."
                return DependencyCheck(name: name, path: path, detail: detail, ready: ready)
            } catch { return DependencyCheck(name: name, path: path, detail: error.localizedDescription, ready: false) }
        }
    }

    @discardableResult
    static func doctor() -> Int32 {
        let platformOK = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0))
        print("DevSwitch doctor\n\(platformOK ? "OK" : "FAIL") macOS 14 or newer")
        let checks = inspect()
        for check in checks {
            print("\(check.ready ? "OK" : "FAIL") \(check.detail)")
            if let path = check.path { print("  \(path)") }
        }
        let ready = platformOK && checks.allSatisfy(\.ready)
        print(ready ? "Dependencies ready. Phone pairing and network access are checked in the app." : installHint)
        return ready ? 0 : 1
    }
}
