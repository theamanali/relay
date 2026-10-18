import CoreGraphics
import XCTest
@testable import Relay

final class StatsHUDTests: XCTestCase {
    private func snapshot() -> LatencyStats.HUDSnapshot {
        var toScreen = LatencyHistogram(), host = LatencyHistogram()
        (0..<100).forEach { toScreen.record($0 < 90 ? 5.4 : 9.2); host.record(4.1) }
        return LatencyStats.HUDSnapshot(
            presentedFPS: 119.8, decodedFPS: 120.1, toScreen: .init(toScreen), decode: .init(LatencyHistogram()),
            host: .init(host), networkHalfRTT: 0.21,
            transfer: .init(LatencyHistogram()), inputSent: .init(LatencyHistogram()), sparkline: (0..<480).map { 5 + Double($0 % 9) / 3 },
            frameBudget: 1_000 / 120,
            stream: StreamInfo(host: "Gaming PC", codec: "HEVC", width: 3024, height: 1964, fps: 120,
                               bitrateMbps: 120, format: "4:4:4 · Balanced", link: "Ethernet", vsync: false),
            counters: PresenterCounters(replaced: 3, late: 1, dropped: 0, unavailable: 0, gpuFailures: 0))
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        let data = image.dataProvider!.data! as Data
        return data[y * image.bytesPerRow + x * 4 + 3]
    }

    func testCompactPanelIsDrawnAtTheBackingScale() throws {
        let image = try XCTUnwrap(StatsHUD.render(snapshot(), mode: .compact, scale: 2))
        XCTAssertEqual(image.width, Int(StatsHUD.width * 2))
        XCTAssertEqual(alpha(image, x: 0, y: 0), 0, "rounded corner stays transparent")
        XCTAssertGreaterThan(alpha(image, x: image.width / 2, y: image.height / 2), 100, "panel body is drawn")
    }

    func testDetailedIsTallerThanCompactAndOffDrawsNothing() throws {
        let compact = try XCTUnwrap(StatsHUD.render(snapshot(), mode: .compact, scale: 1))
        let detailed = try XCTUnwrap(StatsHUD.render(snapshot(), mode: .detailed, scale: 1))
        XCTAssertGreaterThan(detailed.height, compact.height)
        XCTAssertNil(StatsHUD.render(snapshot(), mode: .off, scale: 1))
    }

    func testBudgetColorThresholds() {
        XCTAssertEqual(StatsHUD.Level(value: 5, budget: 8.33), .good)
        XCTAssertEqual(StatsHUD.Level(value: 7, budget: 8.33), .warning)
        XCTAssertEqual(StatsHUD.Level(value: 9, budget: 8.33), .bad)
    }

    func testModeCycles() {
        XCTAssertEqual(HUDMode.off.next, .compact)
        XCTAssertEqual(HUDMode.compact.next, .detailed)
        XCTAssertEqual(HUDMode.detailed.next, .off)
    }
}
