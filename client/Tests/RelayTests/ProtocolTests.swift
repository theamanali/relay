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
        XCTAssertEqual(payload.be16(at: 0), 4)
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

    func testServerHelloCarriesPaired() {
        let hello = Proto.ServerHello(Data([0, 4, 4]) + Data("Desk".utf8) + Data([1]))
        XCTAssertEqual(hello?.version, 4)
        XCTAssertEqual(hello?.name, "Desk")
        XCTAssertEqual(hello?.paired, true)
        XCTAssertEqual(Proto.ServerHello(Data([0, 4, 0, 0]))?.paired, false)
        XCTAssertEqual(Proto.ServerHello(Data([0, 4, 0, 0]))?.name, "")
        XCTAssertNil(Proto.ServerHello(Data([0, 4, 4]) + Data("Desk".utf8)), "v4 hellos end with paired")
        XCTAssertNil(Proto.ServerHello(Data([0, 4, 9, 0])), "name longer than the payload")
        XCTAssertNil(Proto.ServerHello(Data([0, 4])))
    }

    func testPairResultCodes() {
        XCTAssertEqual(Proto.PairResult(Data([1])), .paired)
        XCTAssertEqual(Proto.PairResult(Data([0])), .wrongPIN)
        XCTAssertEqual(Proto.PairResult(Data([2, 0x02, 0x57])), .rateLimited(seconds: 599))
        XCTAssertEqual(Proto.PairResult(Data([2, 0, 0])), .rateLimited(seconds: 0))
        XCTAssertEqual(Proto.PairResult(Data([1, 9, 9])), .paired, "trailing bytes are ignored")
    }

    func testServerHelloNegotiatesPairNameAndIgnoresUnknownBits() throws {
        let legacy = Data([0, 4, 4]) + Data("Desk".utf8) + Data([1])
        for (suffix, capabilities, named) in [(Data(), UInt8(0), false),
                                             (Data([1]), 1, true),
                                             (Data([0x80]), 0x80, false),
                                             (Data([0x81]), 0x81, true)] {
            // Also exercise Data whose startIndex is not zero.
            let hello = try XCTUnwrap(Proto.ServerHello((Data([9]) + legacy + suffix).dropFirst()))
            XCTAssertEqual(hello.version, 4)
            XCTAssertEqual(hello.name, "Desk")
            XCTAssertTrue(hello.paired)
            XCTAssertEqual(hello.capabilities, capabilities)
            XCTAssertEqual(hello.supportsPairName, named)
        }
    }

    func testPairNameIsBoundedOnUnicodeScalarBoundaries() throws {
        let cases = [
            ("Aman’s MacBook Pro", "Aman’s MacBook Pro"),
            ("", ""),
            (String(repeating: "a", count: 256), String(repeating: "a", count: 255)),
            (String(repeating: "界", count: 86), String(repeating: "界", count: 85)),
            (String(repeating: "a", count: 254) + "🦀", String(repeating: "a", count: 254)),
            (String(repeating: "a", count: 251) + "🦀", String(repeating: "a", count: 251) + "🦀"),
            // The boundary may split a grapheme, but never a scalar's UTF-8.
            (String(repeating: "a", count: 254) + "e\u{301}", String(repeating: "a", count: 254) + "e"),
            (" \nMac\t ", " \nMac\t "), // proof uses unsanitized bytes
        ]
        for (name, expected) in cases {
            let ad = Proto.pairNameAD(name)
            let request = try XCTUnwrap(Proto.PairRequest(Data(repeating: 7, count: 32) + ad))
            XCTAssertEqual(request.name, expected)
            XCTAssertEqual(request.ad, ad)
            XCTAssertEqual(Int(ad[0]), expected.utf8.count)
            XCTAssertLessThanOrEqual(32 + ad.count, 288)
        }
    }

    func testPairRequestDistinguishesEmptyNameFromLegacyAndRejectsMalformedNames() throws {
        let share = Data(repeating: 7, count: 32)
        let legacy = try XCTUnwrap(Proto.PairRequest(share))
        XCTAssertNil(legacy.name)
        XCTAssertEqual(legacy.ad, Data())
        let empty = try XCTUnwrap(Proto.PairRequest(share + Proto.pairNameAD("")))
        XCTAssertEqual(empty.name, "")
        XCTAssertEqual(empty.ad, Data([0]))
        XCTAssertEqual(empty.share, share)
        XCTAssertNil(Proto.PairRequest(share.dropFirst()))
        for suffix: Data in [Data([1]), Data([0, 1]), Data([1, 0xff]), Data([2, 97]),
                             Data([2, 0xc0, 0xaf]), Data([3, 0xed, 0xa0, 0x80]),
                             Data([1, 0xe2]), Data([255]) + Data(repeating: 97, count: 256)] {
            XCTAssertNil(Proto.PairRequest(share + suffix), "suffix \(suffix)")
        }
    }

    func testAnythingElseIsARefusal() {
        XCTAssertEqual(Proto.PairResult(Data()), .rejected)
        XCTAssertEqual(Proto.PairResult(Data([2])), .rejected, "rate-limited without its wait")
        XCTAssertEqual(Proto.PairResult(Data([2, 5])), .rejected)
        XCTAssertEqual(Proto.PairResult(Data([3])), .rejected)
        XCTAssertEqual(Proto.PairResult(Data([0xff])), .rejected)
    }
}
