import XCTest
@testable import Relay

final class StreamModeTests: XCTestCase {
    // Built-in panels: 13" Air, 14" Pro, 16" Pro, 15" Air.
    private let panels: [(CGSize, Int, [(Int, Int)])] = [
        (CGSize(width: 2560, height: 1664), 60, [(2560, 1664), (1920, 1248), (1280, 832)]),
        (CGSize(width: 3024, height: 1964), 120, [(3024, 1964), (2268, 1474), (1512, 982)]),
        (CGSize(width: 3456, height: 2234), 120, [(3456, 2234), (2592, 1676), (1728, 1118)]),
        (CGSize(width: 2880, height: 1864), 60, [(2880, 1864), (2160, 1398), (1440, 932)]),
    ]

    func testSizesAreEvenAndSameAspectOnEveryPanel() {
        for (native, _, expected) in panels {
            let sizes = StreamMode.sizes(native: native)
            XCTAssertEqual(sizes.map { $0.scale }, [1.0, 0.75, 0.5])
            for (got, want) in zip(sizes, expected) {
                XCTAssertEqual(got.width, want.0, "\(native)")
                XCTAssertEqual(got.height, want.1, "\(native)")
                XCTAssertEqual(got.width % 2, 0); XCTAssertEqual(got.height % 2, 0)
            }
        }
    }

    func testRefreshRatesFollowThePanel() {
        XCTAssertEqual(StreamMode.refreshRates(max: 120), [120, 60])
        XCTAssertEqual(StreamMode.refreshRates(max: 60), [60])
        XCTAssertEqual(StreamMode.refreshRates(max: 0), [60], "unknown max falls back to 60")
        XCTAssertEqual(StreamMode.refreshRates(max: 48), [48], "odd panels still get one entry")
        for (_, max, _) in panels { XCTAssertEqual(StreamMode.refreshRates(max: max).first, max) }
    }

    func testSavedModeClampsToTheCurrentPanel() {
        let saved = StreamMode(scale: 0.75, refresh: 120)
        XCTAssertEqual(saved.clamped(toMaxRefresh: 60), StreamMode(scale: 0.75, refresh: 60))
        XCTAssertEqual(saved.clamped(toMaxRefresh: 120), saved)
        XCTAssertEqual(StreamMode(scale: 0.6, refresh: 90).clamped(toMaxRefresh: 120), StreamMode(scale: 1.0, refresh: 120))
    }

    func testFlagsRecordWhetherGiven() {
        XCTAssertFalse(LaunchOptions.parse(["Relay"]).scaleGiven)
        XCTAssertFalse(LaunchOptions.parse(["Relay"]).maxFPSGiven)
        let o = LaunchOptions.parse(["Relay", "--scale", "0.5", "--max-fps", "60"])
        XCTAssertTrue(o.scaleGiven); XCTAssertEqual(o.scale, 0.5)
        XCTAssertTrue(o.maxFPSGiven); XCTAssertEqual(o.maxFPS, 60)

        XCTAssertFalse(LaunchOptions.parse(["Relay"]).bitrateGiven)
        let bitrate = LaunchOptions.parse(["Relay", "--bitrate", "500"])
        XCTAssertTrue(bitrate.bitrateGiven)
        XCTAssertEqual(bitrate.bitrateMbps, 500)
    }
}
