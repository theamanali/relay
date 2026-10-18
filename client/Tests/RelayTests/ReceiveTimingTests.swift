import XCTest
@testable import Relay

final class ReceiveTimingTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    func testAMessageInOneRecordHasNoTransferEstimate() {
        var timer = ReceiveTimer()
        timer.didRead(1_000)
        let t = timer.opened(startedAt: 0, consumed: 1_000, decryptNanos: 20_000, complete: true, now: 5 * ms)
        XCTAssertEqual(t?.wireBytes, 1_000)
        XCTAssertNil(t?.transferMilliseconds)
        XCTAssertEqual(t?.decryptMilliseconds ?? 0, 0.02, accuracy: 1e-9)
    }

    func testLaterRecordsGiveTheRateAndTheWholeFramesTime() throws {
        var timer = ReceiveTimer()
        // A 100,000-byte frame: the first read brings its first record (and
        // a little more), the second read the rest 0.2 ms later.
        timer.didRead(70_000)
        XCTAssertNil(timer.opened(startedAt: 0, consumed: 65_539, decryptNanos: 30_000, complete: false, now: 10 * ms))
        timer.didRead(40_000) // 10,000 of these belong to the next message
        let t = try XCTUnwrap(timer.opened(startedAt: 65_539, consumed: 100_000, decryptNanos: 20_000,
                                           complete: true, now: 10 * ms + 200_000))
        XCTAssertEqual(t.wireBytes, 100_000)
        // Only bytes that arrived after the first record count: 30,000 in 0.2 ms.
        XCTAssertEqual(t.lateBytes, 30_000)
        XCTAssertEqual(try XCTUnwrap(t.bitsPerSecond), 1.2e9, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(t.transferMilliseconds), 100_000 * 8 / 1.2e9 * 1_000, accuracy: 1e-9)
        XCTAssertEqual(t.decryptMilliseconds, 0.05, accuracy: 1e-9)
    }

    func testAFrameAlreadyBufferedIsNotAFastLink() {
        var timer = ReceiveTimer()
        timer.didRead(200_000) // the whole frame was waiting
        _ = timer.opened(startedAt: 0, consumed: 65_539, decryptNanos: 0, complete: false, now: 10 * ms)
        let t = timer.opened(startedAt: 65_539, consumed: 100_000, decryptNanos: 0, complete: true, now: 10 * ms + 50_000)
        XCTAssertEqual(t?.lateBytes, 0)
        XCTAssertNil(t?.transferMilliseconds)
        // The next message starts clean.
        let next = timer.opened(startedAt: 100_000, consumed: 100_100, decryptNanos: 0, complete: true, now: 11 * ms)
        XCTAssertEqual(next?.wireBytes, 100)
    }

    func testStatsRecordTransferDecryptAndInput() throws {
        let stats = LatencyStats()
        let second: UInt64 = 1_000_000_000
        stats.reset(at: 0)
        let at = 4 * second
        stats.record(ReceiveTiming(wireBytes: 125_000, lateBytes: 60_000, lateNanos: 400_000, decryptNanos: 40_000), at: at)
        stats.record(ReceiveTiming(wireBytes: 10_000, lateBytes: 0, lateNanos: 0, decryptNanos: 10_000), at: at)
        stats.recordInputSent(milliseconds: 0.6, at: at)
        // Before warm-up ends nothing counts.
        stats.recordInputSent(milliseconds: 30, at: second)
        let hud = stats.hudSnapshot(at: at)
        // 60,000 bytes in 0.4 ms = 1.2 Gb/s, so 125,000 bytes take 0.83 ms.
        XCTAssertEqual(try XCTUnwrap(hud.transfer.p50), 0.83, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(hud.inputSent.p50), 0.6, accuracy: 0.05)
        stats.recordPresented(milliseconds: 3, at: at)
        stats.setStream(StreamInfo(host: "PC", codec: "HEVC", width: 1, height: 1, fps: 120, bitrateMbps: 1,
                                   format: "", link: nil, vsync: false))
        let report = try XCTUnwrap(stats.sessionReport(at: 5 * second, counters: .zero))
        XCTAssertEqual(report.decrypt.count, 2)
        XCTAssertEqual(report.transfer.count, 1)
        XCTAssertEqual(report.inputSent.count, 1)
        XCTAssertEqual(try XCTUnwrap(report.linkBitsPerSecond), 1.2e9, accuracy: 1)
    }
}
