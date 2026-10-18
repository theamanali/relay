import XCTest
@testable import Relay

final class SessionTextTests: XCTestCase {
    func testStalledStreamsSayWhichStepNeverCame() {
        XCTAssertEqual(SessionText.ended("the PC didn't start the stream", streamed: false),
                       "The PC didn't start the stream — try again")
        XCTAssertEqual(SessionText.ended("the PC sent no picture", streamed: false),
                       "The PC sent no picture — wake it and try again")
        // Distinct from a PC that never answered the handshake.
        XCTAssertEqual(SessionText.ended("the PC didn't answer", streamed: false), "The PC didn't answer")
    }

    func testEndReasonsReadAsSentences() {
        XCTAssertEqual(SessionText.ended("the host rejected the PIN", streamed: false), "Wrong PIN — try again")
        XCTAssertEqual(SessionText.ended("host stopped the stream (reason 0)", streamed: true), "The PC ended the session")
        XCTAssertEqual(SessionText.ended("connection closed", streamed: false), "The PC closed the connection")
        XCTAssertEqual(SessionText.ended("host stopped the stream (reason 4)", streamed: false), "PC doesn't know this MacBook — pair again")
        XCTAssertEqual(SessionText.ended("the PC forgot this MacBook", streamed: false), "PC forgot this MacBook")
        XCTAssertEqual(SessionText.ended("read error: Connection reset by peer", streamed: true), "Lost the connection to the PC")
        XCTAssertEqual(SessionText.ended("connection failed: Connection refused", streamed: false), "Couldn't reach the PC")
        XCTAssertEqual(SessionText.ended("couldn't reach the PC in 12 s", streamed: false), "Couldn't reach the PC")
        XCTAssertEqual(
            SessionText.ended("handshake failed: host identity changed: expected A, got B. Remove it from hosts.txt to pair again.", streamed: false),
            "PC identity changed — forget it, pair again"
        )
        XCTAssertEqual(SessionText.ended("something new", streamed: false), "Couldn't connect: something new")
        XCTAssertEqual(SessionText.ended("the PC is in another session", streamed: false), "The PC is in another session")
        XCTAssertEqual(SessionText.ended("host stopped the stream (reason 6)", streamed: false), "The PC is in another session")
        XCTAssertEqual(SessionText.ended("the PC didn't answer", streamed: false), "The PC didn't answer")
        XCTAssertEqual(
            SessionText.ended("host stopped the stream (reason 7)", streamed: true, bitrateMbps: 500),
            "Couldn't sustain 500 Mbps — lower the bitrate"
        )
        XCTAssertEqual(
            SessionText.ended("read error: connection reset", streamed: true, bitrateMbps: 500),
            "Lost connection at 500 Mbps — lower bitrate"
        )
        XCTAssertEqual(
            SessionText.ended("too many wrong PINs — the host accepts none for 599 s", streamed: false),
            "Too many wrong PINs — try again later"
        )
    }

    func testRetryWaitIsWholeMinutesRoundedUp() {
        XCTAssertEqual(SessionText.retryWait(seconds: 599), "10 min")
        XCTAssertEqual(SessionText.retryWait(seconds: 600), "10 min")
        XCTAssertEqual(SessionText.retryWait(seconds: 61), "2 min")
        XCTAssertEqual(SessionText.retryWait(seconds: 1), "1 min")
        XCTAssertEqual(SessionText.retryWait(seconds: 0), "1 min")
    }

    func testCompactMessagesFitTheFooter() {
        let reasons = ["host stopped the stream (reason 7)", "macOS blocked Relay's local network access",
                       "the PC didn't start the stream", "the PC sent no picture", "malformed record",
                       "the host rejected the PIN", "pairing cancelled", "handshake failed: host identity changed",
                       "too many wrong PINs — the host accepts none for 599 s", "the PC is in another session",
                       "the PC didn't answer", "the PC forgot this MacBook",
                       "reason 4", "reason 3", "reason 1", "reason 2", "reason 0", "reason 6", "connection closed",
                       "read error: x", "connection failed: x", "handshake failed: x", "protocol error: x",
                       String(repeating: "z", count: 200)]
        for reason in reasons {
            for streamed in [true, false] {
                for mbps in [nil, 120, 1000] {
                    let text = SessionText.ended(reason, streamed: streamed, bitrateMbps: mbps)
                    XCTAssertLessThanOrEqual(SessionText.width(text), SessionText.footerWidth, text)
                }
            }
        }
        XCTAssertLessThanOrEqual(SessionText.width(SessionText.shortName("WWWWWWWWWWWWWWWWWWWWWWWW")),
                                 SessionText.nameWidth)
        XCTAssertEqual(SessionText.fit("short"), "short")
    }

