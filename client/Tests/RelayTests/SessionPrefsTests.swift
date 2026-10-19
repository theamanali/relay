import AppKit
import XCTest
@testable import Relay

final class SessionPrefsTests: XCTestCase {
    @MainActor func testBitrateDefaultsPersistsAndLaunchFlagOverrides() async {
        let suite = "RelayTests.SessionPrefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(SessionPrefs.load(from: defaults).bitrateMbps, 120)
        var saved = SessionPrefs()
        saved.bitrateMbps = 500
        saved.save(to: defaults)
        XCTAssertEqual(SessionPrefs.load(from: defaults).bitrateMbps, 500)

        let launch = LaunchOptions.parse(["Relay", "--bitrate", "750"])
        XCTAssertEqual(SessionPrefs.load(from: defaults).overridden(by: launch).bitrateMbps, 750)
        XCTAssertEqual(SessionPrefs.load(from: defaults).bitrateMbps, 500, "launch override is not persisted")
    }

    @MainActor func testTearingAndScrollDirectionPersistAndFlagOverrides() async {
        let suite = "RelayTests.SessionPrefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = SessionPrefs.load(from: defaults)
        XCTAssertFalse(fresh.preventTearing)
        XCTAssertEqual(fresh.scrollDirection, .system)
        var saved = SessionPrefs()
        saved.preventTearing = true
        saved.scrollDirection = .standard
        saved.save(to: defaults)
        let loaded = SessionPrefs.load(from: defaults)
        XCTAssertTrue(loaded.preventTearing)
        XCTAssertEqual(loaded.scrollDirection, .standard)

        // --metal-vsync turns it on for one launch without saving it.
        saved.preventTearing = false
        saved.save(to: defaults)
        let launch = LaunchOptions.parse(["Relay", "--metal-vsync"])
        XCTAssertTrue(SessionPrefs.load(from: defaults).overridden(by: launch).preventTearing)
        XCTAssertFalse(SessionPrefs.load(from: defaults).preventTearing)
    }

    @MainActor func testSessionReportStaysClosedUntilTurnedOn() async {
        let suite = "RelayTests.SessionPrefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(SessionPrefs.load(from: defaults).showSessionReport)
        var saved = SessionPrefs()
        saved.showSessionReport = true
        saved.save(to: defaults)
        XCTAssertTrue(SessionPrefs.load(from: defaults).showSessionReport)
    }

    @MainActor func testCodecFlagOffersOneCodec() async {
        XCTAssertNil(LaunchOptions.parse(["Relay"]).codec)
        XCTAssertEqual(LaunchOptions.parse(["Relay", "--codec", "h264"]).codec?.bit, 0b001)
        XCTAssertEqual(LaunchOptions.parse(["Relay", "--codec", "hevc"]).codec?.bit, 0b010)
    }

    func testScrollDirectionFlipsOnlyWhenItDiffersFromTheMac() {
        // AppKit's deltas already follow this Mac's setting.
        XCTAssertEqual(ScrollDirection.system.sign(invertedFromDevice: true), 1)
        XCTAssertEqual(ScrollDirection.system.sign(invertedFromDevice: false), 1)
        // Natural: unchanged when the Mac already scrolls naturally, else flipped.
        XCTAssertEqual(ScrollDirection.natural.sign(invertedFromDevice: true), 1)
        XCTAssertEqual(ScrollDirection.natural.sign(invertedFromDevice: false), -1)
        // Standard: the opposite.
        XCTAssertEqual(ScrollDirection.standard.sign(invertedFromDevice: true), -1)
        XCTAssertEqual(ScrollDirection.standard.sign(invertedFromDevice: false), 1)
    }

    func testNaturalScrollingCheckboxFollowsTheMacUntilChosen() {
        var prefs = SessionPrefs()
        // Never chosen: the checkbox shows what this Mac does.
        XCTAssertTrue(prefs.naturalScrolling(macNatural: true))
        XCTAssertFalse(prefs.naturalScrolling(macNatural: false))
        // Chosen: kept whatever the Mac does.
        prefs.scrollDirection = .natural
        XCTAssertTrue(prefs.naturalScrolling(macNatural: false))
        prefs.scrollDirection = .standard
        XCTAssertFalse(prefs.naturalScrolling(macNatural: true))
    }

    @MainActor func testHUDModePersistsAndTheFlagShowsCompact() async {
        let suite = "RelayTests.SessionPrefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(SessionPrefs.load(from: defaults).hudMode, .off)
        var saved = SessionPrefs()
        saved.hudMode = .detailed
        saved.save(to: defaults)
        XCTAssertEqual(SessionPrefs.load(from: defaults).hudMode, .detailed)

        // Before the detailed view, showLatency alone meant the overlay was on.
        defaults.removeObject(forKey: "latencyDetailed")
        XCTAssertEqual(SessionPrefs.load(from: defaults).hudMode, .compact)

        saved.hudMode = .off
        saved.save(to: defaults)
        let launch = LaunchOptions.parse(["Relay", "--latency-stats"])
        XCTAssertEqual(SessionPrefs.load(from: defaults).overridden(by: launch).hudMode, .compact)
    }

    /// Settings subtitles describe the current choice, and each stays on one
    /// line: no wider than the widest one the 380 pt pane was laid out with.
    func testSettingSubtitlesFollowTheChoiceAndFitOneLine() {
        let pairs = [
            (SettingDetail.automaticBitrate(true), SettingDetail.automaticBitrate(false)),
            (SettingDetail.automaticScaling(true, percent: 200), SettingDetail.automaticScaling(false, percent: 200)),
            (SettingDetail.fullColor(true), SettingDetail.fullColor(false)),
            (SettingDetail.tenBit(true), SettingDetail.tenBit(false)),
            (SettingDetail.vsync(true), SettingDetail.vsync(false)),
            (SettingDetail.control(true), SettingDetail.control(false)),
        ]
        for (on, off) in pairs { XCTAssertNotEqual(on, off) }
        XCTAssertEqual(Set(EncoderQuality.allCases.map(\.detail)).count, EncoderQuality.allCases.count)
        XCTAssertEqual(SettingDetail.automaticScaling(true, percent: 150), "Set to 150% to match this Mac's screen.")

        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let budget = width("Set for the resolution, refresh rate and connection.")
        let all = pairs.flatMap { [$0.0, $0.1] } + EncoderQuality.allCases.map(\.detail)
            + [SettingDetail.automaticScaling(true, percent: 300)]
        for text in all { XCTAssertLessThanOrEqual(width(text), budget, text) }
    }
}
