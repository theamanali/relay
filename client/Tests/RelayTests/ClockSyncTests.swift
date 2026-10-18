import XCTest
@testable import Relay

final class ClockSyncTests: XCTestCase {
    /// An exchange where the PC's clock is `offset` ahead, the request takes
    /// `up` µs, the reply `down` µs and the PC holds it `held` µs.
    private func exchange(_ sync: inout ClockSync, at t1: UInt64, offset: Int64,
                          up: UInt64, down: UInt64, held: UInt64 = 0) -> Bool {
        let t2 = UInt64(Int64(t1 + up) + offset)
        let t3 = t2 + held
        let t4 = t1 + up + held + down
        return sync.add(t1: t1, t2: t2, t3: t3, t4: t4)
    }

    func testSymmetricPathsGiveTheExactOffsetWhateverThePCHolds() throws {
        var sync = ClockSync()
        XCTAssertNil(sync.best)
        XCTAssertNil(sync.macMicros(ofHost: 1_000))
        // A reply held 8 ms behind a frame write changes nothing.
        XCTAssertTrue(exchange(&sync, at: 1_000_000, offset: 250_000, up: 300, down: 300, held: 8_000))
        let best = try XCTUnwrap(sync.best)
        XCTAssertEqual(best.offset, 250_000)
        XCTAssertEqual(best.delay, 600)
        XCTAssertEqual(sync.macMicros(ofHost: 2_250_000), 2_000_000)
        XCTAssertNil(sync.macMicros(ofHost: .max), "u64::MAX is unknown")
    }

    func testANegativeOffsetWorks() throws {
        var sync = ClockSync()
        XCTAssertTrue(exchange(&sync, at: 9_000_000, offset: -5_000_000, up: 50, down: 50))
        XCTAssertEqual(try XCTUnwrap(sync.best).offset, -5_000_000)
        XCTAssertEqual(sync.macMicros(ofHost: 4_000_000), 9_000_000)
    }

    func testAsymmetryIsHalfTheErrorAndTheLowestDelayWins() throws {
        var sync = ClockSync()
        // Slow and lopsided (2 ms up, 0.2 ms down): the estimate is off by
        // half the difference, 0.9 ms.
        XCTAssertTrue(exchange(&sync, at: 1_000_000, offset: 10_000, up: 2_000, down: 200))
        XCTAssertEqual(try XCTUnwrap(sync.best).offset, 10_900)
        // A quick, even exchange later replaces it as the estimate.
        XCTAssertTrue(exchange(&sync, at: 2_000_000, offset: 10_000, up: 100, down: 100))
        XCTAssertEqual(try XCTUnwrap(sync.best).offset, 10_000)
        XCTAssertEqual(try XCTUnwrap(sync.best).delay, 200)
    }

    func testKeepsEightAndRefusesStallsAndBrokenStamps() throws {
        var sync = ClockSync()
        XCTAssertFalse(exchange(&sync, at: 1_000, offset: 0, up: 30_000, down: 30_000), "over 50 ms")
        XCTAssertFalse(sync.add(t1: 100, t2: 500, t3: 400, t4: 900), "the PC replied before it received")
        XCTAssertFalse(sync.add(t1: 900, t2: 500, t3: 500, t4: 100), "received before sent")
        XCTAssertNil(sync.best)
        // The best sample ages out after eight newer ones.
        XCTAssertTrue(exchange(&sync, at: 0, offset: 7, up: 10, down: 10))
        for i in 1...8 { XCTAssertTrue(exchange(&sync, at: UInt64(i) * 1_000_000, offset: 0, up: 500, down: 500)) }
        XCTAssertEqual(sync.samples.count, ClockSync.capacity)
        XCTAssertEqual(try XCTUnwrap(sync.best).offset, 0)
    }

    // MARK: parsing

