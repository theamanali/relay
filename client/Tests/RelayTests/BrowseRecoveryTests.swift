import Network
import XCTest
@testable import Relay

final class BrowseRecoveryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testMissingHostRetriesAtAbsoluteOffsetsAndStops() {
        var recovery = BrowseRecovery()
        recovery.missing("PC", now: t0)
        XCTAssertEqual(recovery.nextDeadline, t0.addingTimeInterval(2.5))
        XCTAssertTrue(recovery.takeDue(now: t0.addingTimeInterval(2.49)).isEmpty)
        for delay in [2.5, 10.0, 30.0] {
            XCTAssertEqual(recovery.takeDue(now: t0.addingTimeInterval(delay)), ["PC"])
            XCTAssertTrue(recovery.takeDue(now: t0.addingTimeInterval(delay)).isEmpty)
        }
        XCTAssertNil(recovery.nextDeadline)
        recovery.missing("PC", now: t0.addingTimeInterval(60))
        XCTAssertNil(recovery.nextDeadline, "An absent PC must not restart a polling loop")
    }

    func testDuplicateTriggersDoNotPostponeRecovery() {
        var recovery = BrowseRecovery()
        recovery.dialFailed("PC", now: t0)
        recovery.missing("PC", now: t0.addingTimeInterval(1))
        recovery.dialFailed("PC", now: t0.addingTimeInterval(2))
        XCTAssertEqual(recovery.takeDue(now: t0.addingTimeInterval(2.5)), ["PC"])
        XCTAssertEqual(recovery.nextDeadline, t0.addingTimeInterval(10))
    }

    func testFailedDialRequiresOneRestartDespiteCachedPresence() {
        var recovery = BrowseRecovery()
        recovery.dialFailed("PC", now: t0)
        recovery.observed(["PC"])
        XCTAssertEqual(recovery.takeDue(now: t0.addingTimeInterval(2.5)), ["PC"])
        recovery.observed(["PC"])
        XCTAssertNil(recovery.nextDeadline)
    }

    func testReturnBeforeFirstRestartCancelsRemovalRecovery() {
        var recovery = BrowseRecovery()
        recovery.missing("PC", now: t0)
        recovery.observed(["PC"])
        XCTAssertNil(recovery.nextDeadline)
        XCTAssertTrue(recovery.takeDue(now: t0.addingTimeInterval(30)).isEmpty)
        // A later disappearance is a separate episode.
        recovery.missing("PC", now: t0.addingTimeInterval(40))
        XCTAssertEqual(recovery.nextDeadline, t0.addingTimeInterval(42.5))
    }

    func testSeveralMissingHostsShareRestartAndRecoverIndependently() {
        var recovery = BrowseRecovery()
        recovery.missing("A", now: t0)
        recovery.missing("B", now: t0)
        XCTAssertEqual(recovery.takeDue(now: t0.addingTimeInterval(2.5)), ["A", "B"])
        recovery.observed(["A"])
        XCTAssertEqual(recovery.takeDue(now: t0.addingTimeInterval(10)), ["B"])
        recovery.observed(["B"])
        XCTAssertNil(recovery.nextDeadline)
    }

    func testLateTimerSkipsElapsedSlotsWithoutBurst() {
        var recovery = BrowseRecovery()
        recovery.missing("PC", now: t0)
        XCTAssertEqual(recovery.takeDue(now: t0.addingTimeInterval(15)), ["PC"])
        XCTAssertEqual(recovery.nextDeadline, t0.addingTimeInterval(30))
        XCTAssertEqual(recovery.takeDue(now: t0.addingTimeInterval(60)), ["PC"])
        XCTAssertNil(recovery.nextDeadline)
    }

    func testNewUserDialAfterExhaustionStartsAnotherBoundedEpisode() {
        var recovery = BrowseRecovery()
        recovery.dialFailed("PC", now: t0)
        _ = recovery.takeDue(now: t0.addingTimeInterval(30))
        recovery.dialFailed("PC", now: t0.addingTimeInterval(60))
        XCTAssertEqual(recovery.nextDeadline, t0.addingTimeInterval(62.5))
        recovery = BrowseRecovery() // HostBrowser.stop cancels all pending recovery.
        XCTAssertNil(recovery.nextDeadline)
    }

    private func host(_ name: String, txt: Bool = true) -> DiscoveredHost {
        DiscoveredHost(name: name,
                       endpoint: .service(name: name, type: Proto.serviceType, domain: "local.", interface: nil),
                       interfaces: [], publicKey: txt ? Data(repeating: 1, count: 32) : nil,
                       hasTXT: txt, links: ["en0"])
    }

    func testStuckTXTWithdrawalRecoversWithoutFlickeringOtherRows() {
        var debouncer = HostListDebouncer()
        var recovery = BrowseRecovery()
        let healthy = host("Other PC")
        let pc = host("PC")
        _ = debouncer.update(seen: [healthy, pc], now: t0)
        let withdrawn = host("PC", txt: false)
        XCTAssertEqual(debouncer.update(seen: [healthy, withdrawn], now: t0.addingTimeInterval(1)).map(\.name), ["Other PC", "PC"])
        let shown = debouncer.update(seen: [healthy, withdrawn], now: t0.addingTimeInterval(3.6))
        XCTAssertEqual(shown.map(\.name), ["Other PC"])
        recovery.missing("PC", now: t0.addingTimeInterval(3.6))
        recovery.observed(["Other PC"]) // TXT-less PC does not count as recovered.
        XCTAssertEqual(recovery.takeDue(now: t0.addingTimeInterval(6.1)), ["PC"])
        // The recreated browser's partial first snapshot must not remove
        // another PC or renew the lost PC's expired grace.
        XCTAssertEqual(debouncer.update(seen: [], now: t0.addingTimeInterval(6.1)).map(\.name), ["Other PC"])
        XCTAssertEqual(debouncer.update(seen: [healthy, pc], now: t0.addingTimeInterval(6.2)).map(\.name), ["Other PC", "PC"])
        recovery.observed(["Other PC", "PC"])
        XCTAssertNil(recovery.nextDeadline)
        XCTAssertFalse(debouncer.hasPendingRemovals)
    }

    func testBriefTXTReplacementStaysWithinGraceAndNeedsNoRecovery() {
        var debouncer = HostListDebouncer()
        _ = debouncer.update(seen: [host("PC")], now: t0)
        XCTAssertEqual(debouncer.update(seen: [host("PC", txt: false)], now: t0.addingTimeInterval(1)).map(\.name), ["PC"])
        XCTAssertEqual(debouncer.update(seen: [host("PC")], now: t0.addingTimeInterval(1.13)).map(\.name), ["PC"])
        XCTAssertFalse(debouncer.hasPendingRemovals)
    }
}
