import XCTest
@testable import Relay

final class ProtocolTests: XCTestCase {
    func testClientHelloCarriesRequestedBitrate() {
        let message = Proto.clientHello(
            width: 3024,
            height: 1964,
            refresh: 120,
            bitrateMbps: 500,
            wantsInput: true,
            codecs: Proto.Codec.hevc.bit,
            name: "Mac"
        )
        let payload = Data(message.dropFirst(Proto.headerSize))
        XCTAssertEqual(payload.count, 16)
        XCTAssertEqual(payload.be16(at: 0), 3)
        XCTAssertEqual(payload.be16(at: 8), 500)
        XCTAssertEqual(payload[payload.startIndex + 10], 1)
        XCTAssertEqual(payload[payload.startIndex + 11], Proto.Codec.hevc.bit)
        XCTAssertEqual(payload[payload.startIndex + 12], 3)
    }

    func testStreamStartReturnsActualBitrate() {
        let start = Proto.StreamStart(Data([0x0b, 0xd0, 0x07, 0xac, 0, 120, 1, 0xf4, 2, 0]))
        XCTAssertEqual(start?.width, 3024)
        XCTAssertEqual(start?.height, 1964)
        XCTAssertEqual(start?.fps, 120)
        XCTAssertEqual(start?.bitrateMbps, 500)
        XCTAssertEqual(start?.codec, .hevc)
        XCTAssertNil(Proto.StreamStart(Data([0, 1, 0, 1, 0, 60, 0, 120])))
        XCTAssertNil(Proto.StreamStart(Data([0, 1, 0, 1, 0, 60, 0, 0, 2, 0])))
    }

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
