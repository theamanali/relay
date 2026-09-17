import Network
import XCTest
@testable import Relay

final class PairingClassifierTests: XCTestCase {
    private func host(_ name: String, key: Data? = nil) -> DiscoveredHost {
        DiscoveredHost(name: name, endpoint: .service(name: name, type: Proto.serviceType, domain: "local.", interface: nil),
                       interfaces: [], publicKey: key)
    }

    private let keyA = Data(repeating: 0xA, count: 32)
    private let keyB = Data(repeating: 0xB, count: 32)

    func testAdvertisedKeyDecides() {
        let known = [keyA: "Desk PC"]
        let r = PairingClassifier.classify([host("Desk PC", key: keyA), host("Desk PC", key: keyB), host("Other", key: keyB)], known: known)
        XCTAssertEqual(r.paired.map(\.name), ["Desk PC"])
        // Same name but a different key is not paired, even though the name matches.
        XCTAssertEqual(r.unpaired.map(\.name), ["Desk PC", "Other"])
    }

    func testNameAloneNeverPairs() {
        let known = [keyA: "Desk PC"]
        let r = PairingClassifier.classify([host("Desk PC"), host("Laptop")], known: known)
        XCTAssertTrue(r.paired.isEmpty)
        XCTAssertEqual(r.unpaired.map(\.name), ["Desk PC", "Laptop"])
    }

    func testExpectedIdentityIsTheRememberedAdvertisedKey() {
        let known = [keyA: "Desk PC"]
        XCTAssertEqual(PairingClassifier.expectedKey(for: host("Desk PC", key: keyA), known: known), keyA)
        XCTAssertNil(PairingClassifier.expectedKey(for: host("Desk PC", key: keyB), known: known))
        XCTAssertNil(PairingClassifier.expectedKey(for: host("Desk PC"), known: known))
    }

    func testFixedHostFlagStillParses() {
        let o = LaunchOptions.parse(["Relay", "--host", "192.168.1.5:8468"])
        XCTAssertNotNil(o.fixedHost)
        XCTAssertNil(LaunchOptions.parse(["Relay"]).fixedHost)
    }
}