    func testTimeReplyIsAtLeastTwentyFourBytes() throws {
        let body = ext([1, 2, 3], [], [])
        let reply = try XCTUnwrap(Proto.TimeReply(body))
        XCTAssertEqual([reply.clientMicros, reply.hostReceiveMicros, reply.hostSendMicros], [1, 2, 3])
        XCTAssertNotNil(Proto.TimeReply(body + Data([9, 9, 9])), "a longer reply is read, the rest ignored")
        XCTAssertNil(Proto.TimeReply(body.prefix(23)))
    }

    /// FRAME_TIMING_EXT: four u64s, five u32s, two u64s.
    private func ext(_ head: [UInt64], _ mid: [UInt32], _ tail: [UInt64]) -> Data {
        var d = Data()
        head.forEach { d.appendBE64($0) }
        mid.forEach { d.appendBE32($0) }
        tail.forEach { d.appendBE64($0) }
        return d
    }

    private func extPayload() -> Data {
        ext([42, 1_000, 1_800, 4_600], [300, 2_000, 500, .max, 900], [3, 5_000])
    }

    func testFrameTimingExtIsAtLeastSixtyEightBytesAndFeedsFrameTiming() throws {
        XCTAssertEqual(extPayload().count, 68)
        let ext = try XCTUnwrap(Proto.FrameTimingExt(extPayload() + Data(repeating: 0, count: 12)))
        XCTAssertEqual(ext.sequence, 42)
        XCTAssertEqual(ext.presentMicros, 1_000)
        XCTAssertEqual(ext.sentMicros, 4_600)
        XCTAssertEqual(ext.copyGPUMicros, .max)
        XCTAssertEqual(ext.inputsApplied, 3)
        XCTAssertEqual(ext.lastInputMicros, 5_000)
        XCTAssertNil(Proto.FrameTimingExt(extPayload().prefix(67)))
        // Once EXT flows it replaces FRAME_TIMING: PC work comes from it.
        let stats = LatencyStats()
        stats.reset(at: 0)
        stats.record(ext.basic, at: 4_000_000_000)
        XCTAssertEqual(try XCTUnwrap(stats.hudSnapshot(at: 4_000_000_000).host.p50), 2.8, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(stats.hudSnapshot(at: 4_000_000_000).networkHalfRTT), 0.45, accuracy: 0.05)
    }

    func testTimeRequestCarriesTheMacClock() {
        let message = Proto.timeRequest(clientMicros: 0x0102_0304_0506_0708)
        XCTAssertEqual(message.first, 0x88)
        XCTAssertEqual(Data(message.dropFirst(Proto.headerSize)), ext([0x0102_0304_0506_0708], [], []))
        XCTAssertFalse(Proto.isInput(message))
        XCTAssertTrue(Proto.isInput(Proto.mouseMove(x: 0.5, y: 0.5)))
        XCTAssertTrue(Proto.isInput(Proto.key(hidUsage: 4, down: true)))
        XCTAssertFalse(Proto.isInput(Proto.pong(Data(count: 8))))
    }

    // MARK: frames and inputs

    func testAFrameMeasuredAcrossBothClocks() throws {
        var sync = ClockSync()
        XCTAssertTrue(exchange(&sync, at: 10_000, offset: 1_000_000, up: 100, down: 100))
        // The PC is 1 s ahead: its 1,100,000 is the Mac's 100,000.
        let fresh = try XCTUnwrap(Proto.FrameTimingExt(
            ext([1, 1_100_000, 1_100_800, 1_104_000], [1, 1, 1, .max, 1], [0, .max])))
        let t = FrameEndToEnd(sequence: 7, ext: fresh, clock: sync, receivedMicros: 105_500)
        XCTAssertEqual(t.sequence, 7)
        XCTAssertEqual(t.presentMacMicros, 100_000)
        XCTAssertEqual(try XCTUnwrap(t.contentAgeMs), 0.8, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(t.sentToReceivedMs), 1.5, accuracy: 1e-9)
        // A re-encoded tick has no present and no content age.
        let reused = try XCTUnwrap(Proto.FrameTimingExt(
            ext([2, .max, 1_100_800, 1_104_000], [1, 1, 1, .max, 1], [0, .max])))
        let r = FrameEndToEnd(sequence: 8, ext: reused, clock: sync, receivedMicros: 105_500)
        XCTAssertNil(r.presentMacMicros)
        XCTAssertNil(r.contentAgeMs)
        XCTAssertNotNil(r.sentToReceivedMs)
        // Before any sync only content age (one clock) is known.
        let unsynced = FrameEndToEnd(sequence: 9, ext: fresh, clock: ClockSync(), receivedMicros: 105_500)
        XCTAssertNil(unsynced.presentMacMicros)
        XCTAssertNil(unsynced.sentToReceivedMs)
        XCTAssertNotNil(unsynced.contentAgeMs)
    }

