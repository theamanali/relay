import XCTest
@testable import Relay

final class ProtocolTests: XCTestCase {
    func testPairResultCodes() {
        XCTAssertEqual(Proto.PairResult(Data([1])), .paired)
        XCTAssertEqual(Proto.PairResult(Data([0])), .wrongPIN)
        XCTAssertEqual(Proto.PairResult(Data([2, 0x02, 0x57])), .rateLimited(seconds: 599))
        XCTAssertEqual(Proto.PairResult(Data([2, 0, 0])), .rateLimited(seconds: 0))
        XCTAssertEqual(Proto.PairResult(Data([1, 9, 9])), .paired, "trailing bytes are ignored")
    }

    func testAnythingElseIsARefusal() {
        XCTAssertEqual(Proto.PairResult(Data()), .rejected)
        XCTAssertEqual(Proto.PairResult(Data([2])), .rejected, "rate-limited without its wait")
        XCTAssertEqual(Proto.PairResult(Data([2, 5])), .rejected)
        XCTAssertEqual(Proto.PairResult(Data([3])), .rejected)
        XCTAssertEqual(Proto.PairResult(Data([0xff])), .rejected)
    }
}
