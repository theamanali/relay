// Continuous Bonjour discovery for the picker. The host's TXT record carries
// its identity key (`pk`, 64 hex chars); a host counts as paired only when
// that key is in hosts.txt, never by name. The handshake verifies the real
// key either way, so the TXT record is never trusted on its own.

import Foundation
import Network

struct DiscoveredHost {
    let name: String
    let endpoint: NWEndpoint
    let interfaces: [NWInterface]
    /// From TXT `pk`, when the host advertises it.
    var publicKey: Data?
    /// From TXT `pg`: the host's pairing digest, which moves whenever it
    /// pairs or forgets a client. A known host advertising a digest other
    /// than the one last verified is asked, over the handshake alone,
    /// whether it still knows this Mac (see `PairingVerifier`).
    var pairingDigest: String?
    /// False when Bonjour reported the service with no TXT record at all —
    /// the shape of a goodbye (the TXT is flushed a beat before the PTR), and
    /// also of a link going away (see `HostListDebouncer`).
    var hasTXT = true
    /// Names of `interfaces` (en0, en7, …). `NWInterface` cannot be built by
    /// hand, so the debouncer compares these; `host(from:)` fills them in.
    var links: Set<String> = []
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

    /// The link the connection will use, so the row and card agree: the
    /// cable whenever the host was seen on one (the dial is pinned to it and
    /// resolves over IPv6 link-local, so it needs no IPv4 to line up — right
    /// after a plug-in there is none yet), else the first reachable link,
    /// else the top interface.
    var connectLink: String {
        connectLink(subnets: LocalNetworks.subnetsByInterface())
    }