    func testInputsAreMatchedByCountIncludingOnesWithoutAnEvent() throws {
        var ledger = InputLedger()
        ledger.didSend(eventTime: 1.000)   // 1: a move
        ledger.didSend(eventTime: nil)     // 2: a key-up released on focus loss
        ledger.didSend(eventTime: 1.010)   // 3
        XCTAssertEqual(ledger.sent, 3)
        // The PC handled two: the second has no event, so no sample.
        XCTAssertNil(ledger.hostApplied(2, atMacMicros: 1_004_000))
        // No change in the count, no sample.
        XCTAssertNil(ledger.hostApplied(2, atMacMicros: 1_005_000))
        // The third, applied 1.2 ms after its event.
        XCTAssertEqual(try XCTUnwrap(ledger.hostApplied(3, atMacMicros: 1_011_200)), 1.2, accuracy: 1e-9)
        // Unsynced: counted, no sample.
        ledger.didSend(eventTime: 2.0)
        XCTAssertNil(ledger.hostApplied(4, atMacMicros: nil))
        XCTAssertEqual(ledger.applied, 4)
    }

    func testObserveSendsNothingSoTheCountsStayEqual() {
        // In Observe StreamView sends no input at all, so the ledger and the
        // PC's count (which includes inputs it does not apply) both stay put.
        var ledger = InputLedger()
        XCTAssertNil(ledger.hostApplied(0, atMacMicros: 5))
        XCTAssertEqual(ledger.sent, 0)
        XCTAssertEqual(ledger.applied, 0)
    }

    func testDesktopToScreenJoinsInEitherOrder() throws {
        let stats = LatencyStats()
        stats.reset(at: 0)
        let at: UInt64 = 4_000_000_000
        stats.recordClock(ClockSync.Sample(offset: 0, delay: 50))
        var frame = FrameEndToEnd(sequence: 1, ext: try XCTUnwrap(Proto.FrameTimingExt(Data(count: 68))),
                                  clock: ClockSync(), receivedMicros: 0)
        // Timing first, then the presentation.
        frame.presentMacMicros = 1_000_000
        stats.record(frame, at: at)
        stats.recordShown(sequence: 1, atMicros: 1_012_000, at: at)
        // Presentation first, then the timing.
        stats.recordShown(sequence: 2, atMicros: 2_014_000, at: at)
        frame.sequence = 2
        frame.presentMacMicros = 2_000_000
        stats.record(frame, at: at)
        let hud = stats.hudSnapshot(at: at)
        XCTAssertEqual(try XCTUnwrap(hud.desktopToScreen.p50), 12, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(hud.desktopToScreen.p95), 14, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(hud.clockDelayMs), 0.05, accuracy: 1e-9)
    }

    func testAnOlderPCGivesNoCrossClockRows() {
        let stats = LatencyStats()
        stats.reset(at: 0)
        stats.recordShown(sequence: 1, atMicros: 1_000, at: 4_000_000_000)
        let hud = stats.hudSnapshot(at: 4_000_000_000)
        XCTAssertNil(hud.desktopToScreen.p50)
        XCTAssertNil(hud.clockOffsetMs)
    }
}
