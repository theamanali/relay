import XCTest
@testable import Relay

final class LatestFrameTests: XCTestCase {
    func testBurstKeepsNewestAndRejectsLateCallback() {
        var mailbox = LatestFrame<String>()
        XCTAssertTrue(mailbox.offer("first", sequence: 1, generation: 0))
        XCTAssertTrue(mailbox.offer("third", sequence: 3, generation: 0))
        XCTAssertFalse(mailbox.offer("second", sequence: 2, generation: 0))
        XCTAssertEqual(mailbox.take(), "third")
        XCTAssertNil(mailbox.take())
        XCTAssertEqual(mailbox.dropped, 2)
        XCTAssertEqual(mailbox.replaced, 1)
        XCTAssertEqual(mailbox.late, 1)
        XCTAssertFalse(mailbox.offer("duplicate", sequence: 3, generation: 0))
    }

    func testResetRejectsOldDecoderAndAcceptsRestartedSequence() {
        var mailbox = LatestFrame<Int>()
        XCTAssertTrue(mailbox.offer(100, sequence: 100, generation: 0))
        mailbox.reset(generation: 1, clearMetrics: true)
        XCTAssertNil(mailbox.take())
        XCTAssertFalse(mailbox.offer(101, sequence: 101, generation: 0))
        XCTAssertTrue(mailbox.offer(0, sequence: 0, generation: 1))
        XCTAssertEqual(mailbox.take(), 0)
        XCTAssertEqual(mailbox.dropped, 0)
    }

    func testRendererSelection() {
        XCTAssertEqual(LaunchOptions.parse(["Relay"]).renderer, "metal")
        XCTAssertEqual(LaunchOptions.parse(["Relay", "--renderer", "avsbdl"]).renderer, "avsbdl")
        XCTAssertFalse(LaunchOptions.parse(["Relay"]).metalVSync)
        XCTAssertTrue(LaunchOptions.parse(["Relay", "--metal-vsync"]).metalVSync)
    }
}
