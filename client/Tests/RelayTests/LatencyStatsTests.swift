import XCTest
@testable import Relay

final class LatencyStatsTests: XCTestCase {
    func testBackendMetricsCannotMasqueradeAsSameLatency() {
        let stats = LatencyStats()
        stats.recordVideoPerformance(VideoPerformanceSnapshot(clientMilliseconds: 2, droppedFrames: 0))
        let av = stats.snapshot().overlayText
        XCTAssertTrue(av.contains("AV scheduling delay"))
        XCTAssertTrue(av.contains("Rx→present unavailable"))
        XCTAssertFalse(av.contains("Total est."))
        stats.recordVideoPerformance(VideoPerformanceSnapshot(clientMilliseconds: 10, droppedFrames: 3,
            clientP95: 15, backend: "metal", replaced: 1100, late: 2, samples: 600))
        let metal = stats.snapshot().overlayText
        XCTAssertTrue(metal.contains("Metal Rx→present (last 600)"))
        XCTAssertTrue(metal.contains("replaced    1100"))
        XCTAssertTrue(metal.contains("zero-time callbacks 3"))
        XCTAssertFalse(metal.contains("AV reported drops"))
    }

    func testUnavailableMetricsClearPreviousValues() {
        let stats = LatencyStats()
        stats.recordVideoPerformance(VideoPerformanceSnapshot(clientMilliseconds: 10, droppedFrames: 3))
        stats.recordVideoPerformance(nil)
        XCTAssertNil(stats.snapshot().clientAverage)
        XCTAssertTrue(stats.snapshot().overlayText.contains("Presentation metrics unavailable"))
    }

    func testRollingDecodeWindowAndInvalidSamples() {
        let stats = LatencyStats()
        for n in 0..<600 { stats.recordFrame(sequence: UInt64(n), decodeMilliseconds: 100) }
        for n in 600..<1200 { stats.recordFrame(sequence: UInt64(n), decodeMilliseconds: 2) }
        stats.recordFrame(sequence: 1200, decodeMilliseconds: .nan)
        stats.recordFrame(sequence: 1201, decodeMilliseconds: -1)
        XCTAssertEqual(stats.snapshot().decodeMedian, 2)
        stats.reset()
        XCTAssertNil(stats.snapshot().decodeMedian)
    }
}
