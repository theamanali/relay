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
}
