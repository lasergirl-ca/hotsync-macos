import Foundation

/// Die IPv4-Adressen dieses Macs, für den Netzwerk-HotSync: der Palm
/// braucht die Adresse des "primären PCs". WLAN und Ethernet zuerst,
/// Loopback und Link-Local nie.
enum LocalAddress {
    struct Address: Equatable {
        let interface: String
        let ip: String
    }

    static func ipv4() -> [Address] {
        var list: [Address] = []
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0, entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buffer)
            if ip.hasPrefix("169.254.") { continue }
            list.append(Address(interface: String(cString: entry.pointee.ifa_name), ip: ip))
        }
        // en0/en1 (WLAN, Ethernet) vor VPN- und Bridge-Schnittstellen
        return list.sorted { a, b in
            let ra = a.interface.hasPrefix("en") ? 0 : 1
            let rb = b.interface.hasPrefix("en") ? 0 : 1
            return ra != rb ? ra < rb : a.interface < b.interface
        }
    }
}
