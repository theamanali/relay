import AppKit
import XCTest
@testable import Relay

final class LatencyHistogramTests: XCTestCase {
    /// Nearest-rank percentile of the raw samples, for comparison.
    private func exact(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
    }

    func testPercentilesWithinOneBinOfSortedSamples() {
        var h = LatencyHistogram()
        var rng = SystemRandomNumberGenerator()
        let values = (0..<5_000).map { _ in Double.random(in: 0.5...14, using: &rng) }
        values.forEach { h.record($0) }
        for p in [0.5, 0.95, 0.99] {
            let got = try! XCTUnwrap(h.percentile(p))
            XCTAssertEqual(got, exact(values, p), accuracy: LatencyHistogram.binWidth, "p\(p)")
        }
        XCTAssertEqual(h.count, 5_000)
        XCTAssertEqual(h.max, values.max()!)
        XCTAssertEqual(try XCTUnwrap(h.mean), values.reduce(0, +) / 5_000, accuracy: 1e-9)
    }

    func testOverflowReportsTheLargestSample() {
        var h = LatencyHistogram()
        for _ in 0..<99 { h.record(2) }
        h.record(180)
        XCTAssertEqual(h.percentile(1), 180)
        XCTAssertEqual(try XCTUnwrap(h.percentile(0.5)), 2, accuracy: LatencyHistogram.binWidth)
    }

    func testInvalidSamplesAreIgnoredAndEmptyHasNoPercentile() {
        var h = LatencyHistogram()
        h.record(.nan); h.record(-1); h.record(.infinity)
        XCTAssertEqual(h.count, 0)
        XCTAssertNil(h.percentile(0.5))
        XCTAssertNil(h.mean)
    }

    func testMergeAddsCounts() {
        var a = LatencyHistogram(), b = LatencyHistogram()
        a.record(1); b.record(3); b.record(3)
        a.merge(b)
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(a.max, 3)
        XCTAssertEqual(try XCTUnwrap(a.percentile(0.5)), 3, accuracy: LatencyHistogram.binWidth)
    }

    func testCoarseBinsForTheReportChart() {
        var h = LatencyHistogram()
        [0.2, 0.4, 1.2, 1.3, 1.4, 60].forEach { h.record($0) }
        let bars = h.bars(width: 1, upTo: 3)
        XCTAssertEqual(bars.map(\.count), [2, 3, 0, 1]) // last bar: 3 ms and above
        XCTAssertEqual(bars.map(\.start), [0, 1, 2, 3])
    }
}

final class LatencyWindowTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    func testOldSamplesAgeOutOfTheWindow() {
        var w = LatencyWindow(seconds: 5)
        let t0: UInt64 = 100 * second
        for _ in 0..<10 { w.record(100, at: t0) }
        for _ in 0..<10 { w.record(2, at: t0 + 3 * second) }
        XCTAssertEqual(w.merged(at: t0 + 3 * second).count, 20)
        XCTAssertEqual(w.merged(at: t0 + 5 * second).count, 10)
        XCTAssertEqual(try XCTUnwrap(w.merged(at: t0 + 5 * second).percentile(0.99)), 2,
                       accuracy: LatencyHistogram.binWidth)
        XCTAssertEqual(w.merged(at: t0 + 9 * second).count, 0)
    }

    func testRecentSamplesKeepTheNewestInOrder() {
        var r = RecentSamples(capacity: 4)
        (1...6).forEach { r.append(Double($0)) }
        XCTAssertEqual(r.ordered, [3, 4, 5, 6])
    }
}

