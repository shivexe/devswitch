import Foundation

@main struct MacTests {
    @MainActor static func main() {
        codecTests()
        serverTests()
        controllerTests()
        fileChannelTests()
        print("\(checks) checks, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }
}
