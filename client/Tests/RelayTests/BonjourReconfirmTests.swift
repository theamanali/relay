import XCTest
@testable import Relay

final class BonjourReconfirmTests: XCTestCase {
    func testWireNameIsLengthPrefixedLabelsAndRoot() {
        let name = BonjourReconfirm.wireName(labels: ["GAMING-PC", "_relay", "_tcp", "local"])
        var expected = Data([9]); expected.append(contentsOf: Array("GAMING-PC".utf8))
        expected.append(6); expected.append(contentsOf: Array("_relay".utf8))
        expected.append(4); expected.append(contentsOf: Array("_tcp".utf8))
        expected.append(5); expected.append(contentsOf: Array("local".utf8))
        expected.append(0)
        XCTAssertEqual(name, expected)
    }

    func testLabelsComeFromDottedNames() {
        XCTAssertEqual(BonjourReconfirm.labels(of: "_relay._tcp"), ["_relay", "_tcp"])
        XCTAssertEqual(BonjourReconfirm.labels(of: "local."), ["local"])
        // An instance name with a dot in it is one label; the caller passes it whole.
        XCTAssertEqual(BonjourReconfirm.wireName(labels: ["Aman's PC"])?.first, 9)
    }

    func testOversizedNamesAreRefused() {
        XCTAssertNil(BonjourReconfirm.wireName(labels: [String(repeating: "x", count: 64)]))
        XCTAssertNil(BonjourReconfirm.wireName(labels: [""]))
        XCTAssertNil(BonjourReconfirm.wireName(labels: Array(repeating: String(repeating: "y", count: 60), count: 5)))
    }
}
