// The Mac's own IPv4 subnets, per interface, so the picker can tell which of
// a PC's advertised addresses it will actually dial: the one on the subnet of
// the interface Bonjour saw the PC on.

import Darwin
import Foundation

struct IPv4Subnet: Equatable {
    let address: UInt32
    let mask: UInt32

    func contains(_ ip: String) -> Bool {
        guard let other = IPv4Subnet.parse(ip) else { return false }
        return (other & mask) == (address & mask)
    }

    static func parse(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }
}

enum LocalNetworks {
    /// Interface name (en0, en5, …) → its IPv4 subnets.
    static func subnetsByInterface() -> [String: [IPv4Subnet]] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var out: [String: [IPv4Subnet]] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.pointee.ifa_netmask else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            out[name, default: []].append(IPv4Subnet(address: a, mask: m))
        }
        return out
    }

    /// Of `candidates` (a PC's advertised IPv4s), the one this Mac would dial:
    /// on the subnet of the first of `interfaces` (in preference order) that
    /// has one. Nil when nothing lines up.
    static func address(among candidates: [String], reachedVia interfaces: [String],
                        subnets: [String: [IPv4Subnet]] = subnetsByInterface()) -> String? {
        for name in interfaces {
            for subnet in subnets[name] ?? [] {
                if let hit = candidates.first(where: subnet.contains) { return hit }
            }
        }
        return nil
    }
}
