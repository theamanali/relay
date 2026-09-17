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
    /// PC facts from the TXT record (`cpu`, `ram`, `gpu`, `os`, `ip`); informational.
    var facts = HostFacts()

    /// Wired interface to pin the connection to, when the host was seen on one.
    var wiredInterface: NWInterface? { interfaces.first { $0.type == .wiredEthernet } }

    /// This Mac's interfaces the host was seen on, in the order the connection
    /// prefers them (cable first, since the dial is pinned to it).
    private var rankedInterfaces: [NWInterface] {
        interfaces
            .filter { $0.type != .loopback }
            .sorted { Self.rank($0.type) < Self.rank($1.type) }
    }

    /// Every link the PC is reachable on from this Mac, in dial order (cable,
    /// then Wi-Fi, …), each with the PC address on that interface's subnet.
    /// Tailscale and other-network addresses never match and so never appear.
    var reachableAddresses: [(link: String, address: String)] {
        reachableAddresses(subnets: LocalNetworks.subnetsByInterface())
    }

    func reachableAddresses(subnets: [String: [IPv4Subnet]]) -> [(link: String, address: String)] {
        var out: [(String, String)] = []
        for interface in rankedInterfaces {
            if let ip = LocalNetworks.address(among: facts.ips, reachedVia: [interface.name], subnets: subnets),
               !out.contains(where: { $0.1 == ip }) {
                out.append((Self.label(interface), ip))
            }
        }
        return out
    }

    /// The link the connection will use — the first reachable one, or the top
    /// interface when no address lines up — so the row and card agree.
    var connectLink: String {
        connectLink(subnets: LocalNetworks.subnetsByInterface())
    }

    func connectLink(subnets: [String: [IPv4Subnet]]) -> String {
        if let first = reachableAddresses(subnets: subnets).first { return first.link }
        guard let top = rankedInterfaces.first else { return "This MacBook" }
        return Self.label(top)
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
        case .loopback: return "This MacBook"
        case .other: return i.name.hasPrefix("utun") ? "VPN" : i.name
        @unknown default: return i.name
        }
    }
}

/// What the host says about itself in its TXT record. Anything missing is empty.
struct HostFacts: Equatable {
    var cpu = ""
    var ramGB = 0
    var gpu = ""
    var os = ""
    var ips: [String] = []

    init() {}

    init(txt: NWTXTRecord) {
        cpu = txt["cpu"] ?? ""
        ramGB = Int(txt["ram"] ?? "") ?? 0
        gpu = txt["gpu"] ?? ""
        os = txt["os"] ?? ""
        ips = (txt["ip"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// Label / value pairs for the hover card.
    var rows: [(label: String, value: String)] {
        var out: [(String, String)] = []
        if !os.isEmpty { out.append(("Windows:", os)) }
        if !cpu.isEmpty { out.append(("CPU:", cpu)) }
        if ramGB > 0 { out.append(("RAM:", "\(ramGB) GB")) }
        if !gpu.isEmpty { out.append(("GPU:", gpu)) }
        return out
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
        var facts = HostFacts()
        if case .bonjour(let txt) = result.metadata {
            if let hex = txt["pk"], let data = Data(hex: hex), data.count == 32 { key = data }
            facts = HostFacts(txt: txt)
        }
        var host = DiscoveredHost(name: name, endpoint: result.endpoint, interfaces: result.interfaces, publicKey: key)
        host.facts = facts
        return host
    }
}