    /// Every other line the footer can show, with the widest PC name a
    /// sentence can hold, fits whole.
    func testEveryFooterLineFitsWithTheWidestName() {
        let name = SessionText.shortName(String(repeating: "W", count: 40))
        let lines = ["Pairing with \(name)…", "Connecting to \(name)…", "Waiting for \(name)…", "Forgetting \(name)…",
                     "Paired with \(name)", "\(name) isn't paired", "Forgot \(name)", "Forgot \(name) on this Mac only",
                     "Can't search for PCs — retrying", "Can't read this MacBook's identity key",
                     SessionText.starting(width: 3024, height: 1964, fps: 120, settings: ["4:4:4", "10-bit", "Balanced"]),
                     SessionText.starting(width: 7680, height: 4320, fps: 240, settings: ["4:4:4", "10-bit", "Balanced"])]
        for line in lines {
            XCTAssertLessThanOrEqual(SessionText.width(line), SessionText.footerWidth, line)
            XCTAssertFalse(line.contains("·"), line)
        }
    }

    func testStartingKeepsTheSettingsThatFitAndUsesCommas() {
        XCTAssertEqual(SessionText.starting(width: 1920, height: 1080, fps: 60, settings: ["10-bit"]),
                       "Starting 1920×1080 @ 60 fps, 10-bit…")
        XCTAssertEqual(SessionText.starting(width: 1920, height: 1080, fps: 60, settings: []),
                       "Starting 1920×1080 @ 60 fps…")
        let full = SessionText.starting(width: 3024, height: 1964, fps: 120, settings: ["4:4:4", "10-bit", "Balanced"])
        XCTAssertTrue(full.hasPrefix("Starting 3024×1964 @ 120 fps, 4:4:4"), full)
    }

    func testOnlyStallsReachTheFooter() {
        XCTAssertNil(SessionText.footerStatus("Connected, securing…", hostName: "PC"))
        XCTAssertNil(SessionText.footerStatus("Secure channel to 04F6A881", hostName: "PC"))
        XCTAssertEqual(SessionText.footerStatus("Waiting for host: Connection refused", hostName: "Desk PC"), "Waiting for Desk PC…")
    }

    func testUnconfirmedForgetDoesNotAssertThePCStillHasThePairing() {
        let text = SessionText.hostSideForgetHelp(detail: "The PC didn't answer", fingerprint: "1234ABCD")
        XCTAssertTrue(text.contains("may still remember"))
        XCTAssertFalse(text.contains("still remembers"))
        XCTAssertTrue(text.contains("relay-host paired --forget 1234ABCD"))
        XCTAssertTrue(text.hasPrefix("The PC didn't answer\n\n"))
    }

    func testLocalNetworkDenialExplainsPermissionAndRelaunch() {
        XCTAssertEqual(SessionText.ended("macOS blocked Relay's local network access", streamed: false),
                       "Local network access blocked — reopen Relay")
        let help = SessionText.hostSideForgetHelp(detail: SessionText.localNetworkHelp, fingerprint: "1234ABCD")
        XCTAssertTrue(help.contains("Privacy & Security → Local Network"))
        XCTAssertTrue(help.contains("quit and reopen Relay"))
    }
}

final class LocalNetworkProbeTests: XCTestCase {
    func testProbesALANAddressNotAVPNOne() {
        for lan in ["10.0.0.47", "192.168.1.2", "172.20.0.1", "169.254.12.3"] {
            XCTAssertTrue(HostConnection.isPrivateIPv4(lan), lan)
        }
        for other in ["100.98.48.108", "172.32.0.1", "8.8.8.8", "fe80::1", "gaming-pc.local", ""] {
            XCTAssertFalse(HostConnection.isPrivateIPv4(other), other)
        }
    }
}
