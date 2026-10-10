import Network
import XCTest
@testable import Relay

final class HostListDebouncerTests: XCTestCase {
    private func host(_ name: String, pk: Data? = nil, hasTXT: Bool = true, links: Set<String> = []) -> DiscoveredHost {
        DiscoveredHost(name: name, endpoint: .service(name: name, type: Proto.serviceType, domain: "local.", interface: nil),
                       interfaces: [], publicKey: pk, hasTXT: hasTXT, links: links)
    }

    private let key = Data(repeating: 0xAB, count: 32)

    func testTXTWithdrawalExpiresWithoutRenewingGrace() {
        var d = HostListDebouncer(grace: 2)
        let t0 = Date()
        XCTAssertEqual(d.update(seen: [host("PC", pk: key)], now: t0).map(\.name), ["PC"])
        XCTAssertEqual(d.update(seen: [host("PC", hasTXT: false)], now: t0.addingTimeInterval(0.1)).map(\.publicKey), [key])
        XCTAssertTrue(d.hasPendingRemovals)
        XCTAssertEqual(d.update(seen: [host("PC", hasTXT: false)], now: t0.addingTimeInterval(1)).count, 1)
        XCTAssertTrue(d.update(seen: [host("PC", hasTXT: false)], now: t0.addingTimeInterval(2.2)).isEmpty)
        XCTAssertTrue(d.update(seen: [], now: t0.addingTimeInterval(2.3)).isEmpty)
        XCTAssertFalse(d.hasPendingRemovals)
        // The host starting again is a fresh appearance.
        XCTAssertEqual(d.update(seen: [host("PC", pk: key)], now: t0.addingTimeInterval(5)).map(\.name), ["PC"])
    }

