import Foundation
import Darwin

enum LocalNetwork {
    static func isLinkLocal(_ host: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
        return withUnsafeBytes(of: address) { $0[0] == 0xfe && ($0[1] & 0xc0) == 0x80 }
    }

    // Select the Mac interface on the phone's IPv4 subnet, then use its IPv6 link.
    static func link(for peer: String?) -> (host: String, interface: String)? {
        guard let peer else { return nil }
        var remote = in_addr()
        guard inet_pton(AF_INET, peer, &remote) == 1 else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var interfaces = Set<String>()
        var links: [(host: String, interface: String)] = []
        var next = list
        while let item = next {
            defer { next = item.pointee.ifa_next }
            let value = item.pointee
            guard value.ifa_flags & UInt32(IFF_UP) != 0,
                  value.ifa_flags & UInt32(IFF_LOOPBACK) == 0, let address = value.ifa_addr else { continue }
            let name = String(cString: value.ifa_name)
            if address.pointee.sa_family == UInt8(AF_INET), let mask = value.ifa_netmask {
                let local = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                if local & netmask == remote.s_addr & netmask { interfaces.insert(name) }
            } else if address.pointee.sa_family == UInt8(AF_INET6) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let literal = String(cString: host).components(separatedBy: "%")[0]
                    if isLinkLocal(literal) { links.append((literal, name)) }
                }
            }
        }
        return links.first { interfaces.contains($0.interface) }
    }

    static func phoneEndpoint(_ status: PhoneStatus?) -> String? {
        guard let status, let raw = status.wifiIPv6Endpoint,
              let parsed = ScreenControl.endpoint(raw),
              let link = link(for: status.lanIPv4), raw.hasPrefix("[") else { return nil }
        let host = String(parsed.host.dropFirst().dropLast()).components(separatedBy: "%")[0]
        return "[\(host)%\(link.interface)]:\(parsed.port)"
    }
}
