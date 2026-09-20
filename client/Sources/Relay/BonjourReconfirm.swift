// Asks mDNSResponder to re-check a host's Bonjour record after a dial to it
// found nobody there. A PC unplugged or powered off without a goodbye stays
// in every Mac's cache until its records' TTL runs out (up to two minutes,
// measured 2026-09-20); Apple's guidance for exactly this case is to
// reconfirm the record, which re-queries it a few times and flushes it, and
// the browser's row with it, within a second or two if the host is silent.

import Foundation
import Network
import dnssd

enum BonjourReconfirm {
    /// Reconfirm the PTR that lists `host` under its service type, on each
    /// link it was seen on. The PTR is the record the browse is built on:
    /// gone, the host is gone from the list. A live host answers the
    /// re-query and nothing changes.
    static func reconfirm(_ host: DiscoveredHost) {
        guard case .service(let name, let type, let domain, _) = host.endpoint,
              let rdata = wireName(labels: [name] + labels(of: type) + labels(of: domain)) else { return }
        let recordName = (labels(of: type) + labels(of: domain)).joined(separator: ".") + "."
        for index in Set(host.interfaces.map(\.index)) {
            let err = rdata.withUnsafeBytes { bytes in
                DNSServiceReconfirmRecord(
                    0, UInt32(index), recordName,
                    UInt16(kDNSServiceType_PTR), UInt16(kDNSServiceClass_IN),
                    UInt16(bytes.count), bytes.baseAddress
                )
            }
            NSLog("BonjourReconfirm: %@ on interface %d -> %d", name, index, err)
        }
    }

    /// "_relay._tcp" / "local." -> ["_relay", "_tcp"] / ["local"].
    static func labels(of dnsName: String) -> [String] {
        dnsName.split(separator: ".").map(String.init).filter { !$0.isEmpty }
    }

    /// A DNS name in wire format: length-prefixed UTF-8 labels and a root
    /// byte, no compression. Nil when a label or the whole name is too long.
    static func wireName(labels: [String]) -> Data? {
        var out = Data()
        for label in labels {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else { return nil }
            out.append(UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(0)
        return out.count <= 255 ? out : nil
    }
}
