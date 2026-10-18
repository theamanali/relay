import AppKit
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
                               bitrateMbps: 120, format: "4:4:4, Balanced", link: "Ethernet", vsync: false),
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

    private func synced(_ base: LatencyStats.HUDSnapshot) -> LatencyStats.HUDSnapshot {
        var s = base
        func stage(_ v: Double) -> LatencyStats.Stage { var h = LatencyHistogram(); h.record(v); return .init(h) }
        s.desktopToScreen = stage(16.2)
        s.contentAge = stage(3.3)
        s.sentToReceived = stage(0.4)
        s.inputApplied = stage(1.1)
        s.desktopSparkline = [15, 16, 17]
        return s
    }

    func testTheHeadlineIsPCToScreenOnceSynced() throws {
        let summary = StatsHUD.Summary(synced(snapshot()))
        XCTAssertEqual(summary.label, "PC → your screen, median")
        XCTAssertEqual(try XCTUnwrap(summary.median), 16.2, accuracy: 0.05)
        XCTAssertEqual(summary.sparkline, [15, 16, 17])
        XCTAssertEqual(summary.budget, 3 * 1_000 / 120, accuracy: 1e-9)
        XCTAssertEqual(summary.groups.map(\.name), ["PC", "Network", "Mac"])
        // PC = image age + PC work; the network is measured one way.
        XCTAssertEqual(try XCTUnwrap(summary.groups[0].milliseconds), 3.3 + 4.1, accuracy: 0.1)
        XCTAssertEqual(summary.groups[0].detail, "image age 3.3, encode & send 4.1")
        XCTAssertEqual(try XCTUnwrap(summary.groups[1].milliseconds), 0.4, accuracy: 0.05)
        XCTAssertEqual(summary.groups[1].detail, "one way, measured")
        XCTAssertEqual(summary.inputLabel, "Input → PC")
        XCTAssertEqual(try XCTUnwrap(summary.input), 1.1, accuracy: 0.05)
    }

    func testAnOlderPCFallsBackToTheMacsShare() throws {
        let summary = StatsHUD.Summary(snapshot())
        XCTAssertEqual(summary.label, "receive → screen, median")
        XCTAssertEqual(try XCTUnwrap(summary.median), 5.4, accuracy: 0.05)
        XCTAssertEqual(summary.budget, 1_000 / 120, accuracy: 1e-9)
        XCTAssertEqual(summary.groups[0].detail, "capture, encode & send")
        XCTAssertEqual(try XCTUnwrap(summary.groups[1].milliseconds), 0.21, accuracy: 1e-9)
        XCTAssertEqual(summary.groups[1].detail, "half a ping round trip")
        XCTAssertEqual(summary.inputLabel, "Input → sent")
    }

    func testSkippedFramesArePerSecondNotCumulative() {
        var s = snapshot()
        XCTAssertEqual(StatsHUD.Summary(s).skippedPerSecond, 0) // 120.1 decoded, 119.8 shown
        s.presentedFPS = 52
        XCTAssertEqual(StatsHUD.Summary(s).skippedPerSecond, 68)
        // Slightly more shown than decoded in the window: 0, never -0.
        s.presentedFPS = 120.4
        XCTAssertEqual(String(format: "%.0f/s", StatsHUD.Summary(s).skippedPerSecond), "0/s")
        XCTAssertFalse(StatsHUD.Summary(s).skippedPerSecond.sign == .minus)
    }

    func testTheStreamIsLabelledRowsThatFit() {
        let rows = StatsHUD.streamRows(StreamInfo(host: "", codec: "HEVC", width: 3024, height: 1964, fps: 120,
                                                  bitrateMbps: 120, format: "4:4:4, 10-bit, Fastest",
                                                  link: "Ethernet", vsync: false), receivedMbps: 47.6)
        XCTAssertEqual(rows.map(\.0), ["Video", "Picture", "Display", "Link", "Data"])
        XCTAssertEqual(rows.map(\.1), ["HEVC 3024×1964 @ 120 Hz", "4:4:4, 10-bit, Fastest", "VSync off",
                                       "Ethernet", "48 of 120 Mbps"])
        // No picture options, no link (--host), no data yet.
        let bare = StatsHUD.streamRows(StreamInfo(host: "", codec: "HEVC", width: 1, height: 1, fps: 60,
                                                  bitrateMbps: 20, format: "", link: nil, vsync: true), receivedMbps: nil)
        XCTAssertEqual(bare.map(\.1), ["HEVC 1×1 @ 60 Hz", "VSync on", "–– of 20 Mbps"])
        // Even the widest stream the app can produce fits beside its label.
        let label = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let value = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let inner = StatsHUD.width - 24
        for (name, text) in StatsHUD.streamRows(StreamInfo.widest, receivedMbps: 999) {
            XCTAssertLessThanOrEqual((name as NSString).size(withAttributes: [.font: label]).width,
                                     StatsHUD.streamLabelWidth - 6, name)
            XCTAssertLessThanOrEqual((text as NSString).size(withAttributes: [.font: value]).width,
                                     inner - StatsHUD.streamLabelWidth, text)
        }
    }

    func testDetailedHeightMatchesWhatIsDrawn() throws {
        let image = try XCTUnwrap(StatsHUD.render(synced(snapshot()), mode: .detailed, scale: 1))
        XCTAssertEqual(CGFloat(image.height), StatsHUD.height(for: snapshot(), mode: .detailed).rounded(.up))
        // The bottom padding stays clear of text: the last rows are inside.
        XCTAssertLessThan(StatsHUD.height(for: snapshot(), mode: .detailed), 400)
    }

    func testModeCycles() {
        XCTAssertEqual(HUDMode.off.next, .compact)
        XCTAssertEqual(HUDMode.compact.next, .detailed)
        XCTAssertEqual(HUDMode.detailed.next, .off)
    }
}
