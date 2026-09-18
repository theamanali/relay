import XCTest
@testable import Relay

final class VideoBitrateTests: XCTestCase {
    func testLimitsAndDefault() {
        XCTAssertEqual(VideoBitrate.defaultValue, 120)
        XCTAssertEqual(VideoBitrate.clamp(-1), 1)
        XCTAssertEqual(VideoBitrate.clamp(1), 1)
        XCTAssertEqual(VideoBitrate.clamp(1_000), 1_000)
        XCTAssertEqual(VideoBitrate.clamp(10_000), 1_000)
    }

    func testLogarithmicSliderEndpointsAndRoundTrips() {
        XCTAssertEqual(VideoBitrate.sliderPosition(for: 1), 0, accuracy: 0.000_001)
        XCTAssertEqual(VideoBitrate.sliderPosition(for: 1_000), 1, accuracy: 0.000_001)
        XCTAssertEqual(VideoBitrate.bitrate(forSliderPosition: 0), 1)
        XCTAssertEqual(VideoBitrate.bitrate(forSliderPosition: 1), 1_000)
        for bitrate in 1...1_000 {
            XCTAssertEqual(
                VideoBitrate.bitrate(forSliderPosition: VideoBitrate.sliderPosition(for: bitrate)),
                bitrate
            )
        }
    }
}
