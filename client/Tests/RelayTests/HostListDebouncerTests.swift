import Network
import XCTest
@testable import Relay

final class HostListDebouncerTests: XCTestCase {
    private func host(_ name: String) -> DiscoveredHost {
        DiscoveredHost(name: name, endpoint: .service(name: name, type: Proto.serviceType, domain: "local.", interface: nil),
                       interfaces: [], publicKey: nil)
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