    func testLosingTheCableKeepsTheKeyWhileTheTXTIsGone() {
        var d = HostListDebouncer(grace: 2)
        let t0 = Date()
        var facts = HostFacts()
        facts.ips = ["10.0.0.46"]
        var both = host("PC", pk: key, links: ["en7", "en0"])
        both.facts = facts
        both.pairingDigest = "0badf00d"
        XCTAssertEqual(d.update(seen: [both], now: t0).map(\.publicKey), [key])
        // Cable unplugged: mDNSResponder purged the TXT with the cable, the
        // PTR survives on Wi-Fi. Same shape as a goodbye, but the links changed.
        let onWiFi = d.update(seen: [host("PC", hasTXT: false, links: ["en0"])], now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(onWiFi.map(\.name), ["PC"])
        XCTAssertEqual(onWiFi[0].publicKey, key)
        XCTAssertEqual(onWiFi[0].pairingDigest, "0badf00d")
        XCTAssertEqual(onWiFi[0].facts.ips, ["10.0.0.46"])
        XCTAssertFalse(onWiFi[0].hasTXT)
        XCTAssertFalse(d.hasPendingRemovals)
        // Bonjour keeps reporting it TXT-less for as long as the TTL: still there, still paired.
        XCTAssertEqual(d.update(seen: [host("PC", hasTXT: false, links: ["en0"])], now: t0.addingTimeInterval(50)).map(\.publicKey), [key])
        // Cable back: the links grow first, the TXT follows a beat later.
        XCTAssertEqual(d.update(seen: [host("PC", hasTXT: false, links: ["en0", "en7"])], now: t0.addingTimeInterval(60)).map(\.publicKey), [key])
        XCTAssertEqual(d.update(seen: [host("PC", pk: key, links: ["en0", "en7"])], now: t0.addingTimeInterval(60.1)).map(\.hasTXT), [true])
    }

    func testGoodbyeWhileCarriedPastACableLossGetsTheNormalHold() {
        var d = HostListDebouncer(grace: 2)
        let t0 = Date()
        _ = d.update(seen: [host("PC", pk: key, links: ["en7", "en0"])], now: t0)
        _ = d.update(seen: [host("PC", hasTXT: false, links: ["en0"])], now: t0.addingTimeInterval(0.1))
        // The PC quits: nothing left to flush but the PTR.
        XCTAssertEqual(d.update(seen: [], now: t0.addingTimeInterval(5)).map(\.name), ["PC"])
        XCTAssertTrue(d.hasPendingRemovals)
        XCTAssertTrue(d.update(seen: [], now: t0.addingTimeInterval(7.5)).isEmpty)
    }

    func testReregistrationKeepsHostAndUpdatesDigest() {
        var d = HostListDebouncer(grace: 2)
        let t0 = Date()
        _ = d.update(seen: [host("PC", pk: key, links: ["en7", "en0"])], now: t0)
        XCTAssertEqual(d.update(seen: [host("PC", hasTXT: false, links: ["en7", "en0"])], now: t0.addingTimeInterval(0.1)).map(\.publicKey), [key])
        var refreshed = host("PC", pk: key, links: ["en7", "en0"])
        refreshed.pairingDigest = "12345678"
        let shown = d.update(seen: [refreshed], now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(shown.map(\.publicKey), [key])
        XCTAssertEqual(shown.first?.pairingDigest, "12345678")
        XCTAssertFalse(d.hasPendingRemovals)
    }

    func testPairedHostThatVanishesWithTXTIntactIsHeld() {
        var d = HostListDebouncer(grace: 2)
        let t0 = Date()
        _ = d.update(seen: [host("PC", pk: key)], now: t0)
        XCTAssertEqual(d.update(seen: [], now: t0.addingTimeInterval(0.5)).map(\.name), ["PC"])
        XCTAssertTrue(d.hasPendingRemovals)
        XCTAssertEqual(d.update(seen: [], now: t0.addingTimeInterval(2.4)).map(\.name), ["PC"])
        XCTAssertTrue(d.update(seen: [], now: t0.addingTimeInterval(2.6)).isEmpty)
    }

    func testHostWithoutKeyLosingTXTIsUnaffected() {
        var d = HostListDebouncer(grace: 2)
        let t0 = Date()
        _ = d.update(seen: [host("PC")], now: t0)
        // Never advertised a key: a TXT-less report is just a host with no facts.
        let shown = d.update(seen: [host("PC", hasTXT: false)], now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(shown.map(\.name), ["PC"])
        XCTAssertFalse(d.hasPendingRemovals)
        // And when it goes away it gets the normal hold.
        XCTAssertEqual(d.update(seen: [], now: t0.addingTimeInterval(0.5)).map(\.name), ["PC"])
        XCTAssertTrue(d.hasPendingRemovals)
    }

    func testVanishedHostIsHeldThroughTheGracePeriod() {
        var d = HostListDebouncer(grace: 2)
        let t0 = Date()
        XCTAssertEqual(d.update(seen: [host("PC")], now: t0).map(\.name), ["PC"])
        // Bonjour drops it: still shown, flagged as pending.
        XCTAssertEqual(d.update(seen: [], now: t0.addingTimeInterval(0.5)).map(\.name), ["PC"])
        XCTAssertTrue(d.hasPendingRemovals)
        // Still within grace.
        XCTAssertEqual(d.update(seen: [], now: t0.addingTimeInterval(2.0)).map(\.name), ["PC"])
        // Grace elapsed since it vanished (at 0.5): gone.
        XCTAssertTrue(d.update(seen: [], now: t0.addingTimeInterval(2.6)).isEmpty)
        XCTAssertFalse(d.hasPendingRemovals)
    }

    func testReappearingHostIsNeverDropped() {
        var d = HostListDebouncer(grace: 2)
        let t0 = Date()
        _ = d.update(seen: [host("PC")], now: t0)
        _ = d.update(seen: [], now: t0.addingTimeInterval(0.3))
        // Re-registered with new facts before the grace ran out.
        var back = host("PC")
        back.facts.ramGB = 32
        let shown = d.update(seen: [back], now: t0.addingTimeInterval(1.0))
        XCTAssertEqual(shown.map(\.name), ["PC"])
        XCTAssertEqual(shown[0].facts.ramGB, 32)
        XCTAssertFalse(d.hasPendingRemovals)
        // Long after: still there because it is still seen.
        XCTAssertEqual(d.update(seen: [back], now: t0.addingTimeInterval(60)).count, 1)
    }

    func testOutputIsSortedByName() {
        var d = HostListDebouncer()
        let shown = d.update(seen: [host("zeta"), host("Alpha")], now: Date())
        XCTAssertEqual(shown.map(\.name), ["Alpha", "zeta"])
    }
}
