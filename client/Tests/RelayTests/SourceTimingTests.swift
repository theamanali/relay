import XCTest
@testable import Relay

/// The source may be DDA (8-bit or Winlogon) or WGC (true 10-bit).
/// Missing source stamps are ordinary telemetry, independent of clock sync.
final class SourceTimingTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    private func synced() -> ClockSync {
        var clock = ClockSync()
        clock.add(t1: 1_000_000, t2: 1_000_100, t3: 1_000_100, t4: 1_000_200)
        return clock
    }

    private func frame(sequence: UInt64 = 1, present: UInt64 = 4_000_000,
                       submit: UInt64 = 4_001_000, sent: UInt64 = 4_004_000,
                       received: UInt64 = 4_005_000, clock: ClockSync? = nil) throws -> FrameEndToEnd {
        var data = Data()
        [sequence, present, submit, sent].forEach { data.appendBE64($0) }
        for field: UInt32 in [500, 2_000, 500, .max, 200] { data.appendBE32(field) }
        data.appendBE64(0); data.appendBE64(.max)
        return FrameEndToEnd(sequence: sequence, ext: try XCTUnwrap(Proto.FrameTimingExt(data)),
                             clock: clock ?? synced(), receivedMicros: received)
    }

    func testEncodeSendNeedsNeitherSourceNorSyncAndIsNotPCWork() throws {
        let f = try frame(present: .max, clock: ClockSync())
        XCTAssertEqual(f.encodeSendMs, 3)
        XCTAssertNil(f.presentMacMicros)
        XCTAssertNil(f.contentAgeMs)
        XCTAssertNil(f.sentToReceivedMs)
        let stats = LatencyStats()
        stats.reset(at: 0)
        stats.record(f, at: 4 * second)
        stats.record(Proto.FrameTiming(sequence: 1, captureMicros: 500, encodeMicros: 2_000,
                                      sendMicros: 500, networkRTTMicros: 200), at: 4 * second)
        let hud = stats.hudSnapshot(at: 4 * second)
        XCTAssertEqual(hud.encodeSend.p50, 3)
        XCTAssertEqual(hud.host.p50, 3)
        XCTAssertNil(hud.clockOffsetMs)
        XCTAssertTrue(StatsHUD.Summary(hud).groups[0].detail.contains("encode & send 3.0"))
        XCTAssertTrue(StatsHUD.Summary(hud).unsyncedNote?.contains("clock not synced") == true)
    }

    func testStaticMovingStaticAndCaptureRecoveryKeepSyncWithoutStaleMeasurements() throws {
        let stats = LatencyStats()
        stats.reset(at: 0)
        let clock = synced()
        stats.recordClock(try XCTUnwrap(clock.best))
        stats.record(try frame(), at: 4 * second)
        stats.recordShown(sequence: 1, atMicros: 4_010_000, at: 4 * second)
        XCTAssertEqual(stats.hudSnapshot(at: 4 * second).desktopToScreen.p50, 10)
        // More than ten seconds of repeats and then a capture gap. Replies
        // continue; neither the clock nor the stream is reset by static video.
        // During the grace window, the sparkline carries the previous frame's
        // latency forward on every presented frame so it doesn't freeze.
        for t in 5...8 {
            stats.recordClock(try XCTUnwrap(clock.best))
            stats.record(try frame(sequence: UInt64(t), present: .max), at: UInt64(t) * second)
            stats.recordPresented(milliseconds: 4, at: UInt64(t) * second)
        }
        var hud = stats.hudSnapshot(at: 8 * second)
        XCTAssertEqual(hud.desktopToScreen.p50, 10)
        XCTAssertEqual(hud.desktopSparkline, [10, 10, 10, 10, 10], "sparkline carries forward previous latency")
        for t in 9...15 {
            stats.recordClock(try XCTUnwrap(clock.best))
            stats.record(try frame(sequence: UInt64(t), present: .max), at: UInt64(t) * second)
            stats.recordPresented(milliseconds: 4, at: UInt64(t) * second)
        }
        hud = stats.hudSnapshot(at: 15 * second)
        XCTAssertNotNil(hud.clockOffsetMs)
        XCTAssertNil(hud.contentAge.p50)
        XCTAssertNil(hud.desktopToScreen.p50)
        XCTAssertTrue(hud.desktopSparkline.isEmpty)
        XCTAssertEqual(hud.encodeSend.p50, 3)
        XCTAssertEqual(StatsHUD.Summary(hud).median, 4)
        XCTAssertEqual(StatsHUD.Summary(hud).unsyncedNote, "Receive → screen, source timing idle")
        XCTAssertTrue(StatsHUD.Summary(hud).groups[0].detail.contains("encode & send 3.0"))
        // Fresh content after a source/recovery transition, same connection.
        stats.record(try frame(sequence: 16, present: 16_000_000, submit: 16_002_000,
                               sent: 16_005_000, received: 16_006_000), at: 16 * second)
        stats.recordShown(sequence: 16, atMicros: 16_012_000, at: 16 * second)
        hud = stats.hudSnapshot(at: 16 * second)
        XCTAssertEqual(hud.desktopToScreen.p50, 12)
        XCTAssertEqual(hud.contentAge.p50, 2)
        XCTAssertEqual(hud.desktopSparkline, [12], "expired source points must not reappear when motion returns")
        XCTAssertNil(StatsHUD.Summary(hud).unsyncedNote)
        hud = stats.hudSnapshot(at: 27 * second)
        XCTAssertNil(hud.desktopToScreen.p50)
        XCTAssertNil(hud.contentAge.p50)
        XCTAssertNil(hud.encodeSend.p50)
        XCTAssertNotNil(hud.clockDelayMs)
        XCTAssertEqual(StatsHUD.Summary(hud).unsyncedNote, "Receive → screen, source timing idle")
    }

    func testMissingAndInvalidSyncDoNotClaimSynchronized() throws {
        var clock = ClockSync()
        XCTAssertFalse(clock.add(t1: 900, t2: 1, t3: 2, t4: 100))
        XCTAssertFalse(clock.add(t1: 1, t2: .max, t3: .max, t4: 2))
        XCTAssertFalse(clock.add(t1: 0, t2: 1, t3: 1, t4: 60_000))
        XCTAssertNil(clock.best)
        let f = try frame(clock: clock)
        XCTAssertNil(f.presentMacMicros)
        XCTAssertNil(f.sentToReceivedMs)
        XCTAssertEqual(f.contentAgeMs, 1)
        XCTAssertEqual(f.encodeSendMs, 3)
    }

    func testHUDTimingLabelsAndFallbacksAreIndependentOfDepthAndChroma() throws {
        let stats = LatencyStats()
        stats.reset(at: 0)
        stats.recordClock(try XCTUnwrap(synced().best))
        stats.record(try frame(present: .max), at: 4 * second)
        stats.recordPresented(milliseconds: 4, at: 4 * second)
        let hud = stats.hudSnapshot(at: 4 * second)
        let expected = StatsHUD.Summary(hud)
        for format in ["Fastest", "4:4:4, Fastest", "10-bit, Fastest", "4:4:4, 10-bit, Fastest"] {
            var s = hud
            s.stream = .widest
            s.stream?.format = format
            s.stream?.fps = 60 // default snapshot budget
            XCTAssertEqual(StatsHUD.Summary(s), expected, format)
        }
    }

    func testFutureUnknownZeroAndReversedStamps() throws {
        let futureSource = try frame(present: 4_002_000)
        XCTAssertNil(futureSource.presentMacMicros)
        XCTAssertNil(futureSource.contentAgeMs)
        XCTAssertEqual(futureSource.encodeSendMs, 3)
        XCTAssertEqual(futureSource.sentToReceivedMs, 1)
        let reversedSend = try frame(sent: 4_000_500)
        XCTAssertNil(reversedSend.encodeSendMs)
        XCTAssertNil(reversedSend.contentAgeMs)
        XCTAssertNil(reversedSend.presentMacMicros)
        XCTAssertNil(reversedSend.sentToReceivedMs)
        for invalid: UInt64 in [0, .max, UInt64(Int64.max) + 1] {
            let f = try frame(present: invalid, submit: invalid, sent: invalid)
            XCTAssertNil(f.presentMacMicros)
            XCTAssertNil(f.contentAgeMs)
            XCTAssertNil(f.encodeSendMs)
            XCTAssertNil(f.sentToReceivedMs)
        }
        let future = try frame(received: 3_000_000)
        XCTAssertNil(future.presentMacMicros)
        XCTAssertNil(future.sentToReceivedMs)
        XCTAssertEqual(future.encodeSendMs, 3, "host-local duration still valid")
    }

    func testNegativePresentationCannotPolluteSparklineOrTimeline() throws {
        let stats = LatencyStats()
        stats.reset(at: 0)
        stats.recordClock(try XCTUnwrap(synced().best))
        stats.record(try frame(), at: 4 * second)
        stats.recordShown(sequence: 1, atMicros: 3_999_999, at: 4 * second)
        let hud = stats.hudSnapshot(at: 4 * second)
        XCTAssertNil(hud.desktopToScreen.p50)
        XCTAssertTrue(hud.desktopSparkline.isEmpty)
    }

    func testReportRetainsIndependentDurationWithUnknownSource() throws {
        let stats = LatencyStats()
        stats.reset(stream: .widest, at: 0)
        stats.record(try frame(present: .max, clock: ClockSync()), at: 4 * second)
        stats.recordPresented(milliseconds: 4, at: 4 * second)
        let report = try XCTUnwrap(stats.sessionReport(at: 5 * second, counters: .zero))
        XCTAssertTrue(report.markdown.contains("| Encode & send | 3.0 | 3.0 | 3.0 | 3.0 | 1 |"))
        XCTAssertNil(report.contentAge.percentile(0.5))
        stats.reset(at: 6 * second)
        XCTAssertNil(stats.hudSnapshot(at: 10 * second).encodeSend.p50)
    }
}
