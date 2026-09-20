import Network
import XCTest
@testable import Relay

final class PairingVerifierTests: XCTestCase {
    private func host(_ name: String, key: Data? = nil, digest: String? = nil) -> DiscoveredHost {
        var h = DiscoveredHost(name: name, endpoint: .service(name: name, type: Proto.serviceType, domain: "local.", interface: nil),
                               interfaces: [], publicKey: key)
        h.pairingDigest = digest
        return h
    }

    private let keyA = Data(repeating: 0xA, count: 32)
    private let keyB = Data(repeating: 0xB, count: 32)

    func testKnownHostWithUnverifiedDigestIsAskedOnce() {
        var v = PairingVerifier()
        let hosts = [host("PC", key: keyA, digest: "aaaa0001")]
        let first = v.next(among: hosts, known: [keyA: "PC"], verified: [:])
        XCTAssertEqual(first?.key, keyA)
        XCTAssertEqual(first?.digest, "aaaa0001")
        // The same browse result again (or an unreachable host): not again.
        XCTAssertNil(v.next(among: hosts, known: [keyA: "PC"], verified: [:]))
        // Until the digest moves.
        let moved = v.next(among: [host("PC", key: keyA, digest: "aaaa0002")], known: [keyA: "PC"], verified: [:])
        XCTAssertEqual(moved?.digest, "aaaa0002")
    }

    func testVerifiedDigestNeedsNoCheck() {
        var v = PairingVerifier()
        let hosts = [host("PC", key: keyA, digest: "aaaa0001")]
        XCTAssertNil(v.next(among: hosts, known: [keyA: "PC"], verified: [keyA: "aaaa0001"]))
        XCTAssertEqual(v.next(among: hosts, known: [keyA: "PC"], verified: [keyA: "aaaa0000"])?.digest, "aaaa0001")
    }

    func testOnlyKnownHostsAdvertisingADigestCount() {
        var v = PairingVerifier()
        // Not paired: nothing to verify. No `pg` (an older host): nothing to compare.
        XCTAssertNil(v.next(among: [host("New", key: keyB, digest: "bbbb0001")], known: [keyA: "PC"], verified: [:]))
        XCTAssertNil(v.next(among: [host("Old", key: keyA)], known: [keyA: "PC"], verified: [:]))
        XCTAssertNil(v.next(among: [host("Nameless")], known: [keyA: "PC"], verified: [:]))
    }

    func testOneHostAtATime() {
        var v = PairingVerifier()
        let hosts = [host("A", key: keyA, digest: "aaaa0001"), host("B", key: keyB, digest: "bbbb0001")]
        let known = [keyA: "A", keyB: "B"]
        XCTAssertEqual(v.next(among: hosts, known: known, verified: [:])?.key, keyA)
        XCTAssertEqual(v.next(among: hosts, known: known, verified: [:])?.key, keyB)
        XCTAssertNil(v.next(among: hosts, known: known, verified: [:]))
    }

    func testRetractedAttemptIsAskedAgain() {
        var v = PairingVerifier()
        let hosts = [host("PC", key: keyA, digest: "aaaa0001")]
        XCTAssertNotNil(v.next(among: hosts, known: [keyA: "PC"], verified: [:]))
        v.retract(keyA)
        XCTAssertNotNil(v.next(among: hosts, known: [keyA: "PC"], verified: [:]))
    }
}
