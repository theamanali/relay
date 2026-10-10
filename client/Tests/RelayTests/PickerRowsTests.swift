import Network
import XCTest
@testable import Relay

final class PickerRowsTests: XCTestCase {
    private func host(_ name: String, key: Data? = nil) -> DiscoveredHost {
        DiscoveredHost(name: name, endpoint: .service(name: name, type: Proto.serviceType, domain: "local.", interface: nil),
                       interfaces: [], publicKey: key)
    }

    private let keyA = Data(repeating: 0xA, count: 32)
    private let keyB = Data(repeating: 0xB, count: 32)

    func testBuildOmitsEmptySections() {
        XCTAssertTrue(PickerRows.build(hosts: [], known: [:]).isEmpty)

        let onlyAvailable = PickerRows.build(hosts: [host("Desk PC", key: keyA)], known: [:])
        XCTAssertEqual(onlyAvailable.map(\.id), [.header(.available), .host("Desk PC")])

        let both = PickerRows.build(hosts: [host("Desk PC", key: keyA), host("Laptop", key: keyB)], known: [keyA: "Desk PC"])
        XCTAssertEqual(both.map(\.id), [.header(.paired), .host("Desk PC"), .header(.available), .host("Laptop")])
    }

    func testBuildIgnoresNameMatchesWithoutAKey() {
        let rows = PickerRows.build(hosts: [host("Desk PC")], known: [keyA: "Desk PC"])
        XCTAssertEqual(rows.map(\.id), [.header(.available), .host("Desk PC")])
    }

    func testDiffAddsAndRemoves() {
        let old = PickerRows.build(hosts: [host("A"), host("B")], known: [:])
        let new = PickerRows.build(hosts: [host("B"), host("C")], known: [:])
        let d = PickerRows.diff(old: old, new: new)
        XCTAssertFalse(d.needsFullReload)
        XCTAssertEqual(d.removed, IndexSet([1]))
        XCTAssertEqual(d.inserted, IndexSet([2]))
        XCTAssertTrue(d.reloaded.isEmpty)
    }

    func testDiffRemovingLastHostDropsTheHeader() {
        let old = PickerRows.build(hosts: [host("A")], known: [:])
        let d = PickerRows.diff(old: old, new: [])
        XCTAssertFalse(d.needsFullReload)
        XCTAssertEqual(d.removed, IndexSet([0, 1]))
    }

    func testDiffReloadsChangedRows() {
        let old = PickerRows.build(hosts: [host("A")], known: [:])
        let new = PickerRows.build(hosts: [host("A", key: keyB)], known: [:])
        let d = PickerRows.diff(old: old, new: new)
        XCTAssertEqual(d.reloaded, IndexSet([1]))
        XCTAssertTrue(d.removed.isEmpty && d.inserted.isEmpty)
    }

    func testDigestChangeAloneRedrawsNothing() {
        var before = host("A", key: keyA)
        before.pairingDigest = "11111111"
        var after = before
        after.pairingDigest = "22222222"
        let d = PickerRows.diff(old: PickerRows.build(hosts: [before], known: [keyA: "A"]),
                                new: PickerRows.build(hosts: [after], known: [keyA: "A"]))
        XCTAssertEqual(d, PickerRowDiff())
    }

    func testDiffFallsBackWhenHostMovesSection() {
        let old = PickerRows.build(hosts: [host("A", key: keyA), host("B", key: keyB)], known: [:])
        let new = PickerRows.build(hosts: [host("A", key: keyA), host("B", key: keyB)], known: [keyB: "B"])
        XCTAssertTrue(PickerRows.diff(old: old, new: new).needsFullReload)
    }

    func testSingleHostChangingSectionAnimatesOnlyHeaders() {
        let hosts = [host("A", key: keyA)]
        let available = PickerRows.build(hosts: hosts, known: [:])
        let paired = PickerRows.build(hosts: hosts, known: [keyA: "A"])
        for diff in [PickerRows.diff(old: available, new: paired),
                     PickerRows.diff(old: paired, new: available)] {
            XCTAssertFalse(diff.needsFullReload)
            XCTAssertEqual(diff.removed, IndexSet([0]))
            XCTAssertEqual(diff.inserted, IndexSet([0]))
            XCTAssertEqual(diff.reloaded, IndexSet([1]))
        }
    }
}
