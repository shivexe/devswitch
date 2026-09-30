import Foundation
import Darwin

// Constructed and read on the main thread; Foundation delivers delegate calls on that run loop.
final class BonjourDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]
    private(set) var failure: String?
    private(set) var endpoints: [String: String] = [:]
    override init() {
        super.init()
    }
    func refresh() {
        browser.delegate = nil; browser.stop()
        for service in services.values { service.delegate = nil; service.stop() }
        services.removeAll(); endpoints.removeAll(); failure = nil
        UserDefaults.standard.removeObject(forKey: "discovery.lastError")
        UserDefaults.standard.removeObject(forKey: "discovery.lastResolvedAt")
        browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: "_adb-tls-connect._tcp.", inDomain: "local.")
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard browser === self.browser else { return }
        UserDefaults.standard.set(errorDict.mapValues { $0.intValue }, forKey: "discovery.lastError")
        failure = "Local discovery failed. Check DevSwitch's Local Network permission or restart DevSwitch, then retry."
        NSLog("DevSwitch Bonjour search failed: %@", errorDict)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        services[service.name]?.stop()
        services[service.name] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        services.removeValue(forKey: service.name)?.stop()
        endpoints.removeValue(forKey: service.name)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard services[sender.name] === sender, (1...65535).contains(sender.port) else { return }
        for data in sender.addresses ?? [] {
            let host: String? = data.withUnsafeBytes { buffer in
                guard buffer.count >= MemoryLayout<sockaddr_in>.size, let base = buffer.baseAddress else { return nil }
                let address = base.assumingMemoryBound(to: sockaddr.self)
                guard address.pointee.sa_family == UInt8(AF_INET) else { return nil }
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(data.count), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: name)
            }
            if let host {
                endpoints[sender.name] = "\(host):\(sender.port)"
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "discovery.lastResolvedAt")
                return
            }
        }
    }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard services[sender.name] === sender else { return }
        UserDefaults.standard.set(errorDict.mapValues { $0.intValue }, forKey: "discovery.lastResolveError")
        endpoints.removeValue(forKey: sender.name)
    }
}
