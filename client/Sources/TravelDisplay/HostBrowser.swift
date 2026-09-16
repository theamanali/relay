// Continuous Bonjour discovery for the picker. The host's TXT record may
// carry its identity key (`pk`, 64 hex chars); until every host advertises
// it, a remembered service name is the fallback for "paired". The handshake
// verifies the real key either way, so a wrong guess only costs a PIN prompt.

import Foundation
import Network

struct DiscoveredHost {
    let name: String
    let endpoint: NWEndpoint
    let interfaces: [NWInterface]
    /// From TXT `pk`, when the host advertises it.
    let publicKey: Data?

    /// Wired interface to pin the connection to, when the host was seen on one.
    var wiredInterface: NWInterface? { interfaces.first { $0.type == .wiredEthernet } }

    /// Short description of how the host is reachable.
    var linkDescription: String {
        let kinds = interfaces.map { i -> String in
            switch i.type {
            case .wiredEthernet: return "Ethernet"
            case .wifi: return "Wi-Fi"
            case .cellular: return "Cellular"
            case .loopback: return "Local"
            default: return i.name
            }
        }
        let unique = Array(NSOrderedSet(array: kinds)) as? [String] ?? kinds
        return unique.joined(separator: ", ")
    }
}

/// Splits discovered hosts into paired and not, using the identity key when
/// advertised and the remembered service name otherwise.
enum PairingClassifier {
    struct Entry {
        let host: DiscoveredHost
        /// True when pairing was inferred from the name alone.
        let byNameOnly: Bool
    }

    static func classify(_ hosts: [DiscoveredHost], known: [Data: String]) -> (paired: [Entry], unpaired: [DiscoveredHost]) {
        let names = Set(known.values.filter { !$0.isEmpty })
        var paired: [Entry] = []
        var unpaired: [DiscoveredHost] = []
        for host in hosts {
            if let key = host.publicKey {
                if known[key] != nil { paired.append(Entry(host: host, byNameOnly: false)) } else { unpaired.append(host) }
            } else if names.contains(host.name) {
                paired.append(Entry(host: host, byNameOnly: true))
            } else {
                unpaired.append(host)
            }
        }
        return (paired, unpaired)
    }
}

final class HostBrowser {
    var onChange: (([DiscoveredHost]) -> Void)?
    var onStatus: ((String) -> Void)?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "traveldisplay.browse")

    func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Proto.serviceType, domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let err) = state {
                self.report("Bonjour browse failed: \(err.localizedDescription) — retrying")
                self.queue.asyncAfter(deadline: .now() + 2) { self.start() }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let hosts = results.compactMap(Self.host(from:)).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self.onChange?(hosts) }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private func report(_ s: String) {
        DispatchQueue.main.async { self.onStatus?(s) }
    }

    static func host(from result: NWBrowser.Result) -> DiscoveredHost? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var key: Data?
        if case .bonjour(let txt) = result.metadata, let hex = txt["pk"], let data = Data(hex: hex), data.count == 32 {
            key = data
        }
        return DiscoveredHost(name: name, endpoint: result.endpoint, interfaces: result.interfaces, publicKey: key)
    }
}