    func connectLink(subnets: [String: [IPv4Subnet]]) -> String {
        if let wired = wiredInterface {
            let ip = LocalNetworks.address(among: facts.ips, reachedVia: [wired.name], subnets: subnets)
            return Self.linkLabel(.wiredEthernet, address: ip ?? "")
        }
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
///
/// The one exception is a goodbye: when the host quits, its TXT goodbye
/// (cache-flush, TTL 0) lands a beat before the PTR removal, so NWBrowser
/// briefly reports the service with no TXT record. A host that advertised a
/// `pk` and now has no TXT at all is only ever that stale cache entry — never
/// a real unpaired PC — so it is dropped at once rather than re-filed under
/// Available for the length of the hold.
///
/// A TXT-less report has a second cause, told apart by the interfaces the
/// host is seen on changing in the same update: a link went away. When the
/// cable is unplugged, mDNSResponder purges everything it learned on that
/// interface; the PTR usually survives on Wi-Fi but the TXT was cached on the
/// cable alone, and it is not re-fetched until its TTL runs out (measured:
/// 53 s on Wi-Fi with no TXT, until the cable came back). The host is still
/// there, so its last-known key and facts are carried forward instead.
struct HostListDebouncer {
    let grace: TimeInterval
    private var lastSeen: [String: (host: DiscoveredHost, vanishedAt: Date?)] = [:]
    /// TXT withdrawals may be a re-registration, not shutdown. Keep the last
    /// row through grace, without renewing it from repeated TXT-less reports.
    private var saidGoodbye: Set<String> = []

    init(grace: TimeInterval = 2.5) {
        self.grace = grace
    }

    /// Feed the hosts Bonjour currently reports; returns what to show.
    mutating func update(seen: [DiscoveredHost], now: Date) -> [DiscoveredHost] {
        let seenNames = Set(seen.map(\.name))
        saidGoodbye = saidGoodbye.intersection(seenNames)
        for var host in seen {
            if !host.hasTXT, saidGoodbye.contains(host.name) { continue }
            let previous = lastSeen[host.name]?.host
            if Self.isGoodbye(host, previous: previous) {
                if let previous { lastSeen[host.name] = (previous, now) }
                saidGoodbye.insert(host.name)
                continue
            }
            if !host.hasTXT, let previous, previous.publicKey != nil {
                // A link change (or a report after one): keep what the TXT said.
                host.publicKey = previous.publicKey
                host.pairingDigest = previous.pairingDigest
                host.facts = previous.facts
            }
            saidGoodbye.remove(host.name)
            lastSeen[host.name] = (host, nil)
        }
        for (name, entry) in lastSeen where !seenNames.contains(name) || saidGoodbye.contains(name) {
            if let since = entry.vanishedAt {
                if now.timeIntervalSince(since) >= grace { lastSeen[name] = nil }
            } else {
                lastSeen[name] = (entry.host, now)
            }
        }
        return lastSeen.values.map(\.host).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A host that had a TXT with a `pk` and now comes with no TXT record at
    /// all, still on the same links. The TXT going away together with a link
    /// is that link's purge, not a goodbye; so is a TXT-less report of a host
    /// already carried past one.
    private static func isGoodbye(_ host: DiscoveredHost, previous: DiscoveredHost?) -> Bool {
        guard !host.hasTXT, host.publicKey == nil, let previous, previous.publicKey != nil else { return false }
        return previous.hasTXT && host.links == previous.links
    }

    /// True while some host is being held past its disappearance.
    var hasPendingRemovals: Bool {
        lastSeen.values.contains { $0.vanishedAt != nil }
    }
}

@MainActor
final class HostBrowser {
    var onChange: (([DiscoveredHost]) -> Void)?
    var onStatus: ((String) -> Void)?
    private var browser: NWBrowser?
    /// The Mac's own links: an address arriving on one (DHCP finishing on a
    /// freshly plugged cable) changes which link a row says it will use, and
    /// Bonjour has no event for that.
    private var paths: NWPathMonitor?
    private let queue = DispatchQueue.main
    private var debouncer = HostListDebouncer()
    private var latest: [DiscoveredHost] = []
    private var flush: DispatchWorkItem?
    private var generation = 0

    func start() {
        generation += 1
        let attempt = generation
        browser?.cancel()
        let params = NWParameters()
        params.includePeerToPeer = true
        // Plain .bonjour never fetches TXT; the host's identity key lives there.
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Proto.serviceType, domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt else { return }
                if case .failed(let err) = state {
                    NSLog("HostBrowser: browse failed: %@", err.localizedDescription)
                    self.report("Can't search for PCs — retrying")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.generation == attempt else { return }
                        self.start()
                    }
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt else { return }
                self.latest = results.compactMap(Self.host(from:))
                self.publish()
            }
        }
        self.browser = browser
        browser.start(queue: queue)
        if paths == nil {
            let paths = NWPathMonitor()
            paths.pathUpdateHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.paths != nil else { return }
                    self.publish()
                }
            }
            self.paths = paths
            paths.start(queue: queue)
        }
    }

    func stop() {
        generation += 1
        flush?.cancel()
        flush = nil
        browser?.cancel()
        browser = nil
        paths?.cancel()
        paths = nil
    }

    /// Run the debouncer over the latest results and, while it is holding a
    /// vanished host, come back after the grace period to let it go.
    private func publish() {
        let hosts = debouncer.update(seen: latest, now: Date())
        onChange?(hosts)
        flush?.cancel()
        flush = nil
        if debouncer.hasPendingRemovals {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.publish() } }
            flush = work
            queue.asyncAfter(deadline: .now() + debouncer.grace + 0.1, execute: work)
        }
    }

    private func report(_ s: String) {
        onStatus?(s)
    }

    nonisolated static func host(from result: NWBrowser.Result) -> DiscoveredHost? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var key: Data?
        var digest: String?
        var facts = HostFacts()
        var hasTXT = false
        if case .bonjour(let txt) = result.metadata {
            hasTXT = true
            if let hex = txt["pk"], let data = Data(hex: hex), data.count == 32 { key = data }
            if let pg = txt["pg"], !pg.isEmpty { digest = pg }
            facts = HostFacts(txt: txt)
        }
        var host = DiscoveredHost(name: name, endpoint: result.endpoint, interfaces: result.interfaces, publicKey: key)
        host.pairingDigest = digest
        host.hasTXT = hasTXT
        host.links = Set(result.interfaces.map(\.name))
        host.facts = facts
        return host
    }
}