final class LatencyStatsTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000
    private let stream = StreamInfo(host: "Gaming PC", codec: "HEVC", width: 3024, height: 1964, fps: 120,
                                    bitrateMbps: 120, format: "4:4:4, Balanced", link: "Ethernet", vsync: false)

    @MainActor func testReportFitsTheWidestSummaryOnOneLine() {
        // The screenshot's line, and the widest the app can produce.
        let seen = StreamInfo(host: "", codec: "HEVC", width: 3024, height: 1964, fps: 120, bitrateMbps: 120,
                              format: "4:4:4, 10-bit, Fastest", link: "Ethernet", vsync: false)
        let font = NSFont.preferredFont(forTextStyle: .callout)
        func width(_ s: StreamInfo) -> CGFloat { (s.summary as NSString).size(withAttributes: [.font: font]).width }
        XCTAssertGreaterThan(width(StreamInfo.widest), width(seen))
        XCTAssertLessThanOrEqual(width(StreamInfo.widest), SessionReportView.width - 2 * Style.Space.margin)
        XCTAssertGreaterThanOrEqual(SessionReportView.width, 520)
    }

    func testHUDSnapshotCoversTheLastFewSeconds() {
        let stats = LatencyStats()
        let t0: UInt64 = 50 * second
        stats.reset(stream: stream, at: t0 - LatencyStats.warmUp)
        for i in 0..<240 {
            let t = t0 + UInt64(i) * second / 120
            stats.recordPresented(milliseconds: i < 120 ? 5 : 7, at: t)
            stats.recordDecoded(milliseconds: 1.5, at: t)
        }
        stats.record(Proto.FrameTiming(sequence: 1, captureMicros: 1_000, encodeMicros: 3_000,
                                       sendMicros: 100, networkRTTMicros: 400), at: t0 + second)
        let s = stats.hudSnapshot(at: t0 + 2 * second)
        XCTAssertEqual(s.presentedFPS, 120, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(s.toScreen.p50), 5, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(s.toScreen.p95), 7, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(s.host.p50), 4.1, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(s.networkHalfRTT), 0.2, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(s.decode.p50), 1.5, accuracy: 0.1)
        XCTAssertEqual(s.sparkline.count, 240)
        XCTAssertEqual(s.frameBudget, 1_000.0 / 120, accuracy: 1e-9)
        XCTAssertEqual(s.stream, stream)
    }

    func testTheFirstThreeSecondsAreNotMeasured() throws {
        let stats = LatencyStats()
        let t0: UInt64 = 20 * second
        stats.reset(stream: stream, at: t0)
        // Start-up: a slow first keyframe and decoder warm-up.
        stats.recordPresented(milliseconds: 60, at: t0 + second)
        stats.recordDecoded(milliseconds: 40, at: t0 + second)
        stats.record(Proto.FrameTiming(sequence: 1, captureMicros: 9_000, encodeMicros: 9_000,
                                       sendMicros: 9_000, networkRTTMicros: 9_000), at: t0 + second)
        XCTAssertTrue(stats.hudSnapshot(at: t0 + 2 * second).warmingUp)
        XCTAssertEqual(LatencyStats.warmUp, 3 * second)

        for i in 0..<120 { stats.recordPresented(milliseconds: 5, at: t0 + 3 * second + UInt64(i) * second / 120) }
        let s = stats.hudSnapshot(at: t0 + 4 * second)
        XCTAssertFalse(s.warmingUp)
        XCTAssertEqual(s.toScreen.p99, 5)
        XCTAssertNil(s.decode.p50)
        XCTAssertNil(s.host.p50)
        XCTAssertNil(s.networkHalfRTT)
        XCTAssertEqual(s.sparkline.count, 120)
        XCTAssertEqual(s.presentedFPS, 120, accuracy: 1)

        let report = try XCTUnwrap(stats.sessionReport(at: t0 + 4 * second, counters: .zero))
        XCTAssertEqual(report.toScreen.count, 120)
        XCTAssertEqual(report.toScreen.max, 5)
        XCTAssertEqual(report.duration, 1, accuracy: 1e-9, "measured from the end of the warm-up")
    }

    func testNoReportForASessionThatEndsDuringWarmUp() {
        let stats = LatencyStats()
        stats.reset(stream: stream, at: second)
        stats.recordPresented(milliseconds: 5, at: 2 * second)
        XCTAssertNil(stats.sessionReport(at: 3 * second, counters: .zero))
    }

    func testUnknownHostFieldsAreNotRecorded() {
        let stats = LatencyStats()
        stats.reset(stream: stream, at: second)
        let after = second + LatencyStats.warmUp
        stats.record(Proto.FrameTiming(sequence: 1, captureMicros: Proto.FrameTiming.unknownMicros,
                                       encodeMicros: 1, sendMicros: 1,
                                       networkRTTMicros: Proto.FrameTiming.unknownMicros), at: after)
        let s = stats.hudSnapshot(at: after)
        XCTAssertNil(s.host.p50)
        XCTAssertNil(s.networkHalfRTT)
    }

    func testSessionReportKeepsEveryFrameAndTheCounters() throws {
        let stats = LatencyStats()
        let t0: UInt64 = 10 * second
        stats.reset(stream: stream, at: t0 - LatencyStats.warmUp)
        for i in 0..<1_200 { stats.recordPresented(milliseconds: i == 0 ? 30 : 5, at: t0 + UInt64(i) * second / 120) }
        let counters = PresenterCounters(replaced: 7, late: 2, dropped: 1, unavailable: 0, gpuFailures: 0)
        let report = try XCTUnwrap(stats.sessionReport(at: t0 + 10 * second, counters: counters,
                                                         endedAt: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(report.duration, 10, accuracy: 1e-9)
        XCTAssertEqual(report.toScreen.count, 1_200)
        XCTAssertEqual(report.toScreen.max, 30)
        XCTAssertEqual(report.presentedFPS, 120, accuracy: 0.5)
        XCTAssertEqual(report.counters, counters)
        XCTAssertEqual(report.stream, stream)
    }

    func testNoReportWithoutAStreamOrFrames() {
        let stats = LatencyStats()
        XCTAssertNil(stats.sessionReport(at: second, counters: .zero))
        stats.reset(stream: stream, at: second)
        XCTAssertNil(stats.sessionReport(at: 2 * second, counters: .zero))
    }

    func testResetClearsTheSession() {
        let stats = LatencyStats()
        stats.reset(stream: stream, at: second)
        stats.recordPresented(milliseconds: 5, at: 5 * second)
        stats.reset(stream: stream, at: 6 * second)
        XCTAssertNil(stats.hudSnapshot(at: 10 * second).toScreen.p50)
        XCTAssertTrue(stats.hudSnapshot(at: 10 * second).sparkline.isEmpty)
    }
}

final class SessionReportTests: XCTestCase {
    func testMarkdownNamesTheSettingsAndStages() {
        var toScreen = LatencyHistogram()
        (0..<100).forEach { toScreen.record($0 < 94 ? 5 : 9) }
        let report = SessionReport(
            stream: StreamInfo(host: "Gaming PC", codec: "HEVC", width: 3024, height: 1964, fps: 120,
                               bitrateMbps: 120, format: "4:4:4, Balanced", link: "Ethernet", vsync: false),
            endedAt: Date(timeIntervalSince1970: 0), duration: 61, presentedFPS: 119.6,
            toScreen: toScreen, decode: LatencyHistogram(), host: LatencyHistogram(), network: LatencyHistogram(),
            transfer: LatencyHistogram(), inputSent: LatencyHistogram(), decrypt: LatencyHistogram(),
            desktopToScreen: LatencyHistogram(), contentAge: LatencyHistogram(),
            sentToReceived: LatencyHistogram(), inputApplied: LatencyHistogram(),
            clock: ClockSync.Sample(offset: 12_345, delay: 81),
            linkBitsPerSecond: 2.5e9,
            counters: PresenterCounters(replaced: 3, late: 1, dropped: 0, unavailable: 0, gpuFailures: 0))
        let md = report.markdown
        XCTAssertTrue(md.contains("HEVC 3024×1964 @ 120 Hz, 120 Mbps, 4:4:4, Balanced, Ethernet, VSync off"), md)
        XCTAssertTrue(md.contains("| Receive → screen | 5.0 | 9.0 | 9.0 | 9.0 | 100 |"), md)
        XCTAssertTrue(md.contains("| Receive → decode | – | – | – | – | 0 |"), md)
        XCTAssertTrue(md.contains("replaced 3, late 1, dropped 0. Frame data arrived at 2.50 Gb/s"), md)
        XCTAssertTrue(md.contains("| Input → sent | – | – | – | – | 0 |"), md)
        XCTAssertTrue(md.contains("PC clock +12.345 ms from this Mac (best delay 0.081 ms)"), md)
        XCTAssertTrue(md.contains("1:01"), md)
        XCTAssertFalse(report.logLine.contains("\n"))
    }
}

final class SessionReportSummaryTests: XCTestCase {
    func testSecondMediansKeepGapsAndTheSecondInProgress() {
        var t = SecondMedians()
        t.record(5, second: 0); t.record(7, second: 0); t.record(9, second: 0)
        t.record(20, second: 2)
        XCTAssertEqual(t.medians, [7], "second 2 is still in progress")
        XCTAssertEqual(t.all, [7, nil, 20])
        t.record(4, second: -1)
        XCTAssertEqual(t.all, [7, nil, 20], "before measurement started")
    }

    private func histogram(_ values: [Double]) -> LatencyHistogram {
        var h = LatencyHistogram(); values.forEach { h.record($0) }; return h
    }

    private func report(synced: Bool, replaced: Int = 4, dropped: Int = 1) -> SessionReport {
        SessionReport(
            stream: StreamInfo(host: "PC", codec: "HEVC", width: 3024, height: 1964, fps: 120, bitrateMbps: 120,
                               format: "", link: "Ethernet", vsync: false),
            endedAt: Date(timeIntervalSince1970: 0), duration: 10, presentedFPS: 119,
            toScreen: histogram([4.4]), decode: histogram(Array(repeating: 3.0, count: 1_000)),
            host: histogram([7.0]), network: histogram([0.9]), transfer: LatencyHistogram(),
            inputSent: histogram([0.5]), decrypt: LatencyHistogram(),
            desktopToScreen: synced ? histogram([14.9]) : LatencyHistogram(),
            contentAge: synced ? histogram([3.3]) : LatencyHistogram(),
            sentToReceived: synced ? histogram([0.4]) : LatencyHistogram(),
            inputApplied: synced ? histogram([1.1]) : LatencyHistogram(),
            clock: synced ? ClockSync.Sample(offset: 1, delay: 500) : nil, linkBitsPerSecond: nil,
            counters: PresenterCounters(replaced: replaced, late: 0, dropped: dropped, unavailable: 0, gpuFailures: 0),
            timeline: [14, nil, 16])
    }

    func testTheReportLeadsLikeTheHUD() throws {
        let synced = report(synced: true)
        XCTAssertEqual(synced.summary.label, "PC → your screen, median")
        XCTAssertEqual(try XCTUnwrap(synced.summary.median), 14.9, accuracy: 0.05)
        XCTAssertEqual(synced.headline.count, 1)
        XCTAssertEqual(try XCTUnwrap(synced.summary.groups[0].milliseconds), 10.3, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(synced.summary.input), 1.1, accuracy: 0.05)
        let older = report(synced: false)
        XCTAssertEqual(older.summary.label, "receive → screen, median")
        XCTAssertEqual(try XCTUnwrap(older.headline.percentile(0.5)), 4.4, accuracy: 0.05)
        XCTAssertEqual(older.summary.inputLabel, "Input → sent")
    }

    func testSkippedFramesInPlainWords() {
        XCTAssertEqual(report(synced: true).skippedText, "Skipped 0.5% of frames") // 5 of 1,000 decoded
        XCTAssertEqual(report(synced: true, replaced: 0, dropped: 0).skippedText, "Skipped 0.0% of frames")
        XCTAssertEqual(report(synced: true, replaced: 0, dropped: 0).skippedFraction, 0)
    }

    func testMarkdownLeadsWithTheBreakdown() {
        let md = report(synced: true).markdown
        XCTAssertTrue(md.contains("PC → your screen p50 14.9 p95 14.9, PC 10.3, Network 0.4, Mac 4.4, "
            + "Input → PC 1.1, skipped 0.5% of frames (ms)"), md)
        XCTAssertTrue(md.contains("| Desktop → screen |"), "the full table is still there")
    }

    func testDataRateAndTotal() throws {
        var w = ByteWindow(seconds: 5)
        let second: UInt64 = 1_000_000_000
        w.add(6_000_000, at: 10 * second)
        w.add(6_000_000, at: 11 * second)
        XCTAssertEqual(w.total(at: 11 * second), 12_000_000)
        XCTAssertEqual(w.total(at: 16 * second), 0, "aged out")
        let stats = LatencyStats()
        stats.reset(at: 0)
        stats.record(ReceiveTiming(wireBytes: 3_000_000, lateBytes: 0, lateNanos: 0, decryptNanos: 0), at: 4 * second)
        stats.record(ReceiveTiming(wireBytes: 3_000_000, lateBytes: 0, lateNanos: 0, decryptNanos: 0), at: 5 * second)
        // 6 MB over the two seconds since measuring began (3 s warm-up): 24 Mbps.
        XCTAssertEqual(try XCTUnwrap(stats.hudSnapshot(at: 5 * second).receivedMbps), 24, accuracy: 0.5)
        var r = report(synced: true)
        XCTAssertNil(r.dataText)
        r.receivedBytes = 1_250_000_000 // 10 s
        XCTAssertEqual(r.dataText, "Received 1.2 GB, 1000 Mbps on average")
        r.receivedBytes = 60_000_000
        XCTAssertEqual(r.dataText, "Received 60 MB, 48 Mbps on average")
        XCTAssertTrue(r.markdown.contains("(ms). Received 60 MB, 48 Mbps on average"), r.markdown)
    }
}
