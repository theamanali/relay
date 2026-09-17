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

    /// The link the connection will use: the cable when the host is seen on
    /// one (the dial is pinned to it), otherwise the best of the rest.
    var preferredLink: String {
        let ranked = interfaces
            .filter { $0.type != .loopback }
            .sorted { Self.rank($0.type) < Self.rank($1.type) }
        guard let best = ranked.first else { return "This Mac" }
        return Self.label(best)
    }

    /// Every link the announcement arrived on, loopback aside (for the tooltip).
    var allLinks: String {
        let kinds = interfaces.filter { $0.type != .loopback }.map(Self.label)
        let unique = Array(NSOrderedSet(array: kinds)) as? [String] ?? kinds
        return unique.isEmpty ? "This Mac" : unique.joined(separator: ", ")
    }

    private static func rank(_ type: NWInterface.InterfaceType) -> Int {
        switch type {
        case .wiredEthernet: return 0
        case .wifi: return 1
        case .other: return 2
        case .cellular: return 3
        default: return 4
        }
    }

    private static func label(_ i: NWInterface) -> String {
        switch i.type {
        case .wiredEthernet: return "Ethernet"
        case .wifi: return "Wi-Fi"
        case .cellular: return "Cellular"
        case .loopback: return "This Mac"
        case .other: return i.name.hasPrefix("utun") ? "VPN" : i.name
        @unknown default: return i.name
        }
    }
}

/// Splits discovered hosts into paired and not. Only the advertised identity
/// key counts: a host that does not advertise one is never assumed paired.
enum PairingClassifier {
    static func classify(_ hosts: [DiscoveredHost], known: [Data: String]) -> (paired: [DiscoveredHost], unpaired: [DiscoveredHost]) {
        var paired: [DiscoveredHost] = []
        var unpaired: [DiscoveredHost] = []
        for host in hosts {
            if let key = host.publicKey, known[key] != nil {
                paired.append(host)
            } else {
                unpaired.append(host)
            }
        }
        return (paired, unpaired)
    }

    /// Identity the handshake must present for a host the user paired before.
    static func expectedKey(for host: DiscoveredHost, known: [Data: String]) -> Data? {
        guard let advertised = host.publicKey, known[advertised] != nil else { return nil }
        return advertised
    }
}

final class HostBrowser {
    var onChange: (([DiscoveredHost]) -> Void)?
    var onStatus: ((String) -> Void)?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "relay.browse")

    func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        // Plain .bonjour never fetches TXT; the host's identity key lives there.
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Proto.serviceType, domain: nil), using: params)
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
