import XCTest
@testable import TravelDisplay

final class FrameReaderTests: XCTestCase {
    private func frame(_ body: [UInt8]) -> Data {
        var d = Data(); d.appendBE32(UInt32(body.count)); d.append(contentsOf: body); return d
    }

    func testTwoFramesInOneReadAndSplitHeader() throws {
        var r = FrameReader(maxFrame: 1 << 20)
        XCTAssertEqual(r.needed, 4)
        var bytes = frame([1, 2, 3]) + frame([4]) + frame([5, 6])
        let tail = bytes.suffix(3); bytes.removeLast(3)   // last frame's header cut mid-way
        r.append(bytes)
        XCTAssertEqual(try r.next(), Data([1, 2, 3]))
        XCTAssertEqual(try r.next(), Data([4]))
        XCTAssertNil(try r.next())
        XCTAssertEqual(r.needed, 1)
        r.append(tail.prefix(1))
        XCTAssertNil(try r.next())
        XCTAssertEqual(r.needed, 2, "header complete, body of 2 still missing")
        r.append(tail.suffix(2))
        XCTAssertEqual(try r.next(), Data([5, 6]))
        XCTAssertNil(try r.next())
        XCTAssertEqual(r.needed, 4)
    }

    func testBodyDeliveredInPieces() throws {
        var r = FrameReader(maxFrame: 1 << 20)
        let body = [UInt8](repeating: 7, count: 10_000)
        let f = frame(body)
        r.append(f.prefix(4 + 100))
        XCTAssertNil(try r.next())
        XCTAssertEqual(r.needed, 9_900)
        r.append(f.suffix(9_900))
        XCTAssertEqual(try r.next()?.count, 10_000)
    }

    func testRejectsBadLengths() {
        var r = FrameReader(maxFrame: 8)
        r.append(frame([UInt8](repeating: 0, count: 9)))
        XCTAssertThrowsError(try r.next()) { XCTAssertEqual($0 as? FrameReader.Failure, .badLength(9)) }
        var z = FrameReader(maxFrame: 8)
        z.append(Data([0, 0, 0, 0]))
        XCTAssertThrowsError(try z.next())
    }

    func testCompactionKeepsUnconsumedBytes() throws {
        var r = FrameReader(maxFrame: 1 << 20)
        for n in 0..<1000 {
            r.append(frame([UInt8(n & 0xff)]))
            XCTAssertEqual(try r.next(), Data([UInt8(n & 0xff)]))
        }
        r.append(frame([9, 9]).prefix(5))
        r.append(frame([9, 9]).suffix(1))
        XCTAssertEqual(try r.next(), Data([9, 9]))
    }
}
