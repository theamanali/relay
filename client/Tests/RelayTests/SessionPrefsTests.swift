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
}
