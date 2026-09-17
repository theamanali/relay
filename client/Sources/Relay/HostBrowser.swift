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
                out.append((Self.linkLabel(interface.type, address: ip), ip))
            }
        }
        return out
    }

    /// A wired link where the PC had to self-assign its address had no DHCP
    /// server on it: the cable runs straight to this MacBook (or through a
    /// bare switch, which amounts to the same thing).
    static func linkLabel(_ type: NWInterface.InterfaceType, address: String) -> String {
        if type == .wiredEthernet, address.hasPrefix("169.254.") { return "Direct cable" }
        return label(type)
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
        if i.type == .other { return i.name.hasPrefix("utun") ? "VPN" : i.name }
        return label(i.type)
    }

    private static func label(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wiredEthernet: return "Ethernet"
        case .wifi: return "Wi-Fi"
        case .cellular: return "Cellular"
        case .loopback: return "This MacBook"
        case .other: return "VPN"
        @unknown default: return "Other"
        }
    }
}

/// What the host says about itself in its TXT record. Anything missing is empty.
struct HostFacts: Equatable {
    var cpu = ""
    var ramGB = 0
    var ramType = ""
    var gpu = ""
    var vramGB = 0
    var os = ""
    var ips: [String] = []

    init() {}

    init(txt: NWTXTRecord) {
        cpu = txt["cpu"] ?? ""
        ramGB = Int(txt["ram"] ?? "") ?? 0
        ramType = txt["ramtype"] ?? ""
        gpu = txt["gpu"] ?? ""
        vramGB = Int(txt["vram"] ?? "") ?? 0
        os = txt["os"] ?? ""
        ips = (txt["ip"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// Label / value pairs for the hover card.
    var rows: [(label: String, value: String)] {
        var out: [(String, String)] = []
        if !os.isEmpty { out.append(("Windows:", os)) }
        if !cpu.isEmpty { out.append(("CPU:", cpu)) }
        if ramGB > 0 { out.append(("RAM:", ramType.isEmpty ? "\(ramGB) GB" : "\(ramGB) GB \(ramType)")) }
        if !gpu.isEmpty { out.append(("GPU:", vramGB > 0 ? "\(gpu) \(vramGB) GB" : gpu)) }
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

/// Keeps a host in the list for a grace period after Bonjour stops seeing
/// it, so a host that re-registers (the PC re-advertising new addresses) or a
/// brief Wi-Fi flap does not make its row vanish and slide back in. Pure, so
/// it can be tested without a network.
struct HostListDebouncer {
    let grace: TimeInterval
    private var lastSeen: [String: (host: DiscoveredHost, vanishedAt: Date?)] = [:]

    init(grace: TimeInterval = 2.5) {
        self.grace = grace
    }

    /// Feed the hosts Bonjour currently reports; returns what to show.
    mutating func update(seen: [DiscoveredHost], now: Date) -> [DiscoveredHost] {
        let seenNames = Set(seen.map(\.name))
        for host in seen {
            lastSeen[host.name] = (host, nil)
        }
        for (name, entry) in lastSeen where !seenNames.contains(name) {
            if let since = entry.vanishedAt {
                if now.timeIntervalSince(since) >= grace { lastSeen[name] = nil }
            } else {
                lastSeen[name] = (entry.host, now)
            }
        }
        return lastSeen.values.map(\.host).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// True while some host is being held past its disappearance.
    var hasPendingRemovals: Bool {
        lastSeen.values.contains { $0.vanishedAt != nil }
    }
}

final class HostBrowser {
    var onChange: (([DiscoveredHost]) -> Void)?
    var onStatus: ((String) -> Void)?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "relay.browse")
    private var debouncer = HostListDebouncer()
    private var latest: [DiscoveredHost] = []
    private var flush: DispatchWorkItem?

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
            self.latest = results.compactMap(Self.host(from:))
            self.publish()
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Run the debouncer over the latest results and, while it is holding a
    /// vanished host, come back after the grace period to let it go.
    private func publish() {
        let hosts = debouncer.update(seen: latest, now: Date())
        DispatchQueue.main.async { self.onChange?(hosts) }
        flush?.cancel()
        flush = nil
        if debouncer.hasPendingRemovals {
            let work = DispatchWorkItem { [weak self] in self?.publish() }
            flush = work
            queue.asyncAfter(deadline: .now() + debouncer.grace + 0.1, execute: work)
        }
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
