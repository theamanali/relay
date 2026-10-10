import Network
import XCTest
@testable import Relay

final class HostConnectionTests: XCTestCase {
    func testLocalNetworkDenialIsDistinctFromOrdinaryNetworkFailures() {
        XCTAssertTrue(HostConnection.isLocalNetworkDenied(.dns(-65570), pathReason: nil))
        XCTAssertTrue(HostConnection.isLocalNetworkDenied(.posix(.EPERM), pathReason: .localNetworkDenied))
        XCTAssertFalse(HostConnection.isLocalNetworkDenied(.posix(.ECONNREFUSED), pathReason: .notAvailable))
        XCTAssertFalse(HostConnection.isLocalNetworkDenied(.posix(.EPERM), pathReason: nil))
        XCTAssertFalse(HostConnection.isLocalNetworkDenied(.dns(-65537), pathReason: nil))
    }
}
